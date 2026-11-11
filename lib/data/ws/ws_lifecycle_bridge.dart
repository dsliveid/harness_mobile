/// 前后台生命周期 → 长连接 resync 的桥接层（M4）。
///
/// 已代码级确认的缺口：`DeviceWsClient` 是纯 Dart 状态机（无 Flutter 依赖），
/// 因此它**永远不会**知道 App 切了后台。后果是真机上极常见的组合：
/// 用户切后台 10 分钟 → 系统回收 TCP（NAT 超时 / Doze）→ 回前台时状态机
/// 仍认为自己是 [DeviceWsState.live] → UI 诚实地说「已连接」，
/// 但一个帧都收不到，用户看到的是「点什么都没反应」。
///
/// 本文件负责把 `WidgetsBindingObserver` 的 lifecycle 事件翻译成状态机动作：
/// - `resumed`        → [DeviceWsLifecycleObserver.onResumed]（重连 + 状态重拉）
/// - `paused`/`hidden`/`detached` → 挂起（停心跳、停退避，省电且不留半死连接）
/// - `inactive`       → **忽略**（下拉通知栏 / 来电 / 切 App 都会触发，
///   把它当后台会让用户在正常使用中被无端断连）
///
/// 幂等性由状态机自身承担（`_resyncInFlight` + 状态判据 + dead 不复活），
/// 因此本类可以放心对同一个事件重复调用 —— 快速切前后台的抖动不会造成
/// 连接风暴。这一点有测试直接断言（连续 resumed 只建连一次）。
library;

import 'package:flutter/widgets.dart';

import 'device_ws.dart';

/// 把 Flutter lifecycle 事件接到 [DeviceWsClient] 上。
///
/// 用法（由上层持有，注意必须 `detach()` 否则观察者泄漏）：
/// ```dart
/// final bridge = DeviceWsLifecycleBridge(client);
/// bridge.attach();
/// // dispose 时
/// bridge.detach();
/// ```
class DeviceWsLifecycleBridge with WidgetsBindingObserver {
  DeviceWsLifecycleBridge(
    this.client, {
    WidgetsBinding? binding,
    void Function(String message)? onLog,
  })  : _binding = binding,
        _onLog = onLog;

  final DeviceWsClient client;

  /// 可注入（测试环境需要自己控制 binding 或完全不注册全局观察者）。
  final WidgetsBinding? _binding;
  final void Function(String message)? _onLog;

  bool _attached = false;

  /// 是否已注册为全局观察者（供测试观测）。
  bool get attached => _attached;

  /// 已处理的 lifecycle 事件序列（观测用：排查真机前后台抖动）。
  final List<AppLifecycleState> handledEvents = <AppLifecycleState>[];

  WidgetsBinding get _targetBinding => _binding ?? WidgetsBinding.instance;

  /// 注册观察者（幂等：重复调用不会重复注册）。
  void attach() {
    if (_attached) return;
    _targetBinding.addObserver(this);
    _attached = true;
  }

  /// 注销观察者（幂等）。
  void detach() {
    if (!_attached) return;
    _targetBinding.removeObserver(this);
    _attached = false;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    handledEvents.add(state);
    switch (state) {
      case AppLifecycleState.resumed:
        onResumed();
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        onBackground();
      case AppLifecycleState.inactive:
        // 刻意忽略：通知栏下拉、来电、切换 App 预览都会触发 inactive，
        // 此时用户其实还在前台感知范围内，断连只会造成可见的闪烁。
        _log('inactive：保持连接不变');
    }
  }

  /// 回到前台：重连 + 状态重拉（幂等，失败不外抛）。
  void onResumed() {
    client.resumeFromBackground().catchError((Object error) {
      // 生命周期回调里抛异常会冒到 framework 变红屏/黑屏，必须吞掉并记录。
      _log('resync 失败：$error');
      return false;
    });
  }

  /// 进入后台：挂起连接（幂等，失败不外抛）。
  void onBackground() {
    client.suspendForBackground().catchError((Object error) {
      _log('挂起连接失败：$error');
    });
  }

  void _log(String message) => _onLog?.call('[ws_lifecycle] $message');
}
