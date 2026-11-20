/// 设备状态**归约**（纯函数，零 IO / 零 Flutter 依赖）。
///
/// # 契约来源（已源码核准）
/// `internal/device/state_bus.go:30-81` + `internal/api/device_events_handler.go`：
///
/// ```
/// event: snapshot
/// data: {"type":"snapshot","all":[<DeviceState>...],"at":<ms>}
///
/// event: device.online
/// data: {"type":"device.online","device":{...},"at":<ms>}
///
/// event: device.offline
/// data: {"type":"device.offline","device":{...},"at":<ms>}
///
/// event: device.revoked
/// data: {"type":"device.revoked","device":{"device_id":"..."},"at":<ms>}
/// ```
///
/// # 分层边界（勿混）
/// - **模型**在 `lib/data/model/device_state.dart`（首屏与快照两种来源共用）；
/// - **归约**在本文件（只服务事件流；首屏不需要归约，它本身就是快照）。
///
/// 本文件不碰 IO、不碰 Flutter、不碰时间 ⇒ 全部语义都能用纯函数断言钉死，
/// 包括最容易搞错的那条红线：
///
/// | 事件 | 语义 | 归约动作 |
/// | --- | --- | --- |
/// | `snapshot` | 全量当前态 | **整表替换**（重连后的权威视图） |
/// | `device.online` | 某设备上线 | 按 `deviceId` **upsert**，`online=true` |
/// | `device.offline` | **暂时**连不上，仍在绑定关系中 | 按 `deviceId` **upsert**，`online=false`，**卡片必须保留** |
/// | `device.revoked` | 绑定关系**终止** | 按 `deviceId` **移除** |
///
/// 🔴 最易犯的错误是把 `offline` 与 `revoked` 合为一个：
/// 那样用户「解除绑定」后前端只会把卡片标灰、设备依然留在列表里
/// （`state_bus.go:74-80` 的注释就是在记录这个已发生过的 bug）。
library;

import '../model/device_state.dart';
import 'sse_event.dart';

/// 事件名常量（与服务端 `state_bus.go:69-81` 逐字对齐，禁止自造）。
abstract final class DeviceEventTypes {
  /// 订阅首帧的全量快照。
  static const String snapshot = 'snapshot';

  /// 某设备上线。
  static const String online = 'device.online';

  /// 某设备离线（**仍在绑定关系中**，卡片保留并标灰）。
  static const String offline = 'device.offline';

  /// 设备被吊销（= 解除绑定，**必须从列表移除**）。
  static const String revoked = 'device.revoked';
}

/// 归约结果：新列表 + 是否发生了实质变化。
///
/// 为什么要带 [changed]：SSE 会因重连收到**重复**帧（§4.4 第 2 条：
/// 重复是正常的）。控制器据此避免无意义地 `notifyListeners()`
/// （否则每次重连都会让整页重建一次，表现为可见的闪烁）。
class DeviceListChange {
  const DeviceListChange({required this.devices, required this.changed});

  final List<DeviceState> devices;
  final bool changed;

  /// 无变化时**原样返回入参**（保持引用相等，让上层可据此短路）。
  static DeviceListChange unchanged(List<DeviceState> devices) =>
      DeviceListChange(devices: devices, changed: false);
}

/// 把一条 [SseEvent] 归约到设备列表上。
///
/// 纯函数：同一输入恒得同一输出，且**不修改**入参列表（返回新列表）。
///
/// - 未知事件名 / 载荷不合形态 ⇒ 原样返回且 `changed=false`
///   （向前兼容：服务端新增事件类型不该让客户端的列表崩掉）。
/// - `snapshot` 的空数组是合法的「零设备」，**不是**解析失败。
DeviceListChange reduceDeviceState(
  List<DeviceState> current,
  SseEvent event,
) {
  final Map<String, dynamic>? payload = event.mapOrNull;
  if (payload == null) return DeviceListChange.unchanged(current);

  switch (event.event) {
    case DeviceEventTypes.snapshot:
      final List<DeviceState> next = devicesFromJsonList(payload['all']);
      // 重连后的权威视图：**整表替换**（D5）。断线期间被 revoked 的设备
      // 若不靠这一步清理，会永久留下幽灵条目。
      // 内容完全相同时**返回入参实例**：否则每次重连都会让 UI 整页重建。
      if (sameDeviceList(current, next)) {
        return DeviceListChange.unchanged(current);
      }
      return DeviceListChange(devices: next, changed: true);

    case DeviceEventTypes.online:
      return _upsert(current, payload['device'], online: true);

    case DeviceEventTypes.offline:
      // 🔴 只是「暂时连不上」：卡片保留、标灰。绝不能在这里移除。
      return _upsert(current, payload['device'], online: false);

    case DeviceEventTypes.revoked:
      final Map<String, dynamic>? device = _mapOf(payload['device']);
      final String id = device == null ? '' : _stringOf(device['device_id']);
      if (id.isEmpty) return DeviceListChange.unchanged(current);
      final List<DeviceState> next = current
          .where((DeviceState d) => d.deviceId != id)
          .toList(growable: false);
      // 找不到该 id 时不算变化（重复帧 / 已被快照清理）。
      if (next.length == current.length) {
        return DeviceListChange.unchanged(current);
      }
      return DeviceListChange(devices: next, changed: true);

    default:
      // 未知事件（未来新增 / 别的域混进来）：静默忽略。
      return DeviceListChange.unchanged(current);
  }
}

DeviceListChange _upsert(
  List<DeviceState> current,
  Object? rawDevice, {
  required bool online,
}) {
  final Map<String, dynamic>? device = _mapOf(rawDevice);
  if (device == null) return DeviceListChange.unchanged(current);
  final DeviceState incoming = DeviceState.fromJson(device);
  if (incoming.deviceId.isEmpty) return DeviceListChange.unchanged(current);

  final List<DeviceState> next = List<DeviceState>.of(current);
  final int index =
      next.indexWhere((DeviceState d) => d.deviceId == incoming.deviceId);
  if (index < 0) {
    // 增量帧先于快照到达（或快照上限外的设备）：直接插入。
    // 以**事件类型**决定 online 而不是载荷字段 —— 服务端快照时刻与事件
    // 时刻存在微差，`device.offline` 的载荷里 online 可能是过期值。
    next.add(incoming.copyWith(online: online));
    return DeviceListChange(devices: next, changed: true);
  }
  final DeviceState merged = incoming.copyWith(
    online: online,
    // 详情字段缺失时保留旧值（`device.revoked` 只发 id，其它事件的载荷
    // 也做了 omitempty 裁剪）。
    name: incoming.name.isEmpty ? next[index].name : null,
    kind: incoming.kind.isEmpty ? next[index].kind : null,
    userId: incoming.userId ?? next[index].userId,
    lastSeenAt: incoming.lastSeenAt ?? next[index].lastSeenAt,
    protocolVersion: incoming.protocolVersion ?? next[index].protocolVersion,
  );
  if (merged == next[index]) return DeviceListChange.unchanged(current);
  next[index] = merged;
  return DeviceListChange(devices: next, changed: true);
}

Map<String, dynamic>? _mapOf(Object? value) =>
    value is Map<String, dynamic> ? value : null;

String _stringOf(Object? value) => value is String ? value : '';
