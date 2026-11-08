/// 审批仓储（P5 审批中心的数据拼装层，**不含 UI**）。
///
/// 服务端没有「全局待审批列表」端点，只能靠 N+1 拼装：
/// ```
/// sessions(limit 50) ──本地标记过滤──▶ active-run ──非空 run──▶ tool-events ──status==pending──▶ PendingApproval
/// ```
/// 三条铁律（对齐服务端源码）：
/// 1. **不做全量扇出**：只对「本地标记 active」的会话查 `active-run`。
///    判定依据是会话自身的 `last_run_status == waiting_approval`
///    （见 `Session.mayNeedApproval`）——这是服务端写入的权威标记。
/// 2. **无活跃 Run 不是错误**：`active-run` 返回 200 + `run_id:""`
///    （`handler.go:247-265`），[SessionApi.activeRun] 已归一成 null。
/// 3. **审批 ID 就是工具事件 ID**：服务端 `approval.Request.ApprovalID = eventID`
///    （`agent/engine.go:633`），故直接用 `ToolEvent.id`，无需额外映射表。
///
/// 并发上限默认 6（移动端弱网下同时打满会拖慢首屏，且触发服务端限流）。
library;

import '../../data/remote/approval_api.dart';
import '../../data/remote/session_api.dart';

/// 待审批项（审批中心列表的一行）。
class PendingApproval {
  const PendingApproval({
    required this.sessionId,
    required this.runId,
    required this.approvalId,
    required this.toolName,
    required this.argsDigest,
    required this.risk,
    required this.createdAt,
    this.namespace = '',
    this.sessionTitle = '',
  });

  /// 所属会话 ID（决策端点路径参数）。
  final String sessionId;

  /// 所属 Run ID（决策端点路径参数）。
  final String runId;

  /// 审批 ID（决策端点路径参数）—— 等于工具事件 ID。
  final String approvalId;

  final String toolName;

  /// 入参摘要（已截断，绝不展示全文，避免敏感信息外泄）。
  final String argsDigest;

  /// 风险等级：`read / write / command / danger`。
  final String risk;

  /// 展示用时间：优先事件 `started_at`，回退会话 `last_message_at`，都无则 0。
  final int createdAt;

  final String namespace;

  /// 所属会话标题（列表做副标题用，省一次查询）。
  final String sessionTitle;

  /// 是否高风险（`command` / `danger` → 需生物识别 + 可能需指定设备确认）。
  bool get isHighRisk => risk == Risks.danger || risk == Risks.command;

  @override
  String toString() =>
      'PendingApproval($approvalId, $toolName, risk=$risk, sid=$sessionId)';
}

/// 审批仓储。
class ApprovalRepository {
  ApprovalRepository({
    required SessionApi sessions,
    this.approvals,
    this.maxConcurrency = 6,
  }) : _sessions = sessions;

  final SessionApi _sessions;

  /// 决策 API（可选注入）：本仓储只负责「读」，决策动作由 UI 层直接调用。
  /// 以公开只读字段暴露，便于上层一次性组装依赖，不做隐式副作用。
  final ApprovalApi? approvals;

  /// 并发上限（扇出请求数）。
  final int maxConcurrency;

  /// 拉取待审批列表。
  ///
  /// - [sessionLimit]：会话扫描上限（默认 50，与首屏列表一致）。
  /// - [candidateSessions]：可选的候选会话覆盖（用于本地已有缓存时避免重拉）。
  ///
  /// 单个会话查询失败**不会**中断整体（移动端常见弱网抖动）；
  /// 但会话列表本身失败会原样上抛 [AppError]，由上层展示错误态。
  Future<List<PendingApproval>> loadPendingApprovals({
    int sessionLimit = 50,
    List<Session>? candidateSessions,
  }) async {
    final sessions =
        candidateSessions ?? await _sessions.listSessions(limit: sessionLimit);

    // 本地标记过滤：只看「可能会产生审批」的会话，绝不无差别扇出。
    final candidates = sessions
        .where((Session s) => !s.isDeleted && !s.isArchived && s.mayNeedApproval)
        .toList(growable: false);

    if (candidates.isEmpty) return const <PendingApproval>[];

    final perSession =
        await _mapConcurrent<Session, List<PendingApproval>>(
      candidates,
      _loadForSession,
    );

    final merged = <PendingApproval>[];
    for (final batch in perSession) {
      merged.addAll(batch);
    }
    // 新的排前面；时间相同则按 approvalId 稳定排序，避免列表抖动。
    merged.sort((PendingApproval a, PendingApproval b) {
      final byTime = b.createdAt.compareTo(a.createdAt);
      return byTime != 0 ? byTime : a.approvalId.compareTo(b.approvalId);
    });
    return merged;
  }

  /// 单会话：active-run → tool-events → 筛 pending。
  Future<List<PendingApproval>> _loadForSession(Session session) async {
    try {
      final run = await _sessions.activeRun(session.id);
      if (run == null) return const <PendingApproval>[];

      final events = await _sessions.toolEvents(session.id, run.runId);
      final pending = <PendingApproval>[];
      for (final event in events) {
        if (!event.isPending) continue;
        pending.add(
          PendingApproval(
            sessionId: session.id,
            runId: run.runId,
            approvalId: event.id,
            toolName: event.toolName,
            argsDigest: event.argsDigest(),
            risk: event.risk,
            createdAt: event.startedAt ?? session.lastMessageAt ?? 0,
            namespace: event.namespace,
            sessionTitle: session.title,
          ),
        );
      }
      return pending;
    } on Object {
      // 弱网/会话被并发删除等单点故障：跳过该会话，不毁整屏。
      return const <PendingApproval>[];
    }
  }

  /// 固定并发池（不引入额外依赖，手写 worker 池）。
  ///
  /// 保持输入顺序返回结果。
  Future<List<R>> _mapConcurrent<T, R>(
    List<T> items,
    Future<R> Function(T item) task,
  ) async {
    if (items.isEmpty) return <R>[];
    final results = List<R?>.filled(items.length, null);
    var nextIndex = 0;

    Future<void> worker() async {
      while (true) {
        final index = nextIndex;
        if (index >= items.length) return;
        nextIndex = index + 1;
        results[index] = await task(items[index]);
      }
    }

    final limit = maxConcurrency < 1 ? 1 : maxConcurrency;
    final workerCount = limit < items.length ? limit : items.length;
    final workers = <Future<void>>[
      for (var i = 0; i < workerCount; i++) worker(),
    ];
    await Future.wait(workers);
    return results.cast<R>();
  }
}
