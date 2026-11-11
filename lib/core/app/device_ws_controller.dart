/// 设备长连接控制器（App 级单例，把 `DeviceWsClient` 接到 UI 与生命周期上）。
///
/// ## 为什么需要这一层
/// `DeviceWsClient` 的 `deviceToken` 是**构造期**参数（会被编进 endpoint 的
/// `?token=`），而令牌存在 Keychain 里必须 `await` 读取。Riverpod 的普通
/// `Provider` 是同步的，直接在里面 await 会把整条链路异步化
/// （变成 `FutureProvider` → 每个页面每次 build 都要处理 loading 态）。
///
/// 因此引入本控制器作中介：
/// - 构造是**同步**的（不读令牌）；
/// - [start] 内部异步读令牌 → 构造真实 client → 启动连接；
/// - UI 订阅本类即可拿状态，并可在 `initState` 里 [attachLifecycle]。
///
/// ## 生命周期铁律（2026-11 用户决策，勿擅改）
/// - **登出（`signOut`）不断开**：WS 绑定「这台设备被授权接入」，与
///   「当前登录的是谁」正交（`device_service.go:395` 只查 devices.token_hash，
///   完全不碰 tokens 表）。登出只清 user_token，device_token 仍在。
/// - **解绑（`resetPairing`）必须断开**：device_token 已被 `clearAll()` 抹掉，
///   继续重连只会持续 401 打满服务端日志。
///
/// ## 反向收敛（2026-11 新增，勿删）
/// 服务端**单方面**吊销本机（管理端 DELETE / 其他端解绑 / 端侧自解绑）后，
/// 会推一帧 fatal `device.revoked` 然后关连接，端侧状态机落到
/// `dead(repairPairing)`。旧实现只停连接、**不动会话**：`AppSession` 仍是
/// paired、Keychain 里令牌都在，UI 显示「仍绑定」，后续每个请求都拿失效令牌
/// 反复 401。现在 [start] 里监听状态流，判定该终态后自动 [AppSession.resetPairing]
/// 并把相位切回配对页，同时留下 [revocationNotice] 供配对页给用户一句原因。
///
/// 🔴 与登出严格正交：`signOut()` **不碰** WS，连接保持 live，永远不会
/// 走到本路径（服务端没吊销，不可能推 `device.revoked`）。
library;

import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../data/local/secure_store.dart';
import '../../data/ws/device_connection.dart';
import '../../data/ws/device_ws.dart';
import '../../data/ws/ws_lifecycle_bridge.dart';
import '../../protocol/envelope.dart' show FrameCode;
import '../../protocol/frame_payloads.dart' show WelcomePayload;
import 'app_session.dart';

/// 设备长连接控制器。
class DeviceWsController extends ChangeNotifier {
  DeviceWsController({
    required SecureStore store,
    required DeviceConnectionFactory factory,
    required AppSession session,
  })  : _store = store,
        _factory = factory,
        _session = session;

  final SecureStore _store;
  final DeviceConnectionFactory _factory;
  final AppSession _session;

  DeviceWsClient? _client;
  DeviceWsLifecycleBridge? _bridge;

  /// 服务端单方面吊销本机后的原因文案（配对页据此给用户一句解释）。
  ///
  /// 与 [deadReason] 的区别：[deadReason] 是状态机的**技术原因**
  /// （`repairPairing` 也可能是用户自己解绑触发的 401 重连耗尽），
  /// 本字段只在「确实收到 terminal `device.revoked` 并已自动收敛」时被置位，
  /// 是给用户看的**业务事实**。用户主动解绑路径会把它消费掉
  /// （见 `device_unbind.dart` 的 `clearRevocationNotice`），避免自己按的
  /// 按钮却提示「被服务端解除了」。
  String? _revocationNotice;

  /// 是否已因 `device.revoked` 完成过一次自动收敛（幂等护栏）。
  ///
  /// `states` 是广播流，dead 状态可能被多次回调（以及随后的 stop() 再触发
  /// 一次状态变化），没有这个标记就会重复 resetPairing / 重复提示。
  bool _revocationHandled = false;

  /// 服务端已解除本设备绑定（未发生则为 null）。
  String? get revocationNotice => _revocationNotice;

  /// 文案由端侧统一给（不依赖服务端 message 的措辞）。
  static const String serverRevokedNotice = '服务端已解除本设备绑定，请重新配对后再使用';

  /// 消费掉吊销提示（用户主动解绑路径调用，或 UI 展示后调用）。
  void clearRevocationNotice() {
    if (_revocationNotice == null) return;
    _revocationNotice = null;
    _safeNotify();
  }

  /// 是否已 dispose：广播流回调可能在 dispose 之后才到达，
  /// 任何 notifyListeners() 前都必须检查它（否则抛「used after disposed」）。
  bool _disposed = false;

  /// 安全通知（dispose 之后静默跳过）。
  ///
  /// 为什么统一走这个 helper 而不是各处裸调 notifyListeners()：
  /// `client.states` 是**广播流**，其回调与 UI 生命周期不同步 ——
  /// 页面销毁 / 测试收尾时 controller 已 dispose，但流回调仍可能迟到一步，
  /// 裸调 notifyListeners() 会抛「A DeviceWsController was used after being
  /// disposed」把测试打成失败（实测踩中）。
  void _safeNotify() {
    if (_disposed) return;
    notifyListeners();
  }

  /// 当前状态（未启动 / 无凭据时为 [DeviceWsState.disconnected]）。
  DeviceWsState get state => _client?.state ?? DeviceWsState.disconnected;

  /// 转入 dead 的原因（非 dead 为 null）。
  DeviceWsDeadReason? get deadReason => _client?.deadReason;

  /// 已排队的重连次数（0 = 当前连接未经历退避）。
  int get retryCount => _client?.retryCount ?? 0;

  /// 当前生效的心跳间隔（收到 welcome 前为 null）。
  Duration? get heartbeatInterval => _client?.heartbeatInterval;

  /// 最近一次 welcome 负载（含服务端 device_id / protocol_version）。
  WelcomePayload? get welcome => _client?.welcome;

  /// 是否已启动（有活跃 client）。
  bool get isStarted => _client != null;

  /// 启动连接。
  ///
  /// 幂等：已启动则直接返回。无 baseUrl 或无 device_token 时**不启动**
  /// （返回 false），避免拿一条必然 401 的连接去打满服务端日志。
  Future<bool> start() async {
    if (_client != null) return true;

    final baseUrl = _session.baseUrl;
    if (baseUrl.isEmpty || _session.deviceId.isEmpty) return false;

    // 🔴 这里必须先 await 读令牌：DeviceWsClient 把令牌编进 endpoint，
    // 构造后无法再改。读不到令牌就不要建 client（否则连接必然 401）。
    final token = await _store.getDeviceToken();
    if (token == null || token.isEmpty) return false;

    final client = DeviceWsClient(
      connectionFactory: _factory,
      baseUrl: Uri.parse(baseUrl),
      deviceToken: token,
      // 用户明确要求：**不上报 load**（故不传 loadProvider）。
      onLog: (String message) {
        // 只保留调试期输出；device_ws 内部已保证令牌经 maskToken 打码。
        assert(() {
          debugPrint('[device_ws] $message');
          return true;
        }());
      },
    );

    client.states.listen((DeviceWsState s) {
      // 状态变化必须让 UI 重建（ConnectionStateChip 依赖它）。
      //
      // 🔴 必须检查 disposed：`states` 是广播流，订阅回调可能在 controller
      // 已被 ChangeNotifierProvider dispose 之后才到达（例如页面在连接
      // 建立途中被销毁、或测试收尾时）。此时调 notifyListeners() 会抛
      // 「A DeviceWsController was used after being disposed」。
      if (_disposed) return;
      _safeNotify();
      // 服务端单方面吊销 → 自动反向收敛（见类注释「反向收敛」）。
      _maybeConvergeRevocation(client);
    });

    _client = client;
    // 生命周期桥：前后台挂起/恢复（回前台 resync）。
    // ⚠️ attach 必须在 Flutter binding 就绪后调用；本方法由 UI initState 触发。
    final bridge = DeviceWsLifecycleBridge(client);
    bridge.attach();
    _bridge = bridge;

    _safeNotify();
    unawaited(client.start());
    return true;
  }

  /// 用户手动重连（dead 状态下调用）。
  ///
  /// 若尚未启动（例如之前没有令牌），本方法会先尝试 [start]。
  Future<void> reconnectNow() async {
    final client = _client;
    if (client == null) {
      await start();
      return;
    }
    await client.reconnectNow();
    _safeNotify();
  }

  /// 主动停止（解绑设备时调用）。
  ///
  /// ⚠️ 与登出的区别：登出**不调用**本方法（WS 继续跑）。
  Future<void> stop() async {
    final bridge = _bridge;
    _bridge = null;
    bridge?.detach();

    final client = _client;
    _client = null;
    if (client != null) {
      // dispose() 内部已 await stop()（幂等），不必再单独调 stop()。
      await client.dispose();
    }
    _safeNotify();
  }

  /// 把 Flutter 生命周期事件接到状态机（前后台挂起/恢复）。
  ///
  /// 若尚未 [start]，本方法无副作用（返回 false）。
  bool attachLifecycle() {
    final client = _client;
    if (client == null) return false;
    if (_bridge != null) return true; // 幂等
    final bridge = DeviceWsLifecycleBridge(client);
    bridge.attach();
    _bridge = bridge;
    return true;
  }

  // ============ 反向收敛：服务端吊销 → 端侧自动解绑 ============

  /// 判定是否为「服务端已吊销本机」的终态，并执行一次自动收敛。
  ///
  /// 触发条件（两者同时满足，缺一不可）：
  /// 1. 状态机落到 `dead` 且原因为 [DeviceWsDeadReason.repairPairing]
  ///    （`ErrorPayload.action` 把 `FrameCode.revoked` 映射到这里）；
  /// 2. 最近收到的帧级错误码确实是 `device.revoked`。
  ///
  /// 为什么还要第 2 条：`repairPairing` 在协议里专供 `revoked` 使用，但端侧
  /// 若日后新增其它「需重新配对」的原因，光看 deadReason 会把「网络抖到最后
  /// 一次重连也失败」误判成「被吊销」，进而**误删用户的设备令牌**。多校一个
  /// 错误码，代价极低，避免不可逆误操作。
  ///
  /// 收敛动作（顺序即语义）：
  /// 1. 先留下 [revocationNotice]（业务事实，供配对页展示）；
  /// 2. `_revocationHandled` 置位做幂等护栏；
  /// 3. `resetPairing()`：清 Keychain 全部令牌 + 清设备身份 →
  ///    `AppSession.stage` 变 [AppStage.pairing]，`go_router` 的
  ///    `refreshListenable` 会自动把用户送回配对页（无需页面自己 push）；
  /// 4. `stop()`：顺手拆掉这条已死连接（dead 状态下重连不会自动发生，
  ///    但 controller 仍持有 client 与 lifecycle bridge，留着只是泄漏）。
  void _maybeConvergeRevocation(DeviceWsClient client) {
    if (_disposed || _revocationHandled) return;
    if (client.state != DeviceWsState.dead) return;
    if (client.deadReason != DeviceWsDeadReason.repairPairing) return;
    if (client.lastFrameCode != FrameCode.revoked) return;

    _revocationHandled = true;
    _revocationNotice = serverRevokedNotice;
    // 先同步通知一次：相位切换（resetPairing 内部 notifyListeners）会让
    // go_router 立刻重算落点，配对页那时就能读到上面这句文案。
    _safeNotify();

    // fire-and-forget：本方法是流回调（同步签名），不能 await。
    // resetPairing / stop 都是本地操作，无网络依赖。
    unawaited(_convergeAfterRevocation());
  }

  Future<void> _convergeAfterRevocation() async {
    try {
      await _session.resetPairing();
      await stop();
    } on Object {
      // 收敛失败不该把异常抛进广播流回调（会变成未捕获的 zone 错误）。
      // 令牌已在 resetPairing 内部先清（clearAll），最坏情况只是连接残留。
    }
    // stop() 会把状态推成 disconnected，UI 需要重建（此时相位已是 pairing）。
    _safeNotify();
  }

  @override
  void dispose() {
    // ChangeNotifierProvider 负责调用本方法：必须清理桥与 client，
    // 否则 WidgetsBindingObserver 泄漏（切前后台仍回调已销毁对象）。
    _disposed = true;
    _bridge?.detach();
    _bridge = null;
    final client = _client;
    _client = null;
    // dispose() 是异步的，但 ChangeNotifier.dispose 是同步签名：
    // 用 unawaited 明确表达「fire-and-forget」，并保证不阻塞 super.dispose()。
    if (client != null) unawaited(client.dispose());
    super.dispose();
  }
}
