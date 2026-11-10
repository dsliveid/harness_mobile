/// App 级 WebView 解锁门（批次 C-2，架构文档 §4.7.1 / §6.3 决策 3）。
///
/// 定位：生物识别从「审批前置校验」改为「**App 级访问前置门**」。
///
/// 触发时机（三处，均收敛到本状态机）：
/// 1. **冷启动**：App 起来了但还没解锁；
/// 2. **回前台**：切后台超过 [relockAfter] 再回来（短暂切走不重复验，避免骚扰）；
/// 3. **手动锁定**：设置页「锁定 App」按钮。
///
/// 铁律：
/// - 解锁失败**不降级为密码**、**无跳过按钮**（fail-closed 由 [BiometricGate] 保证）；
/// - 顺序：**先解锁，再检查登录态**；未登录走原生登录（§4.2）；
/// - 不改变 R3：令牌仍在 Keychain，本锁不参与任何密钥派生。
library;

import 'package:flutter/widgets.dart';

import 'biometric_gate.dart';

/// 解锁门状态。
enum WebViewLockState {
  /// 未解锁：必须通过生物识别才能进入 WebView。
  locked,

  /// 已解锁：可进入 WebView 主体。
  unlocked,

  /// 正在验证（用于按钮转圈，避免重复触发）。
  authenticating,
}

/// App 级解锁状态机。
class WebViewLock extends ChangeNotifier with WidgetsBindingObserver {
  WebViewLock({
    required BiometricGate gate,
    WebViewLockState initial = WebViewLockState.locked,
    this.relockAfter = const Duration(minutes: 5),
  })  : _gate = gate,
        _state = initial;

  final BiometricGate _gate;

  /// 切后台超过该时长后回前台需重新解锁。
  final Duration relockAfter;

  WebViewLockState _state;
  DateTime? _backgroundAt;
  bool _observing = false;

  WebViewLockState get state => _state;

  bool get isLocked => _state != WebViewLockState.unlocked;

  /// 开始监听 App 生命周期（在根组件 initState 内调用一次）。
  void startObserving() {
    if (_observing) return;
    _observing = true;
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        _backgroundAt ??= DateTime.now();
      case AppLifecycleState.resumed:
        final at = _backgroundAt;
        _backgroundAt = null;
        if (at != null && DateTime.now().difference(at) >= relockAfter) {
          lock();
        }
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
        // 不改变锁状态：inactive 会在来电/下拉通知时短暂触发，不能当锁。
        break;
    }
  }

  /// 手动锁定（设置页按钮 / 登出）。
  void lock() {
    if (_state == WebViewLockState.locked) return;
    _state = WebViewLockState.locked;
    notifyListeners();
  }

  /// 请求解锁。fail-closed：拿不到结果即保持锁定。
  ///
  /// 三条保证：
  /// 1. 闸门返回 false / 抛异常 → 状态**必定**回到 [WebViewLockState.locked]，
  ///    绝不进入 unlocked；
  /// 2. 异常路径会先回滚状态并 notifyListeners，再原样上抛 ——
  ///    若只上抛不回滚，`_state` 会永久停在 [WebViewLockState.authenticating]，
  ///    而本方法首行会因此拒掉之后每一次解锁，用户被硬锁死在门外且按钮永久转圈；
  ///    回滚 + 上抛的组合既保证状态机自愈，也让调用方（锁屏 UI）能收到异常
  ///    并给出可读提示，不做静默吞掉。
  Future<bool> unlock({String reason = '请验证指纹或面容以进入工作区'}) async {
    if (_state == WebViewLockState.authenticating) return false;
    _state = WebViewLockState.authenticating;
    notifyListeners();

    final bool ok;
    try {
      ok = await _gate.authenticate(reason: reason);
    } on Object {
      // 插件崩溃 / PlatformException / 用户取消异常：先回滚到 locked
      // （fail-closed），通知监听者让 UI 停止转圈，再把异常交给调用方。
      _state = WebViewLockState.locked;
      notifyListeners();
      rethrow;
    }

    _state = ok ? WebViewLockState.unlocked : WebViewLockState.locked;
    notifyListeners();
    return ok;
  }

  @override
  void dispose() {
    if (_observing) {
      WidgetsBinding.instance.removeObserver(this);
      _observing = false;
    }
    super.dispose();
  }
}