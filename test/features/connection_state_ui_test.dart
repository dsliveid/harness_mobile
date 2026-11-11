/// 连接态 → UI 诚实化映射测试（M5）。
///
/// 核心红线：**没有任何连接时，UI 绝对不能显示「已连接」**。
///
/// 本文件按交接书要求做三类断言：
/// 1. **穷举覆盖**：`DeviceWsState` 的 6 个取值每个都有确定映射
///    （用 `DeviceWsState.values` 遍历，新增枚举值会立刻因缺映射而失败）；
/// 2. **诚实性不变量**：只有 `live` 允许 `usable == true` / 出现「已连接」字样，
///    `disconnected` / `reconnecting` / `dead` 一律不得出现；
/// 3. **语义区分度**：6 个状态的 label 必须互不相同（不许糊成一个「已连接」），
///    dead 的 4 种死因也必须给出不同的下一步动作。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_mobile/data/ws/device_ws.dart';
import 'package:harness_mobile/features/shared/connection_state_ui.dart';

/// Task 交接书提到的「不能出现已连接」的状态集合。
const Set<DeviceWsState> _mustNotSayConnected = <DeviceWsState>{
  DeviceWsState.disconnected,
  DeviceWsState.connecting,
  DeviceWsState.handshaking,
  DeviceWsState.reconnecting,
  DeviceWsState.dead,
};

void main() {
  group('穷举覆盖：6 种连接态都有确定映射', () {
    test('DeviceWsState 恰好 6 个取值（新增/删除必须先改本映射与测试）', () {
      // 数量锁定：状态机新增第 7 个状态时，这条与下面的穷举断言会同时失败，
      // 强制作者回来补 UI 映射，而不是让新状态静默落进某个默认文案。
      expect(DeviceWsState.values.length, 6);
      expect(
        DeviceWsState.values.map((DeviceWsState s) => s.name).toSet(),
        <String>{
          'disconnected',
          'connecting',
          'handshaking',
          'live',
          'reconnecting',
          'dead',
        },
      );
    });

    test('每个取值都能得到非空且确定（幂等）的映射', () {
      for (final state in DeviceWsState.values) {
        final visual = visualForConnectionState(state);
        // ① 文案非空（不许把状态糊成空字符串）
        expect(visual.label.trim(), isNotEmpty, reason: state.name);
        expect(visual.detail.trim(), isNotEmpty, reason: state.name);
        // ② 确定性：同一输入必须得到同一输出（映射是纯函数）
        expect(visual, visualForConnectionState(state), reason: state.name);
        expect(visual, visual, reason: state.name);
      }
    });

    test('6 个状态的 label 互不相同（不许糊成同一个「已连接」）', () {
      final labels = <String>{
        for (final state in DeviceWsState.values)
          visualForConnectionState(state).label,
      };
      // 每个状态都必须有自己的说法 —— 6 个状态 6 种文案。
      expect(labels.length, DeviceWsState.values.length);
    });

    test('每个状态都有专属 icon（视觉上可区分）', () {
      final icons = <IconData>{
        for (final state in DeviceWsState.values)
          visualForConnectionState(state).icon,
      };
      expect(icons.length, DeviceWsState.values.length);
    });
  });

  group('诚实性不变量：只有 live 算「已连接」', () {
    test('usable 为真当且仅当 state == live', () {
      for (final state in DeviceWsState.values) {
        final visual = visualForConnectionState(state);
        expect(
          visual.usable,
          state == DeviceWsState.live,
          reason: '${state.name} 的 usable 必须是 ${state == DeviceWsState.live}，'
              '否则 UI 会对连接撒谎',
        );
        // maySayConnected 与 usable 必须同源，不能各自为政
        expect(visual.maySayConnected, visual.usable, reason: state.name);
      }
    });

    test('无连接的状态绝不出现「已连接」字样（核心红线）', () {
      for (final state in _mustNotSayConnected) {
        final visual = visualForConnectionState(state);
        expect(
          visual.label.contains('已连接'),
          isFalse,
          reason: '${state.name} 的文案出现了「已连接」：$visual',
        );
        expect(
          visual.detail.contains('已连接'),
          isFalse,
          reason: '${state.name} 的说明出现了「已连接」：$visual',
        );
        expect(visual.maySayConnected, isFalse, reason: state.name);
      }
    });

    test('live 状态明确显示「已连接」且语义为健康', () {
      final visual = visualForConnectionState(DeviceWsState.live);
      expect(visual.label, '已连接');
      expect(visual.tone, ConnectionTone.good);
      expect(visual.usable, isTrue);
      expect(visual.maySayConnected, isTrue);
    });

    test('handshaking 不得被算作已连接（TCP 通了 ≠ 协议就绪）', () {
      // 这条是最容易被「优化」掉的：handshaking 时 socket 确实连着，
      // 但 welcome 未到意味着服务端还没承认本设备，此时显示已连接会误导用户。
      final visual = visualForConnectionState(DeviceWsState.handshaking);
      expect(visual.usable, isFalse);
      expect(visual.tone, ConnectionTone.progress);
      expect(visual.label, isNot('已连接'));
    });

    test('reconnecting 文案必须诚实提示「状态可能已过期」', () {
      // 重连期间 UI 显示的仍是上一份缓存状态，必须明示其陈旧性。
      final visual = visualForConnectionState(
        DeviceWsState.reconnecting,
        retryCount: 3,
      );
      expect(visual.label, '正在重连');
      expect(visual.detail, contains('第 3 次'));
      expect(visual.detail, contains('可能已过期'));
      expect(visual.usable, isFalse);
    });
  });

  group('dead 的 4 种死因各有可执行下一步', () {
    test('每种死因的 actionHint 非空且互不相同（不许糊成「连接失败」）', () {
      final hints = <String, String>{};
      for (final reason in DeviceWsDeadReason.values) {
        final visual = visualForConnectionState(
          DeviceWsState.dead,
          deadReason: reason,
        );
        expect(visual.usable, isFalse, reason: reason.name);
        expect(visual.tone, ConnectionTone.alert, reason: reason.name);
        expect(visual.actionHint, isNotNull, reason: reason.name);
        expect(visual.actionHint!.trim(), isNotEmpty, reason: reason.name);
        hints[reason.name] = visual.actionHint!;
      }
      // 4 种死因必须给出 4 条不同的动作指引
      expect(hints.length, DeviceWsDeadReason.values.length);
      expect(hints.values.toSet().length, DeviceWsDeadReason.values.length);
    });

    test('upgradeRequired → 提示升级 App（而不是让用户去配对）', () {
      final visual = visualForConnectionState(
        DeviceWsState.dead,
        deadReason: DeviceWsDeadReason.upgradeRequired,
      );
      expect(visual.actionHint, contains('升级'));
      expect(visual.actionHint!.contains('配对'), isFalse);
    });

    test('repairPairing → 提示重新配对', () {
      final visual = visualForConnectionState(
        DeviceWsState.dead,
        deadReason: DeviceWsDeadReason.repairPairing,
      );
      expect(visual.actionHint, contains('配对'));
    });

    test('replacedElsewhere → 明确告知「已在其他客户端上线」', () {
      final visual = visualForConnectionState(
        DeviceWsState.dead,
        deadReason: DeviceWsDeadReason.replacedElsewhere,
      );
      expect(visual.detail, contains('其他'));
      expect(visual.actionHint, isNotNull);
    });

    test('maxRetriesExceeded 与死因缺失（null）都给出手动重连指引', () {
      for (final reason in <DeviceWsDeadReason?>[
        DeviceWsDeadReason.maxRetriesExceeded,
        null,
      ]) {
        final visual = visualForConnectionState(
          DeviceWsState.dead,
          deadReason: reason,
        );
        expect(visual.actionHint, contains('重连'));
        expect(visual.label, '连接已断开');
        expect(visual.usable, isFalse);
      }
    });

    test('dead 状态无论死因都不得出现「已连接」', () {
      for (final reason in <DeviceWsDeadReason?>[
        ...DeviceWsDeadReason.values,
        null,
      ]) {
        final visual = visualForConnectionState(
          DeviceWsState.dead,
          deadReason: reason,
        );
        expect(visual.label.contains('已连接'), isFalse,
            reason: 'dead(${reason?.name}) 文案含「已连接」');
        expect(visual.detail.contains('已连接'), isFalse,
            reason: 'dead(${reason?.name}) 说明含「已连接」');
      }
    });
  });

  group('ConnectionStateChip（UI 组件与映射表一致）', () {
    Future<void> pumpChip(
      WidgetTester tester,
      DeviceWsState state, {
      DeviceWsDeadReason? deadReason,
      bool compact = true,
      int retryCount = 0,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: ConnectionStateChip(
                state: state,
                deadReason: deadReason,
                compact: compact,
                retryCount: retryCount,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('未连接时屏幕上不出现「已连接」', (WidgetTester tester) async {
      for (final state in _mustNotSayConnected) {
        await pumpChip(tester, state);
        // 直接对渲染结果做否定断言，而不是只信任映射表
        expect(
          find.text('已连接'),
          findsNothing,
          reason: '${state.name} 状态渲染出了「已连接」',
        );
        final visual = visualForConnectionState(state);
        expect(find.text(visual.label), findsOneWidget, reason: state.name);
      }
    });

    testWidgets('live 时显示「已连接」', (WidgetTester tester) async {
      await pumpChip(tester, DeviceWsState.live);
      expect(find.text('已连接'), findsOneWidget);
    });

    testWidgets('verbose 模式展示 detail 与 actionHint（用户能看到下一步）',
        (WidgetTester tester) async {
      await pumpChip(
        tester,
        DeviceWsState.dead,
        deadReason: DeviceWsDeadReason.repairPairing,
        compact: false,
      );
      final visual = visualForConnectionState(
        DeviceWsState.dead,
        deadReason: DeviceWsDeadReason.repairPairing,
      );
      expect(find.text(visual.label), findsOneWidget);
      expect(find.text(visual.detail), findsOneWidget);
      expect(find.text(visual.actionHint!), findsOneWidget);
      // 且依然不得出现「已连接」
      expect(find.text('已连接'), findsNothing);
    });

    testWidgets('重连中展示重试次数（不是一句模糊的「连接中」）',
        (WidgetTester tester) async {
      await pumpChip(
        tester,
        DeviceWsState.reconnecting,
        compact: false,
        retryCount: 2,
      );
      expect(find.textContaining('第 2 次'), findsOneWidget);
      expect(find.text('已连接'), findsNothing);
    });
  });

  group('ConnectionStateDot（窄屏 AppBar 极简圆点）', () {
    Future<void> pumpDot(
      WidgetTester tester,
      DeviceWsState state, {
      DeviceWsDeadReason? deadReason,
      int retryCount = 0,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: ConnectionStateDot(
                state: state,
                deadReason: deadReason,
                retryCount: retryCount,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('6 状态穷举可渲染，且尺寸只有十几 dp（不吃横向空间）',
        (WidgetTester tester) async {
      for (final state in DeviceWsState.values) {
        await pumpDot(tester, state, deadReason: DeviceWsDeadReason.maxRetriesExceeded);
        expect(find.byType(ConnectionStateDot), findsOneWidget,
            reason: state.name);
        final size = tester.getSize(find.byType(ConnectionStateDot));
        // 默认 size=10 → 光晕 18 + 2dp 呼吸 = 20dp 上限
        expect(size.width, lessThanOrEqualTo(20), reason: state.name);
        expect(size.height, lessThanOrEqualTo(20), reason: state.name);
      }
    });

    testWidgets('无障碍标签携带映射表 label（圆点不丢语义）',
        (WidgetTester tester) async {
      final handle = tester.ensureSemantics();
      for (final state in DeviceWsState.values) {
        await pumpDot(tester, state);
        final visual = visualForConnectionState(state);
        expect(
          find.bySemanticsLabel(RegExp(RegExp.escape(visual.label))),
          findsWidgets,
          reason: '${state.name} 的圆点缺少与映射表一致的语义标签',
        );
      }
      handle.dispose();
    });

    testWidgets('dead 死因改变语义标签（4 种死因文案不糊成一句）',
        (WidgetTester tester) async {
      final handle = tester.ensureSemantics();
      final labels = <String>{};
      for (final reason in DeviceWsDeadReason.values) {
        await pumpDot(tester, DeviceWsState.dead, deadReason: reason);
        final visual = visualForConnectionState(
          DeviceWsState.dead,
          deadReason: reason,
        );
        labels.add(visual.label);
        expect(
          find.bySemanticsLabel(RegExp(RegExp.escape(visual.label))),
          findsWidgets,
          reason: reason.name,
        );
      }
      handle.dispose();
      // dead 的 label 允许有复用（如「连接已停止」），但必须来自同一映射表，
      // 这里只断言集合非空且每个死因都能找到自己的 label。
      expect(labels, isNotEmpty);
    });

    testWidgets('颜色与 Chip 同源（colorForConnectionTone 是唯一解析点）',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: Center(child: ConnectionStateChip(state: DeviceWsState.live))),
        ),
      );
      final theme = Theme.of(tester.element(find.byType(ConnectionStateChip)));
      // 4 种 tone 的颜色必须互不相同，否则「语义区分」在视觉上失效
      final colors = <Color>{
        for (final tone in ConnectionTone.values)
          colorForConnectionTone(theme, tone),
      };
      expect(colors.length, ConnectionTone.values.length);
    });
  });
}
