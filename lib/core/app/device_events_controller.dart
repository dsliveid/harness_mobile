/// 设备状态实时同步控制器（App 级单例）。
///
/// # 职责边界（这是本文件存在的全部理由，勿扩权）
/// | 层 | 负责 | 不负责 |
/// | --- | --- | --- |
/// | [SseSession] | 连接 / 分帧 / 退避 / 生命周期 | 不认识「设备」这个概念 |
/// | `device_state_state.dart` | 帧 → 设备列表（纯函数） | 不碰 IO、不碰 Flutter |
/// | **本文件** | 令牌装配、**门控**、组合两层、对 UI 暴露状态 | 不做任何归约逻辑、不画 UI |
///
/// # 🔴 固定边界：移动端原生**只**接「设备状态流」，绝不接「会话列表流」
/// `docs/protocols.md` §4 定义了三条互不相同的 SSE 流。移动端的责任划分是：
///
/// | 流 | 服务端 | 移动端原生 | 理由 |
/// | --- | --- | --- | --- |
/// | ① Run 事件流 | ✅ | ❌ | WebView 内 React 已消费；原生无对话页 |
/// | ② **设备状态流** | ✅ | ✅ **本文件** | 账号页是原生真实页面，设备在线态是原生可见域 |
/// | ③ 会话列表流 | ✅ | ❌ **明确不接** | 见下 |
///
/// 为什么不接 ③：移动端首屏 `/webview` 承载的是**服务端同一份 `web/dist`
/// （React + zustand）**，其 SSE 订阅在 React 侧已完整实现并实测通过
/// （`docs/下一步工作计划.md` v5 §0「实时同步 · Web 端 三期全通」）。
/// 而原生侧的会话列表 / 审批中心页面**已在批次 C 删除**
/// （`lib/app.dart:18-19`）。若在 Dart 侧再接一条 ③，结果是对**同一条流**
/// 开两条连接：双倍占用服务端慢消费者预算，双倍重连风暴，且原生侧
/// **没有任何 UI 消费它** —— 纯粹的堆叠。
///
/// 未来若要在原生做会话列表 UI，正确做法是**在这条边界内新增消费方**，
/// 而不是偷偷再挂一条连接。
///
/// # 门控（§4.4 第 1 条铁律）
/// **必须等首屏 `GET /api/v1/devices` 落地后才允许建连**。
/// 若在首屏之前建连，`snapshot` 帧会与首屏结果交错覆盖 —— 谁后到谁赢，
/// 表现为「列表随机闪烁 / 偶尔少一台设备」。故由 UI 显式调
/// [markFirstListReady] 开闸，本控制器不会自作主张提前连。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../data/local/secure_store.dart' show SecureStore, maskToken;
import '../../data/model/device_state.dart';
import '../../data/sse/device_state_state.dart';
import '../../data/sse/sse_connection.dart';
import '../../data/sse/sse_event.dart';
import '../../data/sse/sse_lifecycle_bridge.dart';
import '../../data/sse/sse_session.dart';

/// 设备状态实时同步控制器。
class DeviceEventsController extends ChangeNotifier {
  DeviceEventsController({
    required SecureStore store,
    required String Function() baseUrl,
    SseConnectionFactory? factory,
  })  : _store = store,
        _baseUrl = baseUrl,
        _factory = factory ?? _defaultFactory;

  final SecureStore _store;

  /// 服务端基址的取值函数（而非快照值）。
  ///
  /// 为什么是函数：`AppSession` 是 `ChangeNotifier` 而非 Riverpod 的
  /// AsyncNotifier，用户改地址不会让普通 Provider 失效；若这里缓存字符串，
  /// 换过地址后仍会连旧服务器（`providers.dart:servicesOf` 记录了同一个坑）。
  /// 每次建连时重新取值即可，建连频率远低于配置变更频率。
  final String Function() _baseUrl;
  final SseConnectionFactory _factory;

  SseSession? _session0;
  SseLifecycleBridge? _bridge;

  List<DeviceState> _devices = const <DeviceState>[];
  SseState _state = SseState.idle;

  /// 首屏列表是否已落地（门控开关，见文件头）。
  bool _firstListReady = false;

  bool _disposed = false;

  /// 当前设备列表（服务端权威态；离线设备**也在列表里**，只是 `online=false`）。
  List<DeviceState> get devices => _devices;

  /// 实时连接状态（`open` 才代表「正在实时更新」）。
  SseState get state => _state;

  /// 是否已开闸（首屏已落地）。
  bool get firstListReady => _firstListReady;

  /// 在线设备数（UI 概览用）。
  int get onlineCount =>
      _devices.where((DeviceState d) => d.online).length;

  /// 首屏 `GET /api/v1/devices` 已落地 → 开闸并建连。
  ///
  /// 幂等：重复调用不会重复建连（[SseSession.start] 自身也幂等）。
  /// 首屏结果同时灌入本地列表：SSE 快照到达前界面就有内容，不必等一次往返。
  Future<void> markFirstListReady(List<DeviceState> firstPage) async {
    if (_disposed) return;
    final bool first = !_firstListReady;
    _firstListReady = true;
    if (!sameDeviceList(_devices, firstPage)) {
      _devices = List<DeviceState>.unmodifiable(firstPage);
      _safeNotify();
    }
    if (first) await _connect();
  }

  /// 启动（无 UI 首屏时也可用：例如后台唤起后直接建连）。
  ///
  /// 与 [markFirstListReady] 的差异：本方法**不**灌首屏数据，只建连。
  Future<void> start() async {
    if (_disposed) return;
    _firstListReady = true;
    await _connect();
  }

  /// 回前台立即重连（生命周期桥会调，UI 的手动「重试」也调这个）。
  Future<void> reconnectNow() async {
    if (_disposed) return;
    final SseSession? session = _session0;
    if (session == null) {
      await _connect();
      return;
    }
    await session.reconnectNow();
  }

  /// 挂起（进后台）。
  Future<void> suspend() async {
    final SseSession? session = _session0;
    if (session == null) return;
    await session.suspend();
  }

  /// 终止（解绑 / 登出清凭据时调，幂等）。
  Future<void> stop() async {
    final SseLifecycleBridge? bridge = _bridge;
    _bridge = null;
    // 🔴 必须 detach：否则组件销毁后观察者泄漏，回前台会复活已废弃的连接
    // （`docs/protocols.md` §4.4 第 4 条）。
    bridge?.detach();

    final SseSession? session = _session0;
    _session0 = null;
    await session?.close();
    if (!_disposed) {
      _devices = const <DeviceState>[];
      _state = SseState.idle;
      _firstListReady = false;
      _safeNotify();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    // 不 await：dispose 是同步的。close() 内部会 abort 连接，
    // 未完成的 Future 在 microtask 里收尾即可。
    unawaited(_teardown());
    super.dispose();
  }

  Future<void> _teardown() async {
    final SseLifecycleBridge? bridge = _bridge;
    _bridge = null;
    bridge?.detach();
    final SseSession? session = _session0;
    _session0 = null;
    await session?.close();
  }

  // —— 内部实现 ——

  Future<void> _connect() async {
    if (_disposed || _session0 != null) return;
    // 门控：首屏未落地绝不建连（§4.4 第 1 条）。
    if (!_firstListReady) return;

    final String baseUrl = _baseUrl();
    if (baseUrl.isEmpty) return;

    // 🔴 必须 await 读令牌：令牌只进请求头（红线 R3），拿不到就不建连
    // （否则必然 401，还会打满服务端日志）。
    final String? token = await _store.getUserToken();
    if (token == null || token.isEmpty) {
      _log('无用户令牌（未登录），不建连：${maskToken(token)}');
      return;
    }

    final Uri? base = Uri.tryParse(baseUrl);
    if (base == null) {
      _log('baseUrl 非法，不建连：$baseUrl');
      return;
    }

    final SseSession session = SseSession(
      factory: _factory,
      endpoint: deviceEventsUri(baseUrl: base),
      headers: <String, String>{'Authorization': 'Bearer $token'},
      onEvent: _handleEvent,
      onStateChanged: _handleState,
      onLog: _log,
    );

    _session0 = session;

    // 生命周期桥必须在建连前 attach：否则回前台那一刻正好在建连途中会漏 resync。
    final SseLifecycleBridge bridge = SseLifecycleBridge(session, onLog: _log);
    bridge.attach();
    _bridge = bridge;

    await session.start();
  }

  void _handleEvent(SseEvent event) {
    if (_disposed) return;
    final DeviceListChange change = reduceDeviceState(_devices, event);
    // 重复帧（重连必然产生）不得触发重建：否则每次重连整页闪一次。
    if (!change.changed) return;
    _devices = List<DeviceState>.unmodifiable(change.devices);
    _safeNotify();
  }

  void _handleState(SseState state) {
    if (_disposed) return;
    if (_state == state) return;
    _state = state;
    _safeNotify();
  }

  void _safeNotify() {
    if (_disposed) return;
    notifyListeners();
  }

  void _log(String message) {
    assert(() {
      debugPrint('[device_events] $message');
      return true;
    }());
  }
}

/// 生产用连接工厂：每次重连新建一条 `dart:io` 连接。
///
/// 与 `deviceConnectionFactoryProvider` 同一范式：工厂可注入 ⇒ 状态机与
/// 归约层都能在无网络环境下被单测覆盖。
Future<SseConnection> _defaultFactory(
  Uri endpoint,
  Map<String, String> headers,
) async =>
    IoHttpSseConnection(endpoint, headers: headers);
