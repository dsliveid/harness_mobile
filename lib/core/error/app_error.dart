/// 统一错误模型（对齐服务端 `internal/apperr/apperr.go`）。
///
/// 服务端对外错误响应体**统一**为：
/// ```json
/// {"error":{"code":"...","message":"...","trace_id":"...","details":{...}}}
/// ```
/// - `trace_id` / `details` 均 `omitempty`
/// - 对外只暴露稳定字符串错误码，不暴露内部错误链（apperr.go:3-6）
library;

/// 稳定错误码（服务端 `apperr.Code`，禁止随意改名）。
abstract final class ErrorCode {
  // —— 通用 ——
  static const String internal = 'internal';
  static const String invalidArgument = 'invalid_argument';
  static const String notFound = 'not_found';
  static const String conflict = 'conflict';
  static const String rateLimited = 'rate_limited';
  static const String unauthorized = 'unauthorized';
  static const String forbidden = 'forbidden';
  static const String unavailable = 'unavailable';

  // —— 认证 ——
  static const String authInvalidCredentials = 'auth.invalid_credentials';
  static const String authSessionExpired = 'auth.session_expired';
  static const String authRateLimited = 'auth.rate_limited';
  static const String authSignExpired = 'auth.sign_expired';

  // —— 会话与运行 ——
  static const String sessionNotFound = 'session.not_found';
  static const String runNotFound = 'run.not_found';
  static const String runStateConflict = 'run.state_conflict';
  static const String runConcurrencyFull = 'run.concurrency_full';

  // —— 审批（B-3 / C-7 跨端仲裁）——
  static const String approvalNotFound = 'approval.not_found';
  static const String approvalAlreadyDecided = 'approval.already_decided';

  /// 审批绑定了执行端设备，决策方不是该设备（strict 模式）。
  ///
  /// 移动端收到此码**必须**提示「需在指定设备上确认」，不得就地批准（红线 R5）。
  static const String approvalDeviceMismatch = 'approval.device_mismatch';

  // —— 设备与多端协同 ——
  static const String devicePairCodeInvalid = 'device.pair_code_invalid';
  static const String deviceNotFound = 'device.not_found';
  static const String deviceRevoked = 'device.revoked';
  static const String deviceProtocolMismatch = 'device.protocol_mismatch';
  static const String deviceDisabled = 'device.disabled';

  // —— 文件系统（移动端本期不申报 workspace.list，一般不会遇到）——
  static const String fsHostUnsupported = 'fs.host_unsupported';
  static const String fsHostOffline = 'fs.host_offline';
}

/// 业务错误（服务端返回的结构化错误，或端侧归一化后的错误）。
class AppError implements Exception {
  const AppError({
    required this.code,
    required this.message,
    this.traceId,
    this.details,
    this.statusCode,
  });

  /// 稳定错误码（见 [ErrorCode]）。
  final String code;

  /// 面向用户的可读消息（服务端已给中文文案，可直接展示）。
  final String message;

  /// 服务端 trace_id（排障用，可提示用户反馈时携带）。
  final String? traceId;

  /// 结构化细节（如 `{"host": "device:xxx"}`）。
  final Map<String, dynamic>? details;

  /// HTTP 状态码（端侧网络层填充）。
  final int? statusCode;

  /// 从服务端错误响应体解析（`{"error":{...}}`）。
  ///
  /// 若响应体不符合约定，退回为通用 internal 错误而非崩溃。
  factory AppError.fromResponseBody(Object? body, {int? statusCode}) {
    if (body is Map<String, dynamic>) {
      final err = body['error'];
      if (err is Map<String, dynamic>) {
        return AppError(
          code: err['code'] as String? ?? ErrorCode.internal,
          message: err['message'] as String? ?? '未知错误',
          traceId: err['trace_id'] as String?,
          details: err['details'] as Map<String, dynamic>?,
          statusCode: statusCode,
        );
      }
    }
    return AppError(
      code: ErrorCode.internal,
      message: '服务返回了非预期格式的错误响应',
      statusCode: statusCode,
    );
  }

  /// 网络/传输层错误（连不上、超时、TLS 失败等）。
  factory AppError.network(String message) => AppError(
        code: ErrorCode.unavailable,
        message: message,
      );

  /// 端侧本地错误（如序列化失败、缺少令牌）。
  factory AppError.local(String code, String message) =>
      AppError(code: code, message: message);

  /// 是否为「审批已被他人决策」（多点竞争审批，first-wins）。
  bool get isApprovalAlreadyDecided => code == ErrorCode.approvalAlreadyDecided;

  /// 是否为「审批需在指定设备确认」（红线 R5）。
  bool get isApprovalDeviceMismatch => code == ErrorCode.approvalDeviceMismatch;

  /// 是否为鉴权失效（401 语义，需刷新令牌或重新登录）。
  bool get isUnauthorized =>
      code == ErrorCode.unauthorized ||
      code == ErrorCode.authSessionExpired ||
      statusCode == 401;

  /// 是否为设备令牌失效（需重新配对）。
  bool get isDeviceRevoked => code == ErrorCode.deviceRevoked;

  /// 是否为协议版本不兼容（需升级 App）。
  bool get isProtocolMismatch => code == ErrorCode.deviceProtocolMismatch;

  /// 是否为请求体字段非法。
  ///
  /// ⚠️ 移动端**高频踩坑**：服务端 `decodeJSON` 启用
  /// `DisallowUnknownFields`（`handler.go:401`），端侧多发一个字段即 400。
  /// 因此这类错误必须把服务端 `message` 原样透出，否则排查极慢（红线 R7）。
  bool get isInvalidArgument =>
      code == ErrorCode.invalidArgument || statusCode == 400;

  /// 用户可读的展示文案（优先服务端 message，其次按码兜底）。
  String get displayMessage {
    if (message.isNotEmpty) return message;
    switch (code) {
      case ErrorCode.unavailable:
        return '网络不可用，请检查连接后重试';
      case ErrorCode.unauthorized:
        return '登录已失效，请重新登录';
      case ErrorCode.deviceRevoked:
        return '本设备已被解绑，请重新配对';
      case ErrorCode.devicePairCodeInvalid:
        return '配对码无效或已过期，请重新生成';
      case ErrorCode.approvalAlreadyDecided:
        return '该审批已被处理，列表已刷新';
      case ErrorCode.approvalDeviceMismatch:
        return '该审批需在指定设备上确认';
      case ErrorCode.deviceProtocolMismatch:
        return '客户端版本过旧，请升级后重试';
      default:
        return '操作失败（$code）';
    }
  }

  @override
  String toString() =>
      'AppError($code${statusCode != null ? ' [$statusCode]' : ''}): $message';

  AppError copyWith({int? statusCode}) => AppError(
        code: code,
        message: message,
        traceId: traceId,
        details: details,
        statusCode: statusCode ?? this.statusCode,
      );
}
