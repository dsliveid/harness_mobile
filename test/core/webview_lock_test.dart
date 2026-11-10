/// WebView 解锁门（[WebViewLock]）安全语义测试（批次 C-2）。
///
/// 覆盖架构文档 §4.7.1 / §6.3 决策 3 的三条铁律：
/// 1. **fail-closed**：生物识别失败 / 抛异常 / 拿不到结果 → 必须保持锁定，
///    绝不降级为密码、绝不默认放行；
/// 2. **手动锁定与回前台锁定**：切后台超过 [WebViewLock.relockAfter] 才重锁，
///    短暂切走不骚扰用户；`inactive`（来电/下拉通知）**不得**当锁；
/// 3. **并发保护**：`authenticating` 期间重复触发必须直接返回 false，
///    避免连点弹出多个系统验证框。
///
/// 全部用假 [BiometricGate] 注入，不碰 local_auth 平台插件。
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_mobile/core/app/biometric_gate.dart';
import 'package:harness_mobile/core/app/webview_lock.dart';

/// 可编排的假闸门：可控返回值、可控抛错、可控调用次数与耗时。
class _ScriptedGate implements BiometricGate {
  _ScriptedGate({this.results = const <bool>[true], this.throwing = false});

  /// 依次返回的判定结果（用完后重复最后一个）。
  final List<bool> results;

  /// true 时抛异常（模拟插件崩溃 / 用户取消异常）。
  ///
  /// 非 final：用例需要模拟「闸门第一次崩溃、随后恢复」的场景
  /// （验证状态机在异常后能自愈，而不是把用户永久锁死）。
  bool throwing;

  int calls = 0;
  final List<String> reasons = <String>[];

  /// 非空时在 authenticate 内等待该时长（模拟系统验证框未关闭）。
  Duration? delay;

  @override
  Future<bool> authenticate({required String reason}) async {
    calls++;
    reasons.add(reason);
    if (delay != null) {
      await Future<void>.delayed(delay!);
    }
    if (throwing) {
      throw StateError('插件崩溃');
    }
    final index = calls - 1 < results.length ? calls - 1 : results.length - 1;
    return results[index];
  }
}

void main() {
  // WebViewLock.startObserving() 内部调用 WidgetsBinding.instance，
  // 纯 Dart 测试环境必须先初始化 binding。
  TestWidgetsFlutterBinding.ensureInitialized();

  group('冷启动与手动解锁', () {
    test('默认 locked，解锁成功后转 unlocked（且 isLocked 跟随）', () async {
      final gate = _ScriptedGate(results: <bool>[true]);
      final lock = WebViewLock(gate: gate);
      addTearDown(lock.dispose);

      expect(lock.state, WebViewLockState.locked);
      expect(lock.isLocked, isTrue);

      final ok = await lock.unlock();

      expect(ok, isTrue);
      expect(lock.state, WebViewLockState.unlocked);
      expect(lock.isLocked, isFalse);
      expect(gate.calls, 1);
      // 必须向系统验证框提供可读理由（否则用户不知道在验什么）
      expect(gate.reasons.single.isNotEmpty, isTrue);
    });

    test('fail-closed：验证返回 false → 保持 locked 且返回 false', () async {
      final gate = _ScriptedGate(results: <bool>[false]);
      final lock = WebViewLock(gate: gate);
      addTearDown(lock.dispose);

      final ok = await lock.unlock();

      expect(ok, isFalse);
      expect(lock.state, WebViewLockState.locked);
      expect(lock.isLocked, isTrue);
    });

    test('fail-closed：闸门抛异常 → 异常上抛，状态回滚 locked 且绝不解锁', () async {
      final gate = _ScriptedGate(throwing: true);
      final lock = WebViewLock(gate: gate);
      addTearDown(lock.dispose);

      final states = <WebViewLockState>[];
      lock.addListener(() => states.add(lock.state));

      await expectLater(lock.unlock(), throwsStateError);
      // fail-closed：无论内部状态如何，绝不能变成 unlocked
      expect(lock.state, isNot(WebViewLockState.unlocked));
      expect(lock.state, WebViewLockState.locked,
          reason: '异常路径必须回滚到 locked，不能停在 authenticating');
      // UI 必须收到「停止转圈」的通知：authenticating → locked
      expect(states, <WebViewLockState>[
        WebViewLockState.authenticating,
        WebViewLockState.locked,
      ]);
    });

    // 回归守护（原为「［已知缺陷·锁定现状］」，lib 修复后改写为正确行为断言）。
    //
    // 历史缺陷（已修复，勿回退）：`lib/core/app/webview_lock.dart` 的 `unlock()`
    //   在 `_gate.authenticate()` 抛异常时没有回滚 `_state`，永久停在
    //   authenticating；而 `unlock()` 首行 `if (_state == authenticating) return false;`
    //   会让此后**任何** unlock 都直接返回 false —— 用户被硬锁死在门外且按钮永久转圈。
    // 修复：异常分支先回滚到 locked + notifyListeners，再 rethrow 交给调用方提示。
    // 本用例断言修复后的正确行为：异常后状态自愈，下一次 unlock 仍可重试成功。
    test('闸门抛异常后状态自愈：下一次 unlock 仍可重试并成功', () async {
      final gate = _ScriptedGate(throwing: true);
      final lock = WebViewLock(gate: gate);
      addTearDown(lock.dispose);

      await expectLater(lock.unlock(), throwsStateError);
      expect(lock.state, WebViewLockState.locked);

      // 闸门恢复（插件重启 / 用户重新验证）后，用户必须还能进得去
      gate.throwing = false;
      final ok = await lock.unlock();

      expect(ok, isTrue);
      expect(lock.state, WebViewLockState.unlocked);
      expect(gate.calls, 2, reason: '第二次 unlock 必须真的再次调用闸门，而不是被静默拒绝');
    });

    test('unlock 过程会先置 authenticating 再落终态（不是一步跳变）', () async {
      final gate = _ScriptedGate(results: <bool>[true])
        ..delay = const Duration(milliseconds: 20);
      final lock = WebViewLock(gate: gate);
      addTearDown(lock.dispose);

      final states = <WebViewLockState>[];
      lock.addListener(() => states.add(lock.state));

      await lock.unlock();

      expect(states, <WebViewLockState>[
        WebViewLockState.authenticating,
        WebViewLockState.unlocked,
      ]);
    });

    test('并发保护：authenticating 期间重复 unlock 直接返回 false（不重复弹框）',
        () async {
      final gate = _ScriptedGate(results: <bool>[true])
        ..delay = const Duration(milliseconds: 30);
      final lock = WebViewLock(gate: gate);
      addTearDown(lock.dispose);

      final first = lock.unlock();
      // 第二个请求在第一次尚未返回时发起
      final second = await lock.unlock();

      expect(second, isFalse, reason: '重复触发必须被当场拒绝');
      expect(await first, isTrue);
      expect(gate.calls, 1, reason: '系统验证框只能弹一次');
    });

    test('已解锁后再 unlock 仍会再验一次（宁可多验不默认放行）', () async {
      final gate = _ScriptedGate(results: <bool>[true, true]);
      final lock = WebViewLock(
        gate: gate,
        initial: WebViewLockState.unlocked,
      );
      addTearDown(lock.dispose);

      expect(lock.isLocked, isFalse);
      expect(await lock.unlock(), isTrue);
      expect(gate.calls, 1);
    });
  });

  group('手动锁定', () {
    test('lock() 后立即变 locked 并通知监听者', () async {
      final lock = WebViewLock(
        gate: _ScriptedGate(),
        initial: WebViewLockState.unlocked,
      );
      addTearDown(lock.dispose);

      var notified = 0;
      lock.addListener(() => notified++);

      lock.lock();

      expect(lock.state, WebViewLockState.locked);
      expect(lock.isLocked, isTrue);
      expect(notified, 1);
    });

    test('已 locked 时再 lock() 不重复通知（避免无意义重建）', () {
      final lock = WebViewLock(gate: _ScriptedGate());
      addTearDown(lock.dispose);

      var notified = 0;
      lock.addListener(() => notified++);

      lock.lock();

      expect(lock.state, WebViewLockState.locked);
      expect(notified, 0);
    });
  });

  group('生命周期：回前台重锁', () {
    test('切后台超过 relockAfter → 回前台自动上锁', () async {
      final lock = WebViewLock(
        gate: _ScriptedGate(),
        initial: WebViewLockState.unlocked,
        relockAfter: const Duration(milliseconds: 30),
      );
      addTearDown(lock.dispose);

      lock.didChangeAppLifecycleState(AppLifecycleState.paused);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      lock.didChangeAppLifecycleState(AppLifecycleState.resumed);

      expect(lock.state, WebViewLockState.locked);
    });

    test('短暂切走（未超过 relockAfter）→ 回前台不重锁（不骚扰用户）', () async {
      final lock = WebViewLock(
        gate: _ScriptedGate(),
        initial: WebViewLockState.unlocked,
        relockAfter: const Duration(seconds: 5),
      );
      addTearDown(lock.dispose);

      lock.didChangeAppLifecycleState(AppLifecycleState.paused);
      lock.didChangeAppLifecycleState(AppLifecycleState.resumed);

      expect(lock.state, WebViewLockState.unlocked);
    });

    test('inactive（来电/下拉通知）绝不当锁', () {
      final lock = WebViewLock(
        gate: _ScriptedGate(),
        initial: WebViewLockState.unlocked,
        // 故意设 0：若实现把 inactive 当后台就会立刻重锁，从而暴露该缺陷
        relockAfter: Duration.zero,
      );
      addTearDown(lock.dispose);

      lock.didChangeAppLifecycleState(AppLifecycleState.inactive);
      lock.didChangeAppLifecycleState(AppLifecycleState.resumed);

      expect(
        lock.state,
        WebViewLockState.unlocked,
        reason: 'inactive 是瞬时态，不得触发重锁',
      );
    });

    test('未进过后台直接 resumed 不重锁（无 _backgroundAt 基准）', () {
      final lock = WebViewLock(
        gate: _ScriptedGate(),
        initial: WebViewLockState.unlocked,
        relockAfter: Duration.zero,
      );
      addTearDown(lock.dispose);

      lock.didChangeAppLifecycleState(AppLifecycleState.resumed);

      expect(lock.state, WebViewLockState.unlocked);
    });

    test('hidden 也算进后台（Android 12+ 新语义）', () async {
      final lock = WebViewLock(
        gate: _ScriptedGate(),
        initial: WebViewLockState.unlocked,
        relockAfter: const Duration(milliseconds: 20),
      );
      addTearDown(lock.dispose);

      lock.didChangeAppLifecycleState(AppLifecycleState.hidden);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      lock.didChangeAppLifecycleState(AppLifecycleState.resumed);

      expect(lock.state, WebViewLockState.locked);
    });
  });

  group('观察者注册安全', () {
    test('startObserving 幂等，dispose 后再也不会重复摘除', () {
      final lock = WebViewLock(
        gate: _ScriptedGate(),
        initial: WebViewLockState.unlocked,
      );

      lock.startObserving();
      lock.startObserving(); // 第二次必须无副作用
      // dispose 内部只在 _observing 为真时摘除；重复调用不应抛异常
      lock.dispose();
      expect(lock.state, WebViewLockState.unlocked);
    });

    test('未 startObserving 时 dispose 不抛异常', () {
      final lock = WebViewLock(gate: _ScriptedGate());
      expect(lock.dispose, returnsNormally);
    });
  });
}
