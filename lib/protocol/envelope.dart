/// 设备协议信封（线格式唯一权威：`harness_go/internal/device/protocol.go:96-109`）。
///
/// 铁律（protocol.go:14-17）：
/// - 所有帧共用同一信封 `{v, type, id, run_id, ts, payload}`
/// - 字段只许新增，禁止删除/改名
library;

/// 协议版本：服务端支持 N 与 N-1（`protocol.go:19-28`）。
///
/// 端侧声明值必须落在 `[MinProtocolVersion, CurrentProtocolVersion]` 内，
/// 否则服务端回 `device.protocol_mismatch` 且**不得静默降级执行**。
class ProtocolVersion {
  const ProtocolVersion._();

  /// 服务端当前协议版本（N）。与 `model.DefaultDeviceProtocolVersion` 对齐。
  static const int current = 1;

  /// 服务端仍接受的最低版本。
  static const int min = 1;

  /// 判定端侧声明版本是否兼容（对齐 `CompatibleVersion`，protocol.go:170-185）。
  ///
  /// 语义「宽进严出」：
  /// - `v == 0`：端侧未声明 → 按最低兼容版本接受
  /// - `min <= v <= current`：兼容
  /// - 其余：不兼容，必须提示升级
  static bool isCompatible(int v) {
    if (v == 0) return true;
    return v >= min && v <= current;
  }
}

/// 帧类型常量（`protocol.go:34-53`）。
abstract final class MessageType {
  /// 端→服：连上后的首帧自述（可选；缺省时以配对本机记录为准）。
  static const String hello = 'hello';

  /// 服→端：握手确认（携带服务端时间、心跳参数、协议版本）。
  static const String welcome = 'welcome';

  /// 端→服：周期心跳，携带负载/能力摘要/协议版本。
  static const String ping = 'ping';

  /// 服→端：对 ping 的应答，携带服务端时间与待派发任务数。
  static const String pong = 'pong';

  /// 双向：错误帧（fatal=true 表示随后断开）。
  static const String error = 'error';

  /// 服→端：任务派发（C-4 dispatcher 发出）。
  static const String taskDispatch = 'task.dispatch';

  /// 端→服：执行进度流式块（C-4）。
  static const String taskProgress = 'task.progress';

  /// 端→服：任务终态结果（C-4）。
  static const String taskResult = 'task.result';

  /// 服→端：会话租约被其他端抢占（C-6）。
  static const String leaseRevoked = 'lease.revoked';

  /// 全部已知帧类型（`Validate` 用，对齐 `MessageType.Valid()`）。
  static const Set<String> all = {
    hello,
    welcome,
    ping,
    pong,
    error,
    taskDispatch,
    taskProgress,
    taskResult,
    leaseRevoked,
  };

  static bool isValid(String t) => all.contains(t);
}

/// 帧级错误码（`protocol.go:57-74`）。
///
/// 与 `apperr` 的对外错误码区分：这里是协议内部码，
/// 端侧按它决定是否重连/升级/解绑。
abstract final class FrameCode {
  /// 帧格式非法（可继续使用连接）。
  static const String badFrame = 'device.bad_frame';

  /// 协议版本不兼容（Fatal，端侧应提示升级）。
  static const String protocolMismatch = 'device.protocol_mismatch';

  /// 服务端未开启远端执行。
  static const String taskUnsupported = 'device.task_unsupported';

  /// 同一 device_token 在别处上线（Fatal）。
  static const String replaced = 'device.replaced';

  /// 心跳失效被服务端判定离线（Fatal）。
  static const String offlineTimeout = 'device.offline_timeout';

  /// 设备已被吊销（Fatal）。
  static const String revoked = 'device.revoked';

  /// 服务端正常退出（Fatal）。
  static const String serverClosing = 'device.server_closing';

  /// 服务端写失败。
  static const String writeFailed = 'device.write_failed';
}

/// 收到 fatal 错误帧后端侧应采取的动作（架构文档 §4.3 决策表）。
///
/// 这张表是「断线是否重连」的唯一决策依据，必须一次写对。
enum WsFatalAction {
  /// 无动作：丢弃该帧，保持连接（如 `bad_frame`）。
  ignore,

  /// 指数退避重连（如 `offline_timeout` / `server_closing` / `write_failed`）。
  reconnect,

  /// 不重连：阻断式提示「请升级 App」（`protocol_mismatch`）。
  upgradeRequired,

  /// 不重连：清空令牌，回配对页（`revoked`）。
  repairPairing,

  /// 不重连：提示「本设备已在其他实例上线」（`replaced`）。
  replacedElsewhere,
}

/// 全局设备协议信封。
///
/// 编解码三约定（架构文档 §4.1）：
/// 1. `int` 一律走 `(x as num).toInt()` —— `ts`/`deadline` 是 int64 毫秒，
///    经 `jsonDecode` 后可能成 `double`，直接 `as int` 会抛 TypeError。
/// 2. Go 侧 `omitempty` 字段为零值时不出现；发送方向用条件键，不写 `null`。
/// 3. `payload` 保持 Map 不预转，按 `type` 二次解码；否则遇到未知新帧整条连接报错。
class Envelope {
  const Envelope({
    required this.v,
    required this.type,
    this.id,
    this.runId,
    this.ts,
    this.payload,
  });

  /// 协议版本（服务端缺省视为「未声明」）。
  final int v;

  /// 帧类型，见 [MessageType]。
  final String type;

  /// 帧 id（幂等/关联用）。
  final String? id;

  /// 关联 Run id（注意 JSON 键是蛇形 `run_id`）。
  final String? runId;

  /// 时间戳（毫秒，仅观测）。
  final int? ts;

  /// 负载，按 [type] 二次解码。
  final Map<String, dynamic>? payload;

  /// 从 JSON 解析。任何数值统一经 `num.toInt()`，防 int64 精度陷阱。
  factory Envelope.fromJson(Map<String, dynamic> json) {
    final rawPayload = json['payload'];
    return Envelope(
      v: _asInt(json['v']) ?? 0,
      type: json['type'] as String,
      id: json['id'] as String?,
      runId: json['run_id'] as String?,
      ts: _asInt(json['ts']),
      payload: rawPayload is Map<String, dynamic> ? rawPayload : null,
    );
  }

  /// 序列化为 JSON。省略 null 字段，对齐 Go 侧 `omitempty`。
  Map<String, dynamic> toJson() => {
        'v': v,
        'type': type,
        if (id != null) 'id': id,
        if (runId != null) 'run_id': runId,
        if (ts != null) 'ts': ts,
        if (payload != null) 'payload': payload,
      };

  /// 帧基本合法性校验（对齐 `Envelope.Validate`，protocol.go:150-159）。
  String? validate() {
    if (type.isEmpty) return '帧缺少 type';
    if (!MessageType.isValid(type)) return '未知帧类型 "$type"';
    return null;
  }

  /// 便捷构造：带负载的帧。
  static Envelope withPayload({
    required String type,
    required Map<String, dynamic> payload,
    String? id,
    String? runId,
  }) =>
      Envelope(
        v: ProtocolVersion.current,
        type: type,
        id: id,
        runId: runId,
        payload: payload,
      );
}

/// 统一的数值解析：兼容 `int` / `double` / `String`，避免 int64 精度陷阱。
int? _asInt(Object? value) {
  if (value == null) return null;
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value);
  return null;
}

/// 供 protocol 层内部复用（payload 解析统一入口）。
int? asIntOrNull(Object? value) => _asInt(value);
