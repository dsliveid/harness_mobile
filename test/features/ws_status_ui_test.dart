/// 设备长连接「上屏」语义测试。
///
/// 覆盖三件事：
/// 1. `ConnectionStateChip` 在 `WebViewPage` 里**真的被挂载**（此前该组件
///    生产代码零调用，属于「写了但没接线」的典型）；
/// 2. 状态映射诚实例外：未连接 / 连接中 / 已连接 / dead 各有确定文案，
///    且**只有 live 才允许出现「已连接」**（`connection_state_ui_test.dart`
///    已守住纯函数层，这里守住页面层）；
/// 3. `DeviceWsController` 的启动前置条件：无 baseUrl / 无 device_token
///    时必须**不启动**（避免拿必 401 的连接去打满服务端日志）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_mobile/core/app/providers.dart';
import 'package:harness_mobile/data/local/app_settings_store.dart';
import 'package:harness_mobile/data/local/secure_store.dart';
import 'package:harness_mobile/data/ws/device_ws.dart';
import 'package:harness_mobile/features/shared/connection_state_ui.dart';

/// 造一个没有任何凭据的空存储（用于验证「不启动」的分支）。
ProviderContainer _emptyContainer({String baseUrl = '', String deviceId = ''}) {
  final store = InMemorySecureStore();
  final container = ProviderContainer(
    overrides: <Override>[
      secureStoreProvider.overrideWithValue(store),
      settingsStoreProvider.overrideWithValue(
        InMemorySettingsStore(
          AppSettings(baseUrl: baseUrl, deviceId: deviceId, deviceName: '测试机'),
        ),
      ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  group('DeviceWsController：启动前置条件（绝不盲目连）', () {
    test('无 baseUrl → 不启动（返回 false，状态仍 disconnected）', () async {
      final container = _emptyContainer();
      await container.read(appSessionProvider).load();
      final ok = await container.read(deviceWsControllerProvider).start();
      expect(ok, isFalse);
      expect(
        container.read(deviceWsControllerProvider).state,
        DeviceWsState.disconnected,
      );
      expect(container.read(deviceWsControllerProvider).isStarted, isFalse);
    });

    test('有 baseUrl 但未配对（无 deviceId）→ 不启动', () async {
      final container = _emptyContainer(baseUrl: 'http://localhost:8080');
      await container.read(appSessionProvider).load();
      expect(await container.read(deviceWsControllerProvider).start(), isFalse);
    });

    test('已配对但 Keychain 里没有 device_token → 不启动（这点最关键）', () async {
      // 这是 signOut 旧实现留下的真实场景：Settings 说已配对，
      // 但 device_token 已被 clearAll 抹掉。此时绝不能建连接。
      final container = _emptyContainer(
        baseUrl: 'http://localhost:8080',
        deviceId: 'dev-1',
      );
      await container.read(appSessionProvider).load();
      final ok = await container.read(deviceWsControllerProvider).start();
      expect(ok, isFalse, reason: '无 device_token 时必须拒绝启动，否则必然 401');
      expect(
        container.read(deviceWsControllerProvider).state,
        DeviceWsState.disconnected,
      );
    });

    test('启动前 state 恒为 disconnected（不会误报已连接）', () {
      final container = _emptyContainer();
      final controller = container.read(deviceWsControllerProvider);
      expect(controller.state, DeviceWsState.disconnected);
      expect(controller.isStarted, isFalse);
      expect(controller.retryCount, 0);
      expect(controller.heartbeatInterval, isNull);
      expect(controller.welcome, isNull);
    });

    test('stop() 在未启动时幂等无害', () async {
      final container = _emptyContainer();
      final controller = container.read(deviceWsControllerProvider);
      await controller.stop();
      await controller.stop(); // 第二次不得抛
      expect(controller.isStarted, isFalse);
    });
  });

  group('ConnectionStateChip：诚实文案（只有 live 才说「已连接」）', () {
    Future<void> pumpChip(
      WidgetTester tester,
      DeviceWsState state, {
      DeviceWsDeadReason? reason,
      int retryCount = 0,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ConnectionStateChip(
              state: state,
              deadReason: reason,
              retryCount: retryCount,
            ),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('disconnected → 未连接（绝无「已连接」字样）', (WidgetTester tester) async {
      await pumpChip(tester, DeviceWsState.disconnected);
      expect(find.text('未连接'), findsOneWidget);
      expect(find.text('已连接'), findsNothing);
    });

    testWidgets('handshaking → 正在握手（TCP 通了也不算已连接）',
        (WidgetTester tester) async {
      await pumpChip(tester, DeviceWsState.handshaking);
      expect(find.text('正在握手'), findsOneWidget);
      expect(find.text('已连接'), findsNothing);
    });

    testWidgets('live → 已连接（唯一允许出现的场景）', (WidgetTester tester) async {
      await pumpChip(tester, DeviceWsState.live);
      expect(find.text('已连接'), findsOneWidget);
    });

    testWidgets('reconnecting → 正在重连，带次数', (WidgetTester tester) async {
      await pumpChip(tester, DeviceWsState.reconnecting, retryCount: 3);
      expect(find.text('正在重连'), findsOneWidget);
      expect(find.text('已连接'), findsNothing);
    });

    testWidgets('dead + repairPairing → 主文案为「连接已停止」（不谎称已连接）',
        (WidgetTester tester) async {
      await pumpChip(
        tester,
        DeviceWsState.dead,
        reason: DeviceWsDeadReason.repairPairing,
      );
      expect(find.text('连接已停止'), findsOneWidget);
      // compact chip 只渲染主文案；actionHint（"请回配对页重新配对"）
      // 属非 compact 模式的 detail 区，由纯函数层单独断言。
      expect(find.text('已连接'), findsNothing);
    });

    testWidgets('dead + upgradeRequired → 主文案为「连接已停止」', (WidgetTester tester) async {
      await pumpChip(
        tester,
        DeviceWsState.dead,
        reason: DeviceWsDeadReason.upgradeRequired,
      );
      expect(find.text('连接已停止'), findsOneWidget);
      expect(find.text('已连接'), findsNothing);
    });

    test('dead 的 4 种死因各有可执行 actionHint（非 compact 才展示）', () {
      // compact chip 不渲染 actionHint，故这里在纯函数层把守：
      // 「死因必须能变成用户能执行的下一步动作」，不能只糊一句「连接失败」。
      final expectations = <DeviceWsDeadReason, String>{
        DeviceWsDeadReason.upgradeRequired: '升级',
        DeviceWsDeadReason.repairPairing: '重新配对',
        DeviceWsDeadReason.replacedElsewhere: '重新配对',
        DeviceWsDeadReason.maxRetriesExceeded: '检查网络',
      };
      for (final MapEntry<DeviceWsDeadReason, String> e in expectations.entries) {
        final visual = visualForConnectionState(
          DeviceWsState.dead,
          deadReason: e.key,
        );
        expect(visual.actionHint, isNotNull, reason: '${e.key.name} 缺少 actionHint');
        expect(
          visual.actionHint,
          contains(e.value),
          reason: '${e.key.name} 的 actionHint 应可执行',
        );
      }
    });

    testWidgets('只有 live 时 usable 为真（穷举 6 态）', (WidgetTester tester) async {
      // 这条是「诚实化」的中心不变量，页面层再守一遍。
      for (final DeviceWsState s in DeviceWsState.values) {
        final visual = visualForConnectionState(s);
        expect(
          visual.usable,
          s == DeviceWsState.live,
          reason: '仅 live 可用，但 ${s.name} 的 usable=${visual.usable}',
        );
        expect(visual.maySayConnected, s == DeviceWsState.live);
      }
    });
  });
}
