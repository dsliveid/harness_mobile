/// 设备当前态模型（**跨来源共享**，不属于任何单一传输层）。
///
/// # 为什么单独成一个文件
/// 移动端有两个来源会产出「设备列表」，它们的数据形状**不同**：
///
/// | 来源 | 服务端类型 | 主键 | 状态字段 | 传输 |
/// | --- | --- | --- | --- | --- |
/// | 首屏 `GET /api/v1/devices` | `model.Device`（`model/device.go:47-56`） | `id` | `status: "online"/"offline"/"revoked"` | Dio 一次性请求 |
/// | 快照 `GET /api/v1/devices/events` | `device.DeviceState`（`state_bus.go:34-55`） | `device_id` | `online: true/false` | SSE 流 |
///
/// 若各自定义一个模型，就会立刻出现两个必然后果：
/// 1. **字段口径漂移**：首屏有 `capabilities`、快照没有，UI 上「某列设备信息
///    在实时同步后突然消失」这类错位；
/// 2. **无法合并**：两批对象类型不同，按 id upsert 时得写一层手工转换，
///    而转换层一旦漏字段，bug 表现为「设备在线状态永远不更新」。
///
/// 因此模型放在 `data/model/`（两侧共同依赖），**归约**才放在
/// `data/sse/`（只服务事件流）。方向永远是 `sse → model`、`remote → model`，
/// 绝不允许 `remote → sse`。
library;

/// 服务端 `model.Device.Status` 的在线取值（`model/device.go:28-32`）。
///
/// 首屏用字符串 `status`，SSE 快照用布尔 `online`；本常量用于把前者归一到后者。
/// 只认 `online` 一个值：`offline` 与 `revoked` 在列表视图里都不算「可用」。
const String deviceStatusOnline = 'online';

/// 单台设备的当前态。
///
/// 刻意保持精简且**不含任何令牌**（服务端 `state_bus.go:32-33` 的红线：
/// `token_hash` 属敏感派生值，绝不外泄到端侧或日志）。
class DeviceState {
  const DeviceState({
    required this.deviceId,
    required this.name,
    required this.kind,
    required this.online,
    this.userId,
    this.lastSeenAt,
    this.protocolVersion,
  });

  final String deviceId;
  final String name;
  final String kind;

  /// 当前是否持有活跃长连接。
  final bool online;

  /// 设备归属账号 id。
  ///
  /// 空 = 归属未知（0011 迁移之前配对的历史设备）。服务端明确要求
  /// 「如实展示为『未绑定账号』而不是隐藏该设备」—— 它仍在正常工作，
  /// 只是缺归属、不能自续会话。
  final String? userId;

  /// 最近一次活动时刻（Unix 毫秒）。离线后仍保留，便于展示「最后在线时间」，
  /// 而不是只显示一个「离线」（服务端 `state_bus.go:50-52`）。
  final int? lastSeenAt;

  /// 端侧上报的协议版本（仅在线时有意义）。
  final int? protocolVersion;

  /// 是否归属未知（UI 据此展示「未绑定账号」）。
  bool get hasOwner => userId != null && userId!.isNotEmpty;

  /// 从服务端 JSON 解析；**字段缺失不抛**（向前兼容）。
  ///
  /// 🔴 必须同时吃两种字段口径 —— 原因见文件头表格。若只认一种，
  /// 另一种来源解析出来就是「空 id + 永远离线」，两批对象无法合并。
  factory DeviceState.fromJson(Map<String, dynamic> json) => DeviceState(
        deviceId: _stringOf(json['device_id'] ?? json['id']),
        name: _stringOf(json['name']),
        kind: _stringOf(json['kind']),
        // 状态归一：布尔 `online` 优先，其次字符串 `status == "online"`。
        online: json['online'] == true || json['status'] == deviceStatusOnline,
        userId: _nullableStringOf(json['user_id']),
        lastSeenAt: _nullableIntOf(json['last_seen_at']),
        protocolVersion: _nullableIntOf(json['protocol_version']),
      );

  DeviceState copyWith({
    String? name,
    String? kind,
    bool? online,
    String? userId,
    int? lastSeenAt,
    int? protocolVersion,
  }) =>
      DeviceState(
        deviceId: deviceId,
        name: name ?? this.name,
        kind: kind ?? this.kind,
        online: online ?? this.online,
        userId: userId ?? this.userId,
        lastSeenAt: lastSeenAt ?? this.lastSeenAt,
        protocolVersion: protocolVersion ?? this.protocolVersion,
      );

  @override
  bool operator ==(Object other) =>
      other is DeviceState &&
      other.deviceId == deviceId &&
      other.name == name &&
      other.kind == kind &&
      other.online == online &&
      other.userId == userId &&
      other.lastSeenAt == lastSeenAt &&
      other.protocolVersion == protocolVersion;

  @override
  int get hashCode => Object.hash(
        deviceId,
        name,
        kind,
        online,
        userId,
        lastSeenAt,
        protocolVersion,
      );

  @override
  String toString() => 'DeviceState($deviceId, $name, online=$online)';
}

/// 把服务端返回的**数组**解析成设备列表（两种来源共用）。
///
/// 首屏的 `items` 与快照帧的 `all` 是同一份字段口径的超集，共用解析器
/// 保证「首屏灌入的列表」与「SSE 覆盖后的列表」类型完全一致。
///
/// 无 id 的条目直接丢弃：它无法被 upsert / 移除，留着只会污染列表。
List<DeviceState> devicesFromJsonList(Object? raw) {
  if (raw is! List) return const <DeviceState>[];
  final List<DeviceState> result = <DeviceState>[];
  for (final Object? item in raw) {
    if (item is! Map<String, dynamic>) continue;
    final DeviceState device = DeviceState.fromJson(item);
    if (device.deviceId.isEmpty) continue;
    result.add(device);
  }
  return result;
}

/// 两份列表是否等价（顺序敏感，元素级相等）。
///
/// 用于「内容未变则不通知 UI」的判据：重连后必然收到与快照重复的帧，
/// 若不判等就会每次重连都让整页重建一次（用户可见的闪烁）。
bool sameDeviceList(List<DeviceState> a, List<DeviceState> b) {
  if (a.length != b.length) return false;
  for (int i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

String _stringOf(Object? value) => value is String ? value : '';

String? _nullableStringOf(Object? value) =>
    value is String && value.isNotEmpty ? value : null;

int? _nullableIntOf(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return null;
}
