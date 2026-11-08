/// 设备 API（对齐服务端 `internal/api/device_handler.go`）。
///
/// 契约要点（已核实源码，勿改）：
/// - `POST   /api/v1/devices/pair-codes`  需鉴权，请求 `{name, kind}`（`device_handler.go:21-24`）
///   → `PairCodeView`（`service/device_service.go:169-176`：
///   `code / expires_at / ttl_s / device_name? / device_kind?`）
/// - `POST   /api/v1/devices/pair`        **免鉴权**，请求体键集合**必须恰为**
///   `{code, name, kind, platform, app_version, capabilities}`（`device_handler.go:51-58`），
///   capabilities 每项**只允许** `{name, version}`（`device_handler.go:46-49`）。
///   服务端启用 `DisallowUnknownFields`，多一个键就是 400。
///   → 201 `PairResult`（`device_service.go:206-212`：
///   `device_id / device_token / ws_path / protocol_version`），
///   `device_token` 明文**仅此一次**返回。
/// - `GET    /api/v1/devices`             → `{items, pair_ttl_s, heartbeat_s, offline_after_s}`
/// - `DELETE /api/v1/devices/{did}`       204
library;

import '../../protocol/frame_payloads.dart';
import '../local/secure_store.dart';
import 'http_client.dart';

/// 设备形态常量（服务端 `model/device.go:8-14`）。
abstract final class DeviceKinds {
  static const String desktop = 'desktop';
  static const String tablet = 'tablet';
  static const String mobile = 'mobile';
  static const String cli = 'cli';
  static const String browser = 'browser';

  static const List<String> values = <String>[
    desktop,
    tablet,
    mobile,
    cli,
    browser,
  ];
}

/// 设备在线状态常量（服务端 `model/device.go:28-32`）。
abstract final class DeviceStatuses {
  static const String online = 'online';
  static const String offline = 'offline';
  static const String revoked = 'revoked';
}

/// 配对码视图（服务端 `PairCodeView`）。
class PairCodeView {
  const PairCodeView({
    required this.code,
    required this.expiresAt,
    required this.ttlSeconds,
    this.deviceName,
    this.deviceKind,
  });

  factory PairCodeView.fromJson(Map<String, dynamic> json) => PairCodeView(
        code: _stringOf(json['code']),
        expiresAt: _intOf(json['expires_at']),
        ttlSeconds: _intOf(json['ttl_s']),
        deviceName: json['device_name'] as String?,
        deviceKind: json['device_kind'] as String?,
      );

  /// 6 位一次性配对码（TTL 120s）。
  final String code;

  /// 过期时刻（Unix 毫秒）。
  final int expiresAt;

  /// 剩余有效期（秒，服务端直接下发，端侧不必自行推算）。
  final int ttlSeconds;

  final String? deviceName;
  final String? deviceKind;

  @override
  String toString() => 'PairCodeView($code, ttl=${ttlSeconds}s)';
}

/// 配对成功结果。**含明文令牌，禁止打印**（红线 R3）。
class PairedDevice {
  PairedDevice({
    required this.deviceId,
    required this.deviceToken,
    required this.wsPath,
    required this.protocolVersion,
  });

  factory PairedDevice.fromJson(Map<String, dynamic> json) => PairedDevice(
        deviceId: _stringOf(json['device_id']),
        deviceToken: _stringOf(json['device_token']),
        wsPath: _stringOf(json['ws_path']),
        protocolVersion: _intOf(json['protocol_version']),
      );

  final String deviceId;

  /// 设备令牌明文（仅此一次返回，立即落 [SecureStore]）。
  final String deviceToken;

  /// 设备长连接 WS 路径（P6 使用）。
  final String wsPath;

  final int protocolVersion;

  /// 令牌打码，避免误入日志（红线 R3）。
  @override
  String toString() =>
      'PairedDevice($deviceId, token=***, ws=$wsPath, v=$protocolVersion)';
}

/// 设备列表项（服务端 `model.Device`，`model/device.go:47-64`）。
class DeviceInfo {
  const DeviceInfo({
    required this.id,
    required this.name,
    required this.kind,
    required this.platform,
    required this.status,
    required this.capabilitiesHash,
    required this.protocolVersion,
    required this.appVersion,
    required this.pairedAt,
    required this.createdAt,
    required this.updatedAt,
    this.lastSeenAt,
    this.revokedAt,
    this.capabilities = const <Capability>[],
  });

  factory DeviceInfo.fromJson(Map<String, dynamic> json) => DeviceInfo(
        id: _stringOf(json['id']),
        name: _stringOf(json['name']),
        kind: _stringOf(json['kind']),
        platform: _stringOf(json['platform']),
        status: _stringOf(json['status']),
        capabilitiesHash: _stringOf(json['capabilities_hash']),
        protocolVersion: _intOf(json['protocol_version']),
        appVersion: _stringOf(json['app_version']),
        pairedAt: _intOf(json['paired_at']),
        lastSeenAt: _intOrNull(json['last_seen_at']),
        revokedAt: _intOrNull(json['revoked_at']),
        createdAt: _intOf(json['created_at']),
        updatedAt: _intOf(json['updated_at']),
        capabilities: _capabilitiesOf(json['capabilities']),
      );

  final String id;
  final String name;
  final String kind;
  final String platform;
  final String status;
  final String capabilitiesHash;
  final int protocolVersion;
  final String appVersion;
  final int pairedAt;
  final int? lastSeenAt;
  final int? revokedAt;
  final int createdAt;
  final int updatedAt;
  final List<Capability> capabilities;

  bool get isOnline => status == DeviceStatuses.online;
  bool get isRevoked => status == DeviceStatuses.revoked;

  @override
  String toString() => 'DeviceInfo($id, $name, $status)';
}

/// 设备 API。
class DeviceApi {
  DeviceApi({
    required ApiClient client,
    required SecureStore store,
    this.platform = 'android',
    this.appVersion = '0.1.0',
  })  : _client = client,
        _store = store;

  final ApiClient _client;
  final SecureStore _store;

  /// 端侧平台标识（随配对上报，服务端用于多端展示）。
  final String platform;

  /// 端侧版本号（随配对上报）。
  final String appVersion;

  /// 生成配对码（管理端角色使用；移动端通常只消费配对码）。
  Future<PairCodeView> createPairCode({
    required String name,
    String kind = DeviceKinds.mobile,
  }) =>
      _client.post<PairCodeView>(
        '/api/v1/devices/pair-codes',
        body: <String, dynamic>{'name': name, 'kind': kind},
        parse: (Object? data) => PairCodeView.fromJson(mapOf(data)),
      );

  /// 凭配对码完成配对。成功后把 `device_token` 写入 [SecureStore]。
  ///
  /// 能力集合默认取 [MobileCapabilities.declared]（network + device 两项），
  /// 上行序列化走 [Capability.toRequestJson]，**只发 name/version**。
  Future<PairedDevice> pair({
    required String code,
    required String name,
    String kind = DeviceKinds.mobile,
    String? platformOverride,
    String? appVersionOverride,
    List<Capability> capabilities = MobileCapabilities.declared,
  }) async {
    final result = await _client.post<PairedDevice>(
      '/api/v1/devices/pair',
      // ⚠️ 键集合必须恰为这 6 个：DisallowUnknownFields 下多一个键即 400
      body: <String, dynamic>{
        'code': code,
        'name': name,
        'kind': kind,
        'platform': platformOverride ?? platform,
        'app_version': appVersionOverride ?? appVersion,
        'capabilities': capabilities
            .map((Capability c) => c.toRequestJson())
            .toList(growable: false),
      },
      options: ApiClient.skipAuth(),
      parse: (Object? data) => PairedDevice.fromJson(mapOf(data)),
    );

    if (result.deviceToken.isEmpty) {
      throw StateError('配对成功但服务端未返回设备令牌');
    }
    await _store.setDeviceToken(result.deviceToken);
    return result;
  }

  /// 设备列表（含在线状态与能力项）。
  Future<List<DeviceInfo>> listDevices() => _client.get<List<DeviceInfo>>(
        '/api/v1/devices',
        parse: (Object? data) => itemsOf(data)
            .map(DeviceInfo.fromJson)
            .toList(growable: false),
      );

  /// 吊销设备（令牌立即失效 + 服务端断连）。
  ///
  /// 服务端返回 204 空响应，只关心状态码是否 2xx。
  Future<void> revoke(String deviceId) => _client.delete<Map<String, dynamic>>(
        '/api/v1/devices/$deviceId',
        parse: mapOf,
      );
}

String _stringOf(Object? value) => value is String ? value : '';

int _intOf(Object? value) {
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value) ?? 0;
  return 0;
}

int? _intOrNull(Object? value) {
  if (value == null) return null;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value);
  return null;
}

List<Capability> _capabilitiesOf(Object? raw) {
  if (raw is! List) return const <Capability>[];
  return raw
      .whereType<Map<String, dynamic>>()
      .map(Capability.fromJson)
      .toList(growable: false);
}
