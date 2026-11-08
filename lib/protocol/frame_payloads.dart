/// 各帧负载（线格式唯一权威：`harness_go/internal/device/protocol.go:189-268`）。
///
/// 所有 `fromJson` 必须遵守：
/// - 数值统一走 [asIntOrNull]（int64 毫秒精度陷阱）
/// - Go 侧 `omitempty` 的字段在 `toJson` 中用条件键，不写 `null`
library;

import 'envelope.dart';

/// 端侧自述（首帧，可选）。对齐 `HelloPayload`。
class HelloPayload {
  const HelloPayload({
    this.name,
    this.platform,
    this.appVersion,
    this.capabilitiesHash,
    this.protocolVersion,
    this.capabilities = const [],
  });

  final String? name;
  final String? platform;
  final String? appVersion;

  /// 能力摘要哈希（服务端用于快速判断端侧能力是否变化）。
  final String? capabilitiesHash;

  final int? protocolVersion;

  /// 能力申报项。元素**只允许** `name` / `version`（服务端 `capabilityInput` 限制）。
  final List<Capability> capabilities;

  factory HelloPayload.fromJson(Map<String, dynamic> json) => HelloPayload(
        name: json['name'] as String?,
        platform: json['platform'] as String?,
        appVersion: json['app_version'] as String?,
        capabilitiesHash: json['capabilities_hash'] as String?,
        protocolVersion: asIntOrNull(json['protocol_version']),
        capabilities: _capsFromJson(json['capabilities']),
      );

  /// 上行序列化：能力项只发 `name`/`version`（见 [Capability.toRequestJson]）。
  Map<String, dynamic> toJson() => {
        if (name != null) 'name': name,
        if (platform != null) 'platform': platform,
        if (appVersion != null) 'app_version': appVersion,
        if (capabilitiesHash != null) 'capabilities_hash': capabilitiesHash,
        if (protocolVersion != null) 'protocol_version': protocolVersion,
        if (capabilities.isNotEmpty)
          'capabilities': capabilities.map((c) => c.toRequestJson()).toList(),
      };
}

/// 握手确认。对齐 `WelcomePayload`（protocol.go:200-209）。
///
/// **最重要的一帧**：`heartbeatS` / `offlineAfterS` 驱动端侧心跳节奏，
/// 绝不允许硬编码 15s（15s 只是服务端默认值，不是契约）。
class WelcomePayload {
  const WelcomePayload({
    required this.deviceId,
    required this.serverTime,
    required this.protocolVersion,
    required this.heartbeatS,
    required this.offlineAfterS,
    required this.pending,
    this.leaseEpoch,
  });

  final String deviceId;
  final int serverTime;
  final int protocolVersion;

  /// 心跳周期（秒）。端侧实际间隔应取其 0.8 倍留裕度。
  final int heartbeatS;

  /// 超过此秒数无帧则服务端判定离线。
  final int offlineAfterS;

  /// 待派发任务数。
  final int pending;

  /// 会话租约代次（omitempty；0/缺省表示无租约信息）。
  final int? leaseEpoch;

  /// 端侧应使用的心跳间隔（含安全裕度）。
  Duration get heartbeatInterval =>
      Duration(milliseconds: (heartbeatS * 0.8 * 1000).round());

  factory WelcomePayload.fromJson(Map<String, dynamic> json) => WelcomePayload(
        deviceId: json['device_id'] as String,
        serverTime: asIntOrNull(json['server_time']) ?? 0,
        protocolVersion: asIntOrNull(json['protocol_version']) ?? 0,
        heartbeatS: asIntOrNull(json['heartbeat_s']) ?? 15,
        offlineAfterS: asIntOrNull(json['offline_after_s']) ?? 45,
        pending: asIntOrNull(json['pending']) ?? 0,
        leaseEpoch: asIntOrNull(json['lease_epoch']),
      );

  Map<String, dynamic> toJson() => {
        'device_id': deviceId,
        'server_time': serverTime,
        'protocol_version': protocolVersion,
        'heartbeat_s': heartbeatS,
        'offline_after_s': offlineAfterS,
        'pending': pending,
        if (leaseEpoch != null) 'lease_epoch': leaseEpoch,
      };
}

/// 端侧心跳。对齐 `PingPayload`（全部 omitempty）。
class PingPayload {
  const PingPayload({
    this.load,
    this.capabilitiesHash,
    this.protocolVersion,
  });

  /// 任意观测负载（建议 `{battery, network, foreground}`）。
  final Map<String, dynamic>? load;
  final String? capabilitiesHash;
  final int? protocolVersion;

  factory PingPayload.fromJson(Map<String, dynamic> json) => PingPayload(
        load: json['load'] as Map<String, dynamic>?,
        capabilitiesHash: json['capabilities_hash'] as String?,
        protocolVersion: asIntOrNull(json['protocol_version']),
      );

  Map<String, dynamic> toJson() => {
        if (load != null) 'load': load,
        if (capabilitiesHash != null) 'capabilities_hash': capabilitiesHash,
        if (protocolVersion != null) 'protocol_version': protocolVersion,
      };
}

/// 服务端心跳应答。对齐 `PongPayload`（全必填）。
class PongPayload {
  const PongPayload({
    required this.serverTime,
    required this.pending,
    required this.protocolVersion,
  });

  final int serverTime;
  final int pending;
  final int protocolVersion;

  factory PongPayload.fromJson(Map<String, dynamic> json) => PongPayload(
        serverTime: asIntOrNull(json['server_time']) ?? 0,
        pending: asIntOrNull(json['pending']) ?? 0,
        protocolVersion: asIntOrNull(json['protocol_version']) ?? 0,
      );

  Map<String, dynamic> toJson() => {
        'server_time': serverTime,
        'pending': pending,
        'protocol_version': protocolVersion,
      };
}

/// 错误帧。对齐 `ErrorPayload`。
class ErrorPayload {
  const ErrorPayload({
    required this.code,
    this.message,
    this.fatal = false,
  });

  final String code;
  final String? message;

  /// true 时服务端在写出本帧后关闭连接。
  final bool fatal;

  /// 按 [FrameCode] 分派端侧动作（架构文档 §4.3 决策表）。
  ///
  /// 注意：非 fatal 的错误也应给出正确动作 —— `bad_frame` 是忽略并保持连接。
  WsFatalAction get action {
    switch (code) {
      case FrameCode.badFrame:
        return WsFatalAction.ignore;
      case FrameCode.taskUnsupported:
        return WsFatalAction.ignore;
      case FrameCode.protocolMismatch:
        return WsFatalAction.upgradeRequired;
      case FrameCode.replaced:
        return WsFatalAction.replacedElsewhere;
      case FrameCode.revoked:
        return WsFatalAction.repairPairing;
      case FrameCode.offlineTimeout:
      case FrameCode.serverClosing:
      case FrameCode.writeFailed:
        return WsFatalAction.reconnect;
      default:
        // 未知错误码：保守按可重连处理，避免永久卡死
        return fatal ? WsFatalAction.reconnect : WsFatalAction.ignore;
    }
  }

  factory ErrorPayload.fromJson(Map<String, dynamic> json) => ErrorPayload(
        code: json['code'] as String? ?? '',
        message: json['message'] as String?,
        fatal: json['fatal'] as bool? ?? false,
      );

  Map<String, dynamic> toJson() => {
        'code': code,
        if (message != null) 'message': message,
        if (fatal) 'fatal': fatal,
      };
}

/// 任务派发。对齐 `TaskDispatchPayload`（protocol.go:234-242）。
///
/// `taskId` 恒等于 `toolEventId`，端侧据此做幂等。
class TaskDispatchPayload {
  const TaskDispatchPayload({
    required this.taskId,
    required this.runId,
    required this.toolEventId,
    required this.toolName,
    this.args,
    required this.deadline,
    this.attempt = 1,
  });

  final String taskId;
  final String runId;
  final String toolEventId;
  final String toolName;
  final Map<String, dynamic>? args;

  /// 毫秒时间戳，超时端侧可放弃（必须主动回 timeout，不许挂死）。
  final int deadline;

  /// 重派次数（>=1）。
  final int attempt;

  factory TaskDispatchPayload.fromJson(Map<String, dynamic> json) =>
      TaskDispatchPayload(
        taskId: json['task_id'] as String,
        runId: json['run_id'] as String,
        toolEventId: json['tool_event_id'] as String,
        toolName: json['tool_name'] as String,
        args: json['args'] as Map<String, dynamic>?,
        deadline: asIntOrNull(json['deadline']) ?? 0,
        attempt: asIntOrNull(json['attempt']) ?? 1,
      );

  Map<String, dynamic> toJson() => {
        'task_id': taskId,
        'run_id': runId,
        'tool_event_id': toolEventId,
        'tool_name': toolName,
        if (args != null) 'args': args,
        'deadline': deadline,
        if (attempt != 1) 'attempt': attempt,
      };
}

/// 执行进度流式块。对齐 `TaskProgressPayload`（全必填）。
class TaskProgressPayload {
  const TaskProgressPayload({
    required this.taskId,
    required this.runId,
    required this.toolEventId,
    required this.chunk,
  });

  final String taskId;
  final String runId;
  final String toolEventId;
  final String chunk;

  factory TaskProgressPayload.fromJson(Map<String, dynamic> json) =>
      TaskProgressPayload(
        taskId: json['task_id'] as String,
        runId: json['run_id'] as String,
        toolEventId: json['tool_event_id'] as String,
        chunk: json['chunk'] as String? ?? '',
      );

  Map<String, dynamic> toJson() => {
        'task_id': taskId,
        'run_id': runId,
        'tool_event_id': toolEventId,
        'chunk': chunk,
      };
}

/// 任务终态。对齐 `TaskResultPayload`（protocol.go:252-261）。
///
/// **红线 R2**：端侧结果一律 `source_trust=untrusted`，
/// 即便结果来自本机也不得自称 trusted（服务端会强制覆盖）。
class TaskResultPayload {
  const TaskResultPayload({
    required this.taskId,
    required this.runId,
    required this.toolEventId,
    required this.status,
    this.result,
    this.error,
    this.sourceTrust = 'untrusted',
  });

  final String taskId;
  final String runId;
  final String toolEventId;

  /// `success` | `failed` | `cancelled`
  final String status;

  final Object? result;
  final String? error;

  /// 恒为 `untrusted`（红线 R2，不要改）。
  final String sourceTrust;

  static const String statusSuccess = 'success';
  static const String statusFailed = 'failed';
  static const String statusCancelled = 'cancelled';

  factory TaskResultPayload.fromJson(Map<String, dynamic> json) =>
      TaskResultPayload(
        taskId: json['task_id'] as String,
        runId: json['run_id'] as String,
        toolEventId: json['tool_event_id'] as String,
        status: json['status'] as String,
        result: json['result'],
        error: json['error'] as String?,
        sourceTrust: json['source_trust'] as String? ?? 'untrusted',
      );

  Map<String, dynamic> toJson() => {
        'task_id': taskId,
        'run_id': runId,
        'tool_event_id': toolEventId,
        'status': status,
        if (result != null) 'result': result,
        if (error != null) 'error': error,
        'source_trust': sourceTrust,
      };
}

/// 租约被抢占通知。对齐 `LeaseRevokedPayload`（protocol.go:263-268）。
///
/// 收到即转只读并提示用户。
class LeaseRevokedPayload {
  const LeaseRevokedPayload({
    required this.sessionId,
    required this.epoch,
    this.reason,
  });

  final String sessionId;
  final int epoch;
  final String? reason;

  factory LeaseRevokedPayload.fromJson(Map<String, dynamic> json) =>
      LeaseRevokedPayload(
        sessionId: json['session_id'] as String,
        epoch: asIntOrNull(json['epoch']) ?? 0,
        reason: json['reason'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'session_id': sessionId,
        'epoch': epoch,
        if (reason != null) 'reason': reason,
      };
}

/// 能力申报项。
///
/// **两个不同结构，不可混用**：
/// - 上行（配对请求 `POST /devices/pair`）：服务端 `capabilityInput` **只接受
///   `name` / `version`**（`device_handler.go:46-49`），多余字段会被
///   `DisallowUnknownFields` 拒为 400。→ 上行请用 [toRequestJson]。
/// - 下行（`model.Capability`，`device.go:72-77`）：含 `device_id`(omitempty)
///   与 `updated_at`（**非 omitempty，恒出现**）。→ 解析请用 [fromJson]。
class Capability {
  const Capability({
    required this.name,
    required this.version,
    this.deviceId,
    this.updatedAt,
  });

  final String name;
  final String version;

  /// 仅下行存在（服务端 `omitempty`）。
  final String? deviceId;

  /// 仅下行存在（服务端无 omitempty，解析时恒有值）。
  final int? updatedAt;

  /// 解析下行能力项（容忍 `updated_at` 缺失，便于测试构造）。
  factory Capability.fromJson(Map<String, dynamic> json) => Capability(
        name: json['name'] as String,
        version: json['version'] as String? ?? '1',
        deviceId: json['device_id'] as String?,
        updatedAt: asIntOrNull(json['updated_at']),
      );

  /// 上行请求体：**只输出 name/version**，绝不带 device_id /
  /// updated_at（否则被服务端 `DisallowUnknownFields` 拒为 400）。
  Map<String, dynamic> toRequestJson() => {'name': name, 'version': version};

  /// 下行完整形态（含 device_id / updated_at 的语义）。
  Map<String, dynamic> toJson() => {
        if (deviceId != null) 'device_id': deviceId,
        'name': name,
        'version': version,
        'updated_at': updatedAt ?? 0,
      };

  @override
  bool operator ==(Object other) =>
      other is Capability && other.name == name && other.version == version;

  @override
  int get hashCode => Object.hash(name, version);

  @override
  String toString() => 'Capability($name v$version)';
}

/// 移动端本期允许申报的能力白名单（架构文档 §6.3.1 / 实施计划 §0.3）。
///
/// **只允许 [network] + [device]**。严禁申报进程类、文件系统类、模型类能力
/// （iOS 无法实现 / 移动端无宿主 / 不承担推理）。
///
/// ⚠️ 本文件**刻意不写出那些被禁标签的字面量**：CI 的 grep 门禁会扫描 `lib/`，
/// 若把禁用词写进源码会让自己触雷。禁用清单与其断言放在
/// `test/protocol/capability_policy_test.dart`，那里不受 grep 门禁约束。
abstract final class MobileCapabilities {
  /// 出网访问能力（HTTP 类轻工具，移动端主战场）。
  static const String network = 'network';

  /// 参与端侧协同能力（接收审批/订阅类任务）。
  static const String device = 'device';

  /// 本期配对上报的能力集合（有且仅有这两项）。
  static const List<Capability> declared = [
    Capability(name: network, version: '1'),
    Capability(name: device, version: '1'),
  ];
}

List<Capability> _capsFromJson(Object? raw) {
  if (raw is! List) return const [];
  return raw
      .whereType<Map<String, dynamic>>()
      .map(Capability.fromJson)
      .toList(growable: false);
}
