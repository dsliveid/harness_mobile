/// 会话 API（对齐服务端 `internal/api/handler.go` 与 `internal/model/model.go`）。
///
/// 端点（已核实源码，勿改）：
/// - `GET /api/v1/sessions?limit=&offset=`            → `{items:[Session]}`（`handler.go:180`）
/// - `GET /api/v1/sessions/{sid}`                      → `Session`
/// - `GET /api/v1/sessions/{sid}/messages?after_seq=&limit=` → `{items,after_seq,limit}`
/// - `GET /api/v1/sessions/{sid}/active-run`           → `{run_id, status}`
///   ⚠️ **无进行中 Run 不是 404**：200 + `run_id:""`（`handler.go:247-265`），
///   故本层把空 run_id 视作「无活跃 Run」（返回 null），调用方无需分支
/// - `GET /api/v1/sessions/{sid}/runs/{rid}/tool-events` → `{items:[ToolEvent]}`
///
/// 解析约定（红线）：所有整数一律 `(x as num).toInt()` 或 [asIntOrNull]，
/// 防止服务端 int64（毫秒时间戳）被当作 double 丢精度。
library;

import '../../protocol/envelope.dart' show asIntOrNull;
import 'http_client.dart';

/// 运行状态取值（服务端 `model.RunStatus`）。
abstract final class RunStatuses {
  static const String pending = 'pending';
  static const String running = 'running';
  static const String waitingApproval = 'waiting_approval';
  static const String completed = 'completed';
  static const String failed = 'failed';
  static const String cancelled = 'cancelled';
  static const String interrupted = 'interrupted';

  static const List<String> values = <String>[
    pending,
    running,
    waitingApproval,
    completed,
    failed,
    cancelled,
    interrupted,
  ];

  /// 是否处于「仍在进行」的状态（用于活动态判定）。
  static bool isLive(String? status) =>
      status == pending ||
      status == running ||
      status == waitingApproval;
}

/// 工具事件状态取值（服务端 `model.ToolEventStatus`）。
abstract final class ToolEventStatuses {
  static const String pending = 'pending';
  static const String approved = 'approved';
  static const String denied = 'denied';
  static const String running = 'running';
  static const String ok = 'ok';
  static const String error = 'error';
  static const String timeout = 'timeout';

  static const List<String> values = <String>[
    pending,
    approved,
    denied,
    running,
    ok,
    error,
    timeout,
  ];
}

/// 风险等级取值（服务端 `model.Risk`）。
abstract final class Risks {
  static const String read = 'read';
  static const String write = 'write';
  static const String command = 'command';
  static const String danger = 'danger';
}

/// 执行面取值（服务端 `model.Executor`）。
abstract final class Executors {
  static const String server = 'server';
  static const String device = 'device';
}

/// 会话（服务端 `model.Session`，`model.go:104-125`）。
class Session {
  const Session({
    required this.id,
    required this.title,
    required this.workspacePath,
    required this.accessMode,
    required this.modelRef,
    required this.userId,
    required this.messageCount,
    required this.totalTokens,
    required this.createdAt,
    required this.updatedAt,
    this.projectId,
    this.source,
    this.lastMessageAt,
    this.lastRunStatus,
    this.deletedAt,
    this.archivedAt,
  });

  factory Session.fromJson(Map<String, dynamic> json) => Session(
        id: _str(json['id']),
        title: _str(json['title']),
        workspacePath: _str(json['workspace_path']),
        projectId: _optStr(json['project_id']),
        accessMode: _str(json['access_mode']),
        modelRef: _str(json['model_ref']),
        userId: _str(json['user_id']),
        source: _optStr(json['source']),
        messageCount: _int(json['message_count']),
        lastMessageAt: asIntOrNull(json['last_message_at']),
        totalTokens: _int(json['total_tokens']),
        lastRunStatus: _optStr(json['last_run_status']),
        createdAt: _int(json['created_at']),
        updatedAt: _int(json['updated_at']),
        deletedAt: asIntOrNull(json['deleted_at']),
        archivedAt: asIntOrNull(json['archived_at']),
      );

  final String id;
  final String title;
  final String workspacePath;

  /// 空串 / null = 纯对话，不隶属任何项目。
  final String? projectId;

  final String accessMode;
  final String modelRef;
  final String userId;

  /// 会话来源：`ui`（默认）/ `openai`（隐藏会话）。
  final String? source;

  final int messageCount;
  final int? lastMessageAt;
  final int totalTokens;
  final String? lastRunStatus;
  final int createdAt;
  final int updatedAt;
  final int? deletedAt;

  /// 非 null 即已归档。
  final int? archivedAt;

  bool get isArchived => archivedAt != null;

  bool get isDeleted => deletedAt != null;

  /// 是否有进行中的运行（`waiting_approval` 也属于进行中）。
  bool get hasLiveRun => RunStatuses.isLive(lastRunStatus);

  /// 是否可能携带待审批项：只有 `waiting_approval` 才需要查 active-run。
  ///
  /// 审批中心 N+1 拼装依赖此判定做「本地标记」过滤，避免对全部会话打请求。
  bool get mayNeedApproval => lastRunStatus == RunStatuses.waitingApproval;

  @override
  String toString() => 'Session($id, $title, run=$lastRunStatus)';
}

/// 消息（服务端 `model.Message`，`model.go:127-143`）。
class Message {
  const Message({
    required this.id,
    required this.seq,
    required this.role,
    required this.content,
    required this.tokenCount,
    required this.createdAt,
    this.runId,
    this.reasoning,
    this.toolCalls,
    this.toolCallId,
    this.attachments,
    this.usage,
    this.hidden = false,
  });

  factory Message.fromJson(Map<String, dynamic> json) => Message(
        id: _str(json['id']),
        seq: _int(json['seq']),
        runId: _optStr(json['run_id']),
        role: _str(json['role']),
        content: _str(json['content']),
        reasoning: _optStr(json['reasoning']),
        toolCalls: _rawList(json['tool_calls']),
        toolCallId: _optStr(json['tool_call_id']),
        attachments: _rawList(json['attachments']),
        tokenCount: _int(json['token_count']),
        usage: json['usage'],
        hidden: json['hidden'] == true,
        createdAt: _int(json['created_at']),
      );

  final String id;

  /// 会话内严格递增序号（增量拉取游标）。
  final int seq;

  final String? runId;
  final String role;
  final String content;
  final String? reasoning;

  /// `json.RawMessage`：服务端原样透传，端侧保留为 List。
  final List<dynamic>? toolCalls;

  final String? toolCallId;
  final List<dynamic>? attachments;
  final int tokenCount;

  /// `json.RawMessage`：用量明细，结构随模型变化，端侧只做展示兜底。
  final Object? usage;

  /// 已随消息级回滚置灰（保留审计，上下文组装排除）。
  final bool hidden;

  final int createdAt;

  @override
  String toString() => 'Message($id, seq=$seq, role=$role)';
}

/// 工具调用事件（服务端 `model.ToolEvent`，`model.go:220-239`）。
///
/// 审批中心的核心数据源：`status == 'pending'` 即待审批项，
/// 且服务端 `approval.Request.ApprovalID` 直接取该事件 ID
/// （`agent/engine.go:633`：`ApprovalID: eventID`）——故 [id] 即审批 ID。
class ToolEvent {
  const ToolEvent({
    required this.id,
    required this.runId,
    required this.toolName,
    required this.namespace,
    required this.status,
    required this.risk,
    required this.executor,
    required this.sourceTrust,
    this.messageId,
    this.args,
    this.result,
    this.resultBlob,
    this.deviceId,
    this.approvedBy,
    this.error,
    this.startedAt,
    this.endedAt,
  });

  factory ToolEvent.fromJson(Map<String, dynamic> json) => ToolEvent(
        id: _str(json['id']),
        runId: _str(json['run_id']),
        messageId: _optStr(json['message_id']),
        toolName: _str(json['tool_name']),
        namespace: _str(json['namespace']),
        args: json['args'],
        result: json['result'],
        resultBlob: _optStr(json['result_blob']),
        status: _str(json['status']),
        risk: _str(json['risk']),
        executor: _str(json['executor']),
        deviceId: _optStr(json['device_id']),
        sourceTrust: _str(json['source_trust']),
        approvedBy: _optStr(json['approved_by']),
        error: _optStr(json['error']),
        startedAt: asIntOrNull(json['started_at']),
        endedAt: asIntOrNull(json['ended_at']),
      );

  /// 事件 ID —— **同时就是审批 ID**（服务端 `ApprovalID = eventID`）。
  final String id;

  final String runId;
  final String? messageId;
  final String toolName;
  final String namespace;

  /// `json.RawMessage`：工具入参原文（可能为 Map / List / 标量）。
  final Object? args;

  final Object? result;
  final String? resultBlob;
  final String status;
  final String risk;
  final String executor;
  final String? deviceId;
  final String sourceTrust;
  final String? approvedBy;
  final String? error;
  final int? startedAt;
  final int? endedAt;

  /// 是否待审批。
  bool get isPending => status == ToolEventStatuses.pending;

  /// 是否高风险（需在指定设备确认，红线 R5）。
  bool get isHighRisk => risk == Risks.danger || risk == Risks.command;

  /// 入参摘要（列表展示用；**不展示全文**，避免敏感信息泄露）。
  ///
  /// 规则：Map 取前若干个键 `k=v` 拼接；List 取长度；标量取 toString；
  /// 超长截断到 [maxLength]（按字符边界安全截断）。
  String argsDigest({int maxLength = 120}) {
    final raw = args;
    final String text;
    if (raw == null) {
      text = '';
    } else if (raw is Map) {
      final parts = <String>[];
      for (final entry in raw.entries) {
        parts.add('${entry.key}=${_short(entry.value)}');
        if (parts.length >= 4) break;
      }
      text = parts.join(', ');
    } else if (raw is List) {
      // 直接按 JSON 文本兜底，长度受截断保护
      text = raw.toString();
    } else {
      text = raw.toString();
    }
    if (text.length <= maxLength) return text;
    // 安全截断：回退到合法字符边界，避免切在多字节字符中间（中文 panic 坑）
    var end = maxLength;
    while (end > 0 && !_isCharBoundary(text, end)) {
      end--;
    }
    return '${text.substring(0, end)}…';
  }

  @override
  String toString() =>
      'ToolEvent($id, $toolName, status=$status, risk=$risk)';
}

/// 活跃运行视图（`GET /active-run` 的响应）。
class ActiveRun {
  const ActiveRun({required this.runId, required this.status});

  factory ActiveRun.fromJson(Map<String, dynamic> json) => ActiveRun(
        runId: _str(json['run_id']),
        status: _str(json['status']),
      );

  /// 空串表示「当前无活跃 Run」（服务端刻意用 200 而非 404）。
  final String runId;
  final String status;

  bool get isActive => runId.isNotEmpty;

  @override
  String toString() => 'ActiveRun($runId, $status)';
}

/// 会话 API。
class SessionApi {
  SessionApi({required ApiClient client}) : _client = client;

  final ApiClient _client;

  /// 会话列表（默认按服务端排序，移动端取最近 50 条）。
  Future<List<Session>> listSessions({int limit = 50, int offset = 0}) =>
      _client.get<List<Session>>(
        '/api/v1/sessions',
        query: <String, dynamic>{'limit': limit, 'offset': offset},
        parse: (Object? data) =>
            itemsOf(data).map(Session.fromJson).toList(growable: false),
      );

  /// 单会话详情。
  Future<Session> getSession(String sessionId) => _client.get<Session>(
        '/api/v1/sessions/$sessionId',
        parse: (Object? data) => Session.fromJson(mapOf(data)),
      );

  /// 消息增量拉取（`after_seq` 游标，配合 SSE 断线续传）。
  Future<List<Message>> listMessages(
    String sessionId, {
    int afterSeq = 0,
    int limit = 100,
  }) =>
      _client.get<List<Message>>(
        '/api/v1/sessions/$sessionId/messages',
        query: <String, dynamic>{'after_seq': afterSeq, 'limit': limit},
        parse: (Object? data) =>
            itemsOf(data).map(Message.fromJson).toList(growable: false),
      );

  /// 当前活跃运行。**无活跃 Run 时返回 null**（不是异常、不是 404）。
  ///
  /// 服务端语义铁律见 `handler.go:247-252`：200 + `run_id:""`。
  Future<ActiveRun?> activeRun(String sessionId) async {
    final data = await _client.get<Map<String, dynamic>>(
      '/api/v1/sessions/$sessionId/active-run',
      parse: mapOf,
    );
    final run = ActiveRun.fromJson(data);
    return run.isActive ? run : null;
  }

  /// 某次 Run 的全部工具事件（审计 / 审批中心数据源）。
  Future<List<ToolEvent>> toolEvents(String sessionId, String runId) =>
      _client.get<List<ToolEvent>>(
        '/api/v1/sessions/$sessionId/runs/$runId/tool-events',
        parse: (Object? data) =>
            itemsOf(data).map(ToolEvent.fromJson).toList(growable: false),
      );
}

String _str(Object? value) => value is String ? value : '';

String? _optStr(Object? value) =>
    value is String && value.isNotEmpty ? value : null;

int _int(Object? value) {
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value) ?? 0;
  return 0;
}

/// `json.RawMessage` 形态：服务端数组原样透传；非数组返回 null。
List<dynamic>? _rawList(Object? value) {
  if (value is List) return value;
  return null;
}

String _short(Object? value) {
  if (value == null) return 'null';
  final text = value is String ? value : value.toString();
  return text.length <= 32 ? text : '${text.substring(0, 32)}…';
}

/// UTF-16 code unit 边界判定（代理对安全）。
bool _isCharBoundary(String text, int index) {
  if (index <= 0 || index >= text.length) return true;
  final unit = text.codeUnitAt(index - 1);
  // 高位代理（0xD800-0xDBFF）后紧跟低位代理时，不能在此处切断
  return !(unit >= 0xD800 && unit <= 0xDBFF);
}
