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
///   `device_token` 明文**仅此一次**返回。服务端「配对后免二次登录」上线后
///   还会**并列**追加 `user_token / user / session_ttl_s`（三者同生共死，
///   全无即合法降级，见 [PairedDevice.hasUserSession]）。
/// - `GET    /api/v1/devices`             → `{items, pair_ttl_s, heartbeat_s, offline_after_s}`
/// - `DELETE /api/v1/devices/{did}`       204（**管理端专用**，端侧解绑走 [DeviceApi.unpair]）
/// - `POST   /api/v1/devices/unpair`      **凭设备令牌**吊销自己，204（幂等）
library;

import '../../core/error/app_error.dart';
import '../../protocol/frame_payloads.dart';
import '../local/secure_store.dart';
// 复用登录链路的用户视图类型：配对下发的 `user` 与 `/auth/login` 的 `user`
// 是同一份服务端结构（id/username/display_name/role），刻意不另立类型。
import 'auth_api.dart' show AuthUser;
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
///
/// 契约演进（服务端「配对后免二次登录」）：201 响应在原有四个字段之外
/// **可能**追加 `user_token` / `user` / `session_ttl_s` 三兄弟：
/// ```json
/// {
///   "device_id": "...", "device_token": "...",
///   "ws_path": "/api/v1/devices/ws", "protocol_version": 1,
///   "user_token": "hgt_...",
///   "user": {"id": "...", "username": "...", "display_name": "...", "role": "owner"},
///   "session_ttl_s": 604800
/// }
/// ```
/// 铁律：三者**要么全有、要么全无**。全无是**合法降级**（旧服务端或历史配对码
/// 未携带授权用户），此时 [hasUserSession] 为 false，上层回落「配对成功后请登录」。
/// 因此解析必须**容错**：字段缺失 / 类型不符 / `user` 为 null 一律不抛异常。
class PairedDevice {
  PairedDevice({
    required this.deviceId,
    required this.deviceToken,
    required this.wsPath,
    required this.protocolVersion,
    this.userToken,
    this.user,
    this.sessionTtlS,
  });

  factory PairedDevice.fromJson(Map<String, dynamic> json) => PairedDevice(
        deviceId: _stringOf(json['device_id']),
        deviceToken: _stringOf(json['device_token']),
        wsPath: _stringOf(json['ws_path']),
        protocolVersion: _intOf(json['protocol_version']),
        // 以下三项全部走宽容解析：非字符串 / 非对象 / 非数字一律视为「未提供」，
        // 绝不让一个畸形字段把整次配对打成失败（配对本身已经成功且令牌已发）。
        userToken: _nonEmptyStringOrNull(json['user_token']),
        user: _authUserOrNull(json['user']),
        sessionTtlS: _intOrNull(json['session_ttl_s']),
      );

  final String deviceId;

  /// 设备令牌明文（仅此一次返回，立即落 [SecureStore]）。
  final String deviceToken;

  /// 设备长连接 WS 路径（P6 使用）。
  final String wsPath;

  final int protocolVersion;

  /// 用户令牌明文（服务端「配对即登录」能力；**仅此一次返回**，由
  /// [DeviceApi.pair] 直接落 [SecureStore]，本字段不进任何日志 —— 红线 R3）。
  ///
  /// 为 null 表示服务端本次没下发会话（**合法降级**），上层须继续走登录页。
  final String? userToken;

  /// 授权用户视图（与 [userToken] 同生共死；仅用于展示，非机密）。
  final AuthUser? user;

  /// 会话有效期（秒，服务端直接下发；端侧不做推算）。
  final int? sessionTtlS;

  /// 本次配对是否**一并拿到了用户会话**（三兄弟齐备才算）。
  ///
  /// 刻意要求三者同时具备：若服务端只回令牌不回用户，端侧无法展示账号，
  /// 与其进入「半个登录态」不如按降级处理，让用户走一次正常登录。
  bool get hasUserSession =>
      (userToken?.isNotEmpty ?? false) &&
      user != null &&
      sessionTtlS != null;

  /// 令牌一律打码，避免误入日志（红线 R3）。
  @override
  String toString() => 'PairedDevice($deviceId, token=***, ws=$wsPath, '
      'v=$protocolVersion, signedIn=$hasUserSession)';
}

/// 设备令牌自续会话的**三态结果**（刻意不是 `bool` / 可空对象）。
///
/// 为什么必须是三态：调用方（`WebViewTicketApi.prepareAuth`）要对三种情况给出
/// **完全不同的自救指引**，折成两态就只能给一句含糊文案：
/// - [renewed]：换到新会话，可以继续签 ticket —— 无事发生；
/// - [rejected]：服务端**明确拒绝**（设备令牌无效 / 已吊销 / 归属账号未知）。
///   这是**确定性**结论，重试一万次也没用 → 必须引导「回账号页重新登录 / 重新配对」；
/// - [unavailable]：**无法判定**（本机没配对、服务端未实现该端点 404、网络异常）。
///   这类失败只值得重试，不该吓唬用户去重新配对。
enum DeviceSessionStatus {
  /// 已换到新的用户令牌（并已落 Keychain）。
  renewed,

  /// 服务端明确拒绝（HTTP 401 / 403）。
  rejected,

  /// 无法判定（未配对 / 端点未实现 / 网络异常 / 响应缺 `user_token`）。
  unavailable,
}

/// 设备令牌自续会话的结果。
///
/// **不含任何令牌明文**（红线 R3）：新令牌在 [DeviceApi.renewSession] 内部
/// 直接写入 [SecureStore]，本对象只携带展示用的用户视图与 TTL。
class DeviceSessionOutcome {
  const DeviceSessionOutcome._({
    required this.status,
    this.user,
    this.sessionTtlS,
  });

  /// 续期成功。`user` / `sessionTtlS` 可为空（宽容解析：服务端少给字段
  /// 不该把整次续期打回失败 —— 令牌已经拿到，票据签发只需要令牌）。
  const DeviceSessionOutcome.renewed({AuthUser? user, int? sessionTtlS})
      : this._(status: DeviceSessionStatus.renewed, user: user, sessionTtlS: sessionTtlS);

  /// 服务端明确拒绝（401 吊销 / 403 归属未知）。
  const DeviceSessionOutcome.rejected()
      : this._(status: DeviceSessionStatus.rejected);

  /// 无法判定（未配对 / 404 / 网络异常）。
  const DeviceSessionOutcome.unavailable()
      : this._(status: DeviceSessionStatus.unavailable);

  final DeviceSessionStatus status;

  /// 授权用户视图（展示用，非机密）。
  final AuthUser? user;

  /// 会话有效期（秒，服务端直接下发）。
  final int? sessionTtlS;

  bool get renewed => status == DeviceSessionStatus.renewed;

  /// 是否为「设备绑定已坏」的确定性结论（决定要不要引导重新配对）。
  bool get isRejected => status == DeviceSessionStatus.rejected;

  @override
  String toString() => 'DeviceSessionOutcome(${status.name})';
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

  /// 凭配对码完成配对。成功后把 `device_token` 写入 [SecureStore]；
  /// 若服务端**一并**下发了用户会话（`user_token`），则同规格写入用户令牌，
  /// 使上层可直接 `markSignedIn()` 跳过登录页。
  ///
  /// 能力集合默认取 [MobileCapabilities.declared]（network + device 两项），
  /// 上行序列化走 [Capability.toRequestJson]，**只发 name/version**。
  ///
  /// ⚠️ 用户令牌的落盘位置与 [AuthApi.login] **完全一致**
  /// （`SecureStore.setUserToken`，即 Keychain / Keystore），红线 R3：
  /// 令牌不进日志、不进异常文案、不做内存缓存。
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

    // 服务端「配对即登录」：三兄弟齐备才落用户令牌。
    // 缺失是**合法降级**（旧服务端 / 历史配对码），此处静默跳过，
    // 绝不因为没拿到会话而让整次配对失败 —— 设备授权已经生效。
    if (result.hasUserSession) {
      await _store.setUserToken(result.userToken!);
    }
    return result;
  }

  /// 用**设备令牌**换取新的用户会话（`POST /api/v1/devices/session`）。
  ///
  /// ## 为什么端侧需要它（Bug 1 根因，勿删）
  /// 用户会话默认 7 天过期（服务端 `session_ttl_h=168`），而 `device_token`
  /// **无法**通过 `/api/**` 的用户令牌中间件 —— 第 8 天 `prepareAuth` 去签
  /// webview-ticket 必然 401，首帧 fail-closed，用户再也进不去内置页面。
  /// 本方法与 [pair] 是**同一枚**设备令牌的第二次用途：把「设备仍被授权」
  /// 翻译成「一份新的用户会话」。
  ///
  /// ## 契约（权威，勿改字段名）
  /// ```
  /// POST /api/v1/devices/session
  /// Header: Authorization: Bearer <device_token>   ← 只认设备令牌
  /// Body: 无
  /// 200: {user_token, user:{id,username,display_name,role}, session_ttl_s}
  /// 401: 设备令牌无效 / 已吊销 / 缺失（含误用 user_token 来调）
  /// 403: 归属账号未知（device.owner_unknown）
  /// ```
  /// 三字段**要么全有要么全无**；幂等可重试（服务端每次签发新会话，旧的自然过期）。
  ///
  /// ## 解析宽容与降级
  /// 字段缺失 / 类型不符 / `user` 为 null **一律不抛异常**。但 `user_token`
  /// 是唯一**必需**项：拿不到它就没有「新会话」这回事，返回
  /// [DeviceSessionOutcome.unavailable] 让调用方走降级，而不是抛错打断链路。
  ///
  /// ## 红线 R3
  /// 新令牌在末尾直接 `_store.setUserToken`（与 [AuthApi.login]、[pair] 同规格），
  /// 本方法**不返回**令牌、不打日志、不进异常文案。
  Future<DeviceSessionOutcome> renewSession() async {
    final deviceToken = await _store.getDeviceToken();
    // 未配对：连身份都没有，打端点只会拿一个 401 回来浪费一次往返。
    if (deviceToken == null || deviceToken.isEmpty) {
      return const DeviceSessionOutcome.unavailable();
    }

    const Map<String, dynamic> noBody = <String, dynamic>{};
    final Map<String, dynamic> data;
    try {
      data = await _client.post<Map<String, dynamic>>(
        '/api/v1/devices/session',
        // 服务端 `decodeJSON` 启用 DisallowUnknownFields：无 body 就发空对象，
        // 绝不塞 `{}` 以外的任何键（也不发 null —— 部分网关会当畸形请求）。
        body: noBody,
        // ⚠️ Bearer 必须是 device_token；默认拦截器注入的是用户令牌，
        // 用 skipAuthKey 关掉它，否则会变成「用失效的用户令牌去续期」→ 必然 401。
        options: ApiClient.deviceAuth(deviceToken),
        parse: mapOf,
      );
    } on AppError catch (error) {
      // 401（无效/吊销/误用用户令牌）与 403（owner_unknown）是服务端给出的
      // **确定性拒绝**，值得让用户去重新配对/登录；
      // 其余（网络、5xx、404 端点未实现）都属于「无法判定」，只值得重试。
      if (error.statusCode == 401 || error.statusCode == 403) {
        return const DeviceSessionOutcome.rejected();
      }
      return const DeviceSessionOutcome.unavailable();
    } on Object {
      return const DeviceSessionOutcome.unavailable();
    }

    // 宽容解析：非字符串 / 空串都视为「没换到会话」。
    final String? token = _nonEmptyStringOrNull(data['user_token']);
    if (token == null) return const DeviceSessionOutcome.unavailable();

    await _store.setUserToken(token);
    return DeviceSessionOutcome.renewed(
      user: _authUserOrNull(data['user']),
      sessionTtlS: _intOrNull(data['session_ttl_s']),
    );
  }

  /// 用户会话是否仍然有效（`GET /api/v1/auth/me` 200 即有效）。
  ///
  /// ## 为什么必须先验再写 Cookie（Bug 2 根因，勿删）
  /// 旧实现只看「Keychain 里有非空 token」就把它写进 `hg_sess` 并报成功。
  /// 令牌过期后，页面拿这枚死令牌请求 `/auth/me` 得到 401 → Web UI 显示
  /// 登录表单 → 用户在移动端 WebView 里再登一次 → 新会话**只进 Cookie、
  /// 不认 Keychain** → 原生与页面两套账，「单一登录」破产。
  ///
  /// 因此注入前必须问服务端一句「这枚令牌还认不认」，认才写。
  /// 任何异常（401/403/网络）都按**无效**处理：宁可 fail-closed 让用户
  /// 回账号页，也绝不把死令牌塞进页面制造两套账。
  Future<bool> isSessionValid() async {
    final token = await _store.getUserToken();
    if (token == null || token.isEmpty) return false;
    try {
      await _client.get<Map<String, dynamic>>(
        '/api/v1/auth/me',
        parse: mapOf,
      );
      return true;
    } on Object {
      return false;
    }
  }

  /// 设备列表（含在线状态与能力项）。
  Future<List<DeviceInfo>> listDevices() => _client.get<List<DeviceInfo>>(
        '/api/v1/devices',
        parse: (Object? data) => itemsOf(data)
            .map(DeviceInfo.fromJson)
            .toList(growable: false),
      );

  /// 吊销**任意**设备（`DELETE /api/v1/devices/{did}`）。
  ///
  /// 🔴 **仅管理端 / 用户会话可调用，端侧解绑本机绝不能用它**（2026-11 定案）：
  /// 该端点挂在 `/api/v1/**` 用户令牌中间件后面，而端侧点「解除本机绑定」
  /// 时手里**只有 device_token** —— `user_token` 可能早已过期 7 天
  /// （正是设备持久绑定要解决的那个问题），因此结构上不可达。
  /// 历史上本方法一度是**全仓库零调用点**的死代码，正是这个原因。
  ///
  /// 端侧自我解绑一律走 [unpair]（凭设备令牌吊销自己）。
  ///
  /// 服务端返回 204 空响应，只关心状态码是否 2xx。
  Future<void> revoke(String deviceId) => _client.delete<Map<String, dynamic>>(
        '/api/v1/devices/$deviceId',
        parse: mapOf,
      );

  /// 端侧**自我解约**：凭 device_token 吊销本机（`POST /api/v1/devices/unpair`）。
  ///
  /// ## 为什么需要它（Bug 根因，勿删）
  /// 旧实现在账号页 / 登录页点「解除本机绑定」时**只清本地凭据**，服务端
  /// devices 表里那台设备依然是 `online/offline` 的绑定记录 —— 管理端「设备
  /// 列表」里它永远挂着，用户以为解绑了、服务端认为还绑着，两端各说一套。
  /// 而唯一能吊销的 `DELETE /devices/{did}` 需要用户令牌（见 [revoke]），
  /// 解绑时刻只有设备令牌，结构上够不着。本方法就是补上的那条腿。
  ///
  /// ## 契约（权威，勿改字段名）
  /// ```
  /// POST /api/v1/devices/unpair
  /// Header: Authorization: Bearer <device_token>   ← 只认设备令牌
  /// Body: 无
  /// 204: 已吊销（**幂等**：令牌无效 / 设备不存在 / 已吊销 也是 204）
  /// 401: 缺少设备令牌（调用方编程错误）
  /// ```
  /// 服务端吊销后还会通过 WS 推 `device.revoked` 并断开连接；其他端的设备
  /// 列表也会立刻不再返回本机（吊销即从列表消失）。
  ///
  /// ## 语义边界（勿与登出混淆）
  /// 只吊销**设备绑定**，不动用户会话（那是 `/auth/logout`）。本方法也
  /// **不**清本地凭据 —— 本地清理由调用方按既有顺序执行（见账号页：
  /// 先 unpair 拿到令牌，再停 WS → 清 Cookie → `resetPairing()`），
  /// 这样 unpair 失败时本地解绑仍能完成。
  ///
  /// ## 幂等与失败语义
  /// 服务端对「令牌无效 / 已吊销」都回 204，所以正常路径**不需要**区分
  /// 「真的吊销了」和「本来就没绑」。唯一的端侧前置失败是「本机压根没有
  /// 设备令牌」—— 此时**不发请求**（必然 401，白打服务端日志），直接抛
  /// [AppError]，让调用方给用户一句「未能通知服务端」。
  Future<void> unpair() async {
    final deviceToken = await _store.getDeviceToken();
    if (deviceToken == null || deviceToken.isEmpty) {
      throw AppError.local('device.no_token', '本机没有设备令牌，无法通知服务端');
    }
    await _client.post<Map<String, dynamic>>(
      '/api/v1/devices/unpair',
      // 服务端 `unpairDevice` 不读请求体（`device_handler.go:226-242`），
      // 发空对象与 `POST /devices/session` 保持同一形态。
      body: const <String, dynamic>{},
      // ⚠️ Bearer 必须是 device_token；默认拦截器注入的是用户令牌，
      // 用 deviceAuth 关掉它，否则会变成「用可能已过期的用户令牌解绑」→ 401。
      options: ApiClient.deviceAuth(deviceToken),
      parse: mapOf,
    );
  }
}

String _stringOf(Object? value) => value is String ? value : '';

/// 非空字符串或 null（`user_token` 用：空串等同于没下发）。
String? _nonEmptyStringOrNull(Object? value) =>
    (value is String && value.isNotEmpty) ? value : null;

/// 宽容解析用户对象：只有 Map 才尝试构造，其它类型（含 null）一律视为未提供。
///
/// 字段级也走 `_stringOf` 兜底，因此服务端少给 `display_name` 之类不会崩。
AuthUser? _authUserOrNull(Object? value) {
  if (value is! Map) return null;
  return AuthUser.fromJson(Map<String, dynamic>.from(value));
}

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
