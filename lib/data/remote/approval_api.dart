/// 审批 API（对齐服务端 `internal/api/provider_handler.go:14-51`）。
///
/// `POST /api/v1/sessions/{sid}/runs/{rid}/approvals/{aid}/decide`
/// 请求体键集合**必须恰为** `{decision, reason, device_id}`；
/// `decision` **只允许** `allow_once` | `allow_session` | `deny`
/// （服务端 `provider_handler.go:16-22`，**不是 approve/reject**！）。
/// 响应 `{approval_id, decision, status, decided_by_device}`。
library;

import 'http_client.dart';

/// 审批决策取值常量（服务端 `provider_handler.go:17` 注释限定）。
abstract final class ApprovalDecisions {
  /// 本次允许（一次性）。
  static const String allowOnce = 'allow_once';

  /// 本会话内允许（服务端记忆该工具/模式的放行）。
  static const String allowSession = 'allow_session';

  /// 拒绝。
  static const String deny = 'deny';

  static const List<String> values = <String>[allowOnce, allowSession, deny];

  static bool isValid(String decision) => values.contains(decision);
}

/// 决策结果（服务端直接回显）。
class ApprovalDecisionResult {
  const ApprovalDecisionResult({
    required this.approvalId,
    required this.decision,
    required this.status,
    required this.decidedByDevice,
  });

  factory ApprovalDecisionResult.fromJson(Map<String, dynamic> json) =>
      ApprovalDecisionResult(
        approvalId: _str(json['approval_id']),
        decision: _str(json['decision']),
        status: _str(json['status']),
        decidedByDevice: _str(json['decided_by_device']),
      );

  final String approvalId;
  final String decision;
  final String status;
  final String decidedByDevice;

  @override
  String toString() =>
      'ApprovalDecisionResult($approvalId, $decision, $status)';
}

/// 审批 API。
class ApprovalApi {
  ApprovalApi({required ApiClient client}) : _client = client;

  final ApiClient _client;

  /// 提交审批决策。
  ///
  /// - [sessionId] / [runId] / [approvalId]：来自待审批项（[ToolEvent.id] 即审批 ID）。
  /// - [decision]：**必须**是 [ApprovalDecisions] 中的值；非法值在端侧直接抛错，
  ///   不发请求（服务端会以 400 拒绝，但端侧早失败更利于定位）。
  /// - [deviceId]：决策端设备 ID（本机配对得到的 device_id）。
  ///   服务端 `strict_approval_device=true` 且审批绑定执行端时，
  ///   非该设备决策会返回 403 `approval.device_mismatch`（红线 R5：必须提示用户
  ///   「需在指定设备确认」，**不得就地批准**）。
  Future<ApprovalDecisionResult> decide({
    required String sessionId,
    required String runId,
    required String approvalId,
    required String decision,
    required String deviceId,
    String reason = '',
  }) {
    if (!ApprovalDecisions.isValid(decision)) {
      throw ArgumentError.value(
        decision,
        'decision',
        '只允许 ${ApprovalDecisions.values.join(' / ')}',
      );
    }
    return _client.post<ApprovalDecisionResult>(
      '/api/v1/sessions/$sessionId/runs/$runId/approvals/$approvalId/decide',
      // ⚠️ 键集合必须恰为这 3 个（DisallowUnknownFields）
      body: <String, dynamic>{
        'decision': decision,
        'reason': reason,
        'device_id': deviceId,
      },
      parse: (Object? data) =>
          ApprovalDecisionResult.fromJson(mapOf(data)),
    );
  }
}

String _str(Object? value) => value is String ? value : '';
