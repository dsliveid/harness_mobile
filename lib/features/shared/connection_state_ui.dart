/// 连接态 → UI 呈现的**唯一映射表**（M5：连接态诚实化）。
///
/// 核心红线：**没有任何连接时，UI 绝对不能显示「已连接」**。
///
/// 为什么需要这层纯函数映射，而不是在 widget 里到处写 `if (state == live)`：
/// 1. `DeviceWsState` 有 6 个取值，散落的条件判断极易把
///    `connecting` / `handshaking` / `reconnecting` 全糊成一句「连接中」，
///    甚至误落进「已连接」分支 —— 用户据此以为一切正常，实际一帧都收不到；
/// 2. 纯函数可被穷举测试直接断言：6 个枚举值必须各有确定映射
///    （见 `test/features/connection_state_ui_test.dart`）；
/// 3. 文案集中一处，改措辞时不会漏改某个页面。
///
/// 语义口径（**勿按直觉简化**）：
/// - 只有 [DeviceWsState.live] 才能出现「已连接」；
/// - [DeviceWsState.handshaking] 虽然 TCP 已通，但**协议未就绪**
///   （welcome 未到，服务端还没承认本设备），绝不能算「已连接」；
/// - [DeviceWsState.dead] 是终态、且**多种死因**（升级 / 重新配对 /
///   被别处顶替 / 重试耗尽），每种都给出可执行的下一步动作。
library;

import 'package:flutter/material.dart';

import '../../data/ws/device_ws.dart';

/// 连接态在 UI 上的完整呈现（文案 + 颜色语义 + 是否可视为「已连接」）。
///
/// 做成值对象而不是散落常量：测试可以对**整个对象**做相等断言，
/// 任何字段被顺手改动都会立刻红灯。
@immutable
class ConnectionStateVisual {
  const ConnectionStateVisual({
    required this.label,
    required this.detail,
    required this.tone,
    required this.icon,
    required this.usable,
    this.actionHint,
  });

  /// 主文案（连接条上那一行字）。
  final String label;

  /// 补充说明（为什么是这个状态、正在做什么）。
  final String detail;

  /// 颜色语义（不是具体颜色，具体颜色由主题解析）。
  final ConnectionTone tone;

  final IconData icon;

  /// 是否可视为「可用连接」。
  ///
  /// **只有 [DeviceWsState.live] 为 true** —— 这是本文件的中心不变量，
  /// 测试用穷举断言把守它（`usable == (state == live)`）。
  final bool usable;

  /// 用户可执行的下一步（dead 等状态才有）。
  final String? actionHint;

  /// 是否允许在 UI 上出现「已连接」字样。
  ///
  /// 与 [usable] 同源但语义更窄：单独暴露是为了让测试直接断言
  /// 「disconnected / failed 状态下绝不出现已连接」，而不必推断文案。
  bool get maySayConnected => usable;

  @override
  bool operator ==(Object other) =>
      other is ConnectionStateVisual &&
      other.label == label &&
      other.detail == detail &&
      other.tone == tone &&
      other.icon == icon &&
      other.usable == usable &&
      other.actionHint == actionHint;

  @override
  int get hashCode =>
      Object.hash(label, detail, tone, icon, usable, actionHint);

  @override
  String toString() =>
      'ConnectionStateVisual($label, tone=${tone.name}, usable=$usable)';
}

/// 颜色语义（由主题解析成具体颜色，便于深色/浅色一致）。
enum ConnectionTone {
  /// 中性：尚未开始（用户主动停止）。
  neutral,

  /// 进行中：连接 / 握手 / 重连退避。
  progress,

  /// 健康：唯一可用的 live。
  good,

  /// 需要用户动作：dead（终态）。
  alert,
}

/// 连接态 → 视觉映射（**穷举 switch，新增枚举值会编译失败**）。
///
/// 用 `switch` 表达式而不是 Map 查找：漏掉新枚举值时期望「编译期报错」
/// 而不是「运行时 null → 静默回落到某个默认文案」。
ConnectionStateVisual visualForConnectionState(
  DeviceWsState state, {
  DeviceWsDeadReason? deadReason,
  int retryCount = 0,
}) {
  switch (state) {
    case DeviceWsState.disconnected:
      return const ConnectionStateVisual(
        label: '未连接',
        detail: '长连接已停止，实时状态不会更新',
        tone: ConnectionTone.neutral,
        icon: Icons.cloud_off_outlined,
        usable: false,
      );
    case DeviceWsState.connecting:
      return const ConnectionStateVisual(
        label: '正在连接',
        detail: '正在建立到服务端的长连接',
        tone: ConnectionTone.progress,
        icon: Icons.sync,
        usable: false,
      );
    case DeviceWsState.handshaking:
      // 铁律：TCP 通了 ≠ 已连接。welcome 未到之前服务端还没承认本设备，
      // 这时显示「已连接」是彻头彻尾的谎话。
      return const ConnectionStateVisual(
        label: '正在握手',
        detail: '连接已建立，正在等待服务端确认协议版本',
        tone: ConnectionTone.progress,
        icon: Icons.hourglass_top_outlined,
        usable: false,
      );
    case DeviceWsState.live:
      return const ConnectionStateVisual(
        label: '已连接',
        detail: '实时状态同步中',
        tone: ConnectionTone.good,
        icon: Icons.cloud_done_outlined,
        usable: true,
      );
    case DeviceWsState.reconnecting:
      return ConnectionStateVisual(
        label: '正在重连',
        detail: retryCount > 0
            ? '第 $retryCount 次重连尝试中，实时状态可能已过期'
            : '连接中断，正在重连，实时状态可能已过期',
        tone: ConnectionTone.progress,
        icon: Icons.autorenew,
        usable: false,
      );
    case DeviceWsState.dead:
      // dead 有 4 种死因，用户能做的动作完全不同 —— 必须分开说，
      // 一律糊成「连接失败」等于把排查成本全甩给用户。
      switch (deadReason) {
        case DeviceWsDeadReason.upgradeRequired:
          return const ConnectionStateVisual(
            label: '连接已停止',
            detail: '服务端协议版本与本 App 不兼容',
            tone: ConnectionTone.alert,
            icon: Icons.system_update_alt,
            usable: false,
            actionHint: '请升级 App 后重试',
          );
        case DeviceWsDeadReason.repairPairing:
          return const ConnectionStateVisual(
            label: '连接已停止',
            detail: '设备凭据已失效（可能被移除或撤销）',
            tone: ConnectionTone.alert,
            icon: Icons.link_off,
            usable: false,
            actionHint: '请回配对页重新配对',
          );
        case DeviceWsDeadReason.replacedElsewhere:
          return const ConnectionStateVisual(
            label: '连接已停止',
            detail: '本设备已在其他客户端上线',
            tone: ConnectionTone.alert,
            icon: Icons.devices_other_outlined,
            usable: false,
            actionHint: '如需在本机继续使用，请重新配对',
          );
        case DeviceWsDeadReason.maxRetriesExceeded:
        case null:
          return const ConnectionStateVisual(
            label: '连接已断开',
            detail: '多次重连均失败，已停止自动重连',
            tone: ConnectionTone.alert,
            icon: Icons.cloud_off,
            usable: false,
            actionHint: '请检查网络与服务端状态后手动重连',
          );
      }
  }
}

/// 语义化连接指示条（AppBar / 页面顶部用）。
///
/// 只读 [DeviceWsState]，**自己不做任何状态推断** —— 呈现完全由
/// [visualForConnectionState] 决定，避免「UI 与状态机各说一套」。
class ConnectionStateChip extends StatelessWidget {
  const ConnectionStateChip({
    super.key,
    required this.state,
    this.deadReason,
    this.retryCount = 0,
    this.compact = true,
  });

  final DeviceWsState state;
  final DeviceWsDeadReason? deadReason;
  final int retryCount;

  /// true 时只显示主文案（AppBar 用），false 时连 detail 一起显示。
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final visual = visualForConnectionState(
      state,
      deadReason: deadReason,
      retryCount: retryCount,
    );
    final color = _colorOf(theme, visual.tone);

    if (compact) {
      return Chip(
        avatar: Icon(visual.icon, size: 16, color: color),
        label: Text(visual.label),
        labelStyle: theme.textTheme.labelMedium?.copyWith(color: color),
        side: BorderSide(color: color.withValues(alpha: 0.4)),
        backgroundColor: color.withValues(alpha: 0.08),
        visualDensity: VisualDensity.compact,
      );
    }
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        border: Border(bottom: BorderSide(color: color.withValues(alpha: 0.3))),
      ),
      child: Row(
        children: <Widget>[
          Icon(visual.icon, size: 18, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  visual.label,
                  style: theme.textTheme.labelLarge?.copyWith(color: color),
                ),
                Text(visual.detail, style: theme.textTheme.bodySmall),
                if (visual.actionHint != null)
                  Text(
                    visual.actionHint!,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.error),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Color _colorOf(ThemeData theme, ConnectionTone tone) {
    switch (tone) {
      case ConnectionTone.neutral:
        return theme.colorScheme.outline;
      case ConnectionTone.progress:
        return theme.colorScheme.tertiary;
      case ConnectionTone.good:
        return theme.colorScheme.primary;
      case ConnectionTone.alert:
        return theme.colorScheme.error;
    }
  }
}
