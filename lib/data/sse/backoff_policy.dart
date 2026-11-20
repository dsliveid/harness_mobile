/// 退避策略（纯函数，零 IO / 零 Flutter 依赖）。
///
/// # 为什么必须抽成共享内核（而不是给 SSE 再抄一份）
/// 移动端已有一套成熟的重连口径，固化在 `lib/data/ws/device_ws.dart` 的
/// 状态机里：**1s → 2s → 4s → 8s → 30s 封顶，±20% 抖动，连续 5 次后转 dead**。
///
/// 如果 SSE 再写一份，会出现两个必然后果：
/// 1. **两套退避打架**：前后台切换时 WS 与 SSE 各自按不同节奏重连，
///    流量突发不可控，且排查日志时无法用同一口径判断「谁是正常的」；
/// 2. **口径漂移**：某天有人调了 WS 的封顶值，SSE 就悄悄不一致了，
///    而这种不一致只会在真机弱网下以「一闪一闪」的形式暴露，极难定位。
///
/// 因此这里把「退避序列 + 抖动 + 上限」抽成纯函数，让两处共享同一口径。
/// 形态参照 `device_ws.dart` 的 `_backoffSchedule` / `jitterRatio` / `maxRetries`
/// （那里是字段，这里是同一语义的纯函数化）。
///
/// # 设计取舍：本文件**不**决定「耗尽后怎么办」
/// `device_ws` 在耗尽后转 `dead`（有重新配对等业务终态）；
/// SSE 没有业务终态，耗尽后应落**长退避继续重试**（见 `sse_session.dart`）。
/// 因此本函数只负责「第 n 次重连该等多久」，终态策略留给调用方 —— 这是
/// 让两者共用同一内核而不互相绑架的关键。
library;

import 'dart:math';

/// 退避序列（毫秒），与 `device_ws.dart` 的默认值逐字对齐。
///
/// 不再增长的理由：30s 已是「用户可感知但不焦虑」的上限；
/// 继续拉长会让弱网恢复后的数据迟到数十秒，实时性彻底失效。
const List<int> defaultBackoffScheduleMs = <int>[
  1000,
  2000,
  4000,
  8000,
  30000,
];

/// 默认抖动比例（±20%）。
///
/// 为什么要抖动：大量客户端在服务端重启后会**同时**重连，
/// 无抖动会形成整齐的重连风暴（thundering herd）。±20% 足以错峰。
const double defaultJitterRatio = 0.2;

/// 取第 [attempt] 次重连（从 0 开始）的等待时长（毫秒）。
///
/// - 超出序列长度时**取末位值**（不是无限增长，也不是归零）。
///   `device_ws` 的口径是「耗尽即 dead」，而这里「耗尽即封顶保持」——
///   因为 SSE 会靠长退避继续自愈（D3）。
/// - [jitterRatio] 为 0 时返回**精确**序列值（测试与排查时用）。
/// - [random] 可注入，便于测试固定抖动边界。
int backoffDelayMs(
  int attempt, {
  List<int> schedule = defaultBackoffScheduleMs,
  double jitterRatio = defaultJitterRatio,
  Random? random,
}) {
  if (schedule.isEmpty) return 0;
  final int index = attempt < 0 ? 0 : attempt;
  final int base = schedule[index >= schedule.length ? schedule.length - 1 : index];
  if (jitterRatio <= 0) return base;

  final Random rng = random ?? Random();
  // 抖动范围 [base*(1-ratio), base*(1+ratio)]，均匀分布。
  final double span = base * jitterRatio * 2;
  final double offset = (rng.nextDouble() * span) - (base * jitterRatio);
  final int result = (base + offset).round();
  // 下限 1ms：绝不能返回 0（否则退避变成忙等，会打满 CPU 与日志）。
  return result < 1 ? 1 : result;
}

/// 判断该次重连是否已「超出快速重连窗口」。
///
/// 用途：SSE 状态机据此决定是否**重置首帧快照等待**与日志级别
/// （前几次是正常抖动，之后才算异常）。阈值与 `device_ws` 的
/// `maxRetries = 5` 对齐 —— 口径一致才能用同一套日志判读两端。
bool isBeyondFastRetries(
  int attempt, {
  int maxFastRetries = 5,
}) =>
    attempt >= maxFastRetries;
