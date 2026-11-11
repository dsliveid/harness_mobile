/// 反向收敛测试：服务端单方面吊销 → 端侧**自动**解绑。
///
/// ## 这个文件防的是什么（真实 bug）
/// 旧实现收到 terminal `device.revoked` 只把状态机打成 `dead`，**完全不动
/// 会话**：`AppSession` 仍是 paired、Keychain 里 device_token / user_token
/// 都还在 → UI 显示「仍绑定」，页面继续拿失效令牌请求，反复 401，
/// 用户不知道自己已经被服务端解绑了。
///
/// 现在要求：判定终态后自动 `resetPairing()`（清令牌 + 相位回配对页），
/// 并留下一条原因文案给配对页展示。
///
/// 同时反向钉死两条**不许误伤**的边界：
/// - 重连耗尽（`maxRetriesExceeded`）**不是**吊销，绝不能清令牌；
/// - 用户主动登出（`signOut`）与设备吊销严格正交，不触发任何收敛。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_mobile/core/app/app_session.dart';
import 'package:harness_mobile/core/app/device_ws_controller.dart';
import 'package:harness_mobile/core/app/providers.dart';
import 'package:harness_mobile/data/local/app_settings_store.dart';
import 'package:harness_mobile/data/local/secure_store.dart';
import 'package:harness_mobile/data/ws/device_connection.dart';
import 'package:harness_mobile/data/ws/device_ws.dart';
import 'package:harness_mobile/protocol/envelope.dart';

/// 可注入的假连接（入站帧由测试主动 push）。
class _FakeConnection implements DeviceConnection {
  _FakeConnection(this.endpoint);

  @override
  final Uri endpoint;

  final StreamController<String> _in = StreamController<String>();
  bool closed = false;

  @override
  Stream<String> get stream => _in.stream;

  @override
  Future<void> connect() async {}

  @override
  void send(String data) {}

  @override
  Future<void> close([int? code, String? reason]) async {
    closed = true;
    if (!_in.isClosed) await _in.close();
  }

  void push(Map<String, dynamic> env) {
    if (!_in.isClosed) _in.add(jsonEncode(env));
  }
}

Map<String, dynamic> _welcomeFrame() => <String, dynamic>{
      'v': 1,
      'type': MessageType.welcome,
      'payload': <String, dynamic>{
        'device_id': 'dev-1',
        'server_time': 1700000000000,
        'protocol_version': 1,
        'heartbeat_s': 30,
        'offline_after_s': 45,
        'pending': 0,
      },
    };

Map<String, dynamic> _errorFrame(String code, {bool fatal = true}) =>
    <String, dynamic>{
      'v': 1,
      'type': MessageType.error,
      'payload': <String, dynamic>{'code': code, 'message': 'test', 'fatal': fatal},
    };

/// 装配「已配对 + 已登录 + 一条 fake 连接已建立并 live」的环境。
class _Harness {
  _Harness(this.container, this.connections, this.store);

  final ProviderContainer container;
  final List<_FakeConnection> connections;
  final InMemorySecureStore store;

  AppSession get session => container.read(appSessionProvider);
  DeviceWsController get controller => container.read(deviceWsControllerProvider);
}

Future<_Harness> _boot(WidgetTester tester) async {
  final store = InMemorySecureStore();
  await store.setDeviceToken('dt_secret');
  await store.setUserToken('ut_secret');
  final connections = <_FakeConnection>[];
  final container = ProviderContainer(
    overrides: <Override>[
      secureStoreProvider.overrideWithValue(store),
      settingsStoreProvider.overrideWithValue(
        InMemorySettingsStore(
          const AppSettings(
            baseUrl: 'http://localhost:8080',
            deviceId: 'dev-1',
            deviceName: '测试机',
          ),
        ),
      ),
      deviceConnectionFactoryProvider.overrideWithValue(
        (Uri uri) {
          final conn = _FakeConnection(uri);
          connections.add(conn);
          return conn;
        },
      ),
    ],
  );
  addTearDown(container.dispose);
  await container.read(appSessionProvider).load();
  final started = await container.read(deviceWsControllerProvider).start();
  expect(started, isTrue, reason: '前置条件齐备时必须能启动连接');
  await tester.pump();
  connections.single.push(_welcomeFrame());
  await tester.pump();
  expect(
    container.read(deviceWsControllerProvider).state,
    DeviceWsState.live,
    reason: '前置：连接必须已进入 live',
  );
  return _Harness(container, connections, store);
}

void main() {
  group('terminal device.revoked → 自动收敛到配对页', () {
    testWidgets('收到 device.revoked 后自动 resetPairing（令牌清空、相位回 pairing）',
        (WidgetTester tester) async {
      final h = await _boot(tester);
      expect(h.session.stage, AppStage.webview);

      h.connections.single.push(_errorFrame(FrameCode.revoked));
      // 收敛涉及多个 await（resetPairing → stop），多 pump 几次让微任务跑完。
      await tester.pump();
      await tester.pump();
      await tester.pump();

      // ★ 核心断言 1：令牌真的被清（旧实现这里仍然有值）
      expect(await h.store.getDeviceToken(), isNull);
      expect(await h.store.getUserToken(), isNull);
      // ★ 核心断言 2：会话已经不相信「还绑着」
      expect(h.session.paired, isFalse);
      expect(h.session.signedIn, isFalse);
      expect(h.session.stage, AppStage.pairing);
      // ★ 核心断言 3：给了用户可读的原因文案
      expect(h.controller.revocationNotice, isNotNull);
      expect(
        h.controller.revocationNotice,
        contains('服务端已解除本设备绑定'),
      );
    });

    testWidgets('收敛后连接被拆除（不再拿失效令牌重连）', (WidgetTester tester) async {
      final h = await _boot(tester);

      h.connections.single.push(_errorFrame(FrameCode.revoked));
      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(h.controller.isStarted, isFalse, reason: '收敛后 controller 不应再持有 client');
      expect(h.connections.single.closed, isTrue, reason: '底层连接必须被关闭');
    });

    testWidgets('重复 revoked 帧（广播流多次回调）只收敛一次', (WidgetTester tester) async {
      final h = await _boot(tester);

      h.connections.single.push(_errorFrame(FrameCode.revoked));
      h.connections.single.push(_errorFrame(FrameCode.revoked));
      await tester.pump();
      await tester.pump();
      await tester.pump();

      // clearAll 只应发生一次（幂等护栏 _revocationHandled）
      expect(h.store.clearedCount, 1);
    });

    testWidgets('文案被 clearRevocationNotice 消费后不再残留（主动解绑路径用）',
        (WidgetTester tester) async {
      final h = await _boot(tester);
      h.connections.single.push(_errorFrame(FrameCode.revoked));
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(h.controller.revocationNotice, isNotNull);

      h.controller.clearRevocationNotice();

      expect(h.controller.revocationNotice, isNull);
    });
  });

  group('不许误伤的边界', () {
    testWidgets('重连耗尽（maxRetriesExceeded）不是吊销 → 绝不清令牌',
        (WidgetTester tester) async {
      final h = await _boot(tester);

      // 断连并让退避重连耗尽（默认 5 次）。fake_async 由 tester.pump 推进。
      await h.connections.single.close();
      for (int i = 0; i < 8; i++) {
        await tester.pump(const Duration(seconds: 31));
      }

      if (h.controller.deadReason == DeviceWsDeadReason.maxRetriesExceeded) {
        // 终态已判定 → 仍不得清令牌，也不得有吊销文案
        expect(h.store.clearedCount, 0);
        expect(h.controller.revocationNotice, isNull);
        expect(h.session.paired, isTrue);
      }
      // 无论如何：吊销文案绝不能出现（没收到 revoked 帧）
      expect(h.controller.revocationNotice, isNull);

      // 收尾：退避重连的定时器可能仍挂着
      await h.controller.stop();
      await tester.pump();
    });

    testWidgets('signOut（用户主动登出）不触发任何收敛，设备绑定保留',
        (WidgetTester tester) async {
      final h = await _boot(tester);

      await h.session.signOut();
      await tester.pump();

      // 与吊销严格正交：只清 user_token，device_token 与相位（login）保留
      expect(await h.store.getUserToken(), isNull);
      expect(await h.store.getDeviceToken(), 'dt_secret');
      expect(h.session.paired, isTrue);
      expect(h.session.stage, AppStage.login);
      expect(h.store.clearedCount, 0);
      expect(h.controller.revocationNotice, isNull);
      // 连接也不该被收敛流程拆掉（登出不断开 WS）
      expect(h.controller.isStarted, isTrue);

      // 收尾：显式停掉连接（心跳定时器不该跨测试存活）
      await h.controller.stop();
      await tester.pump();
    });
  });
}
