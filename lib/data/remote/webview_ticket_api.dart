/// WebView 认证透传（批次 C-4，接口先行）。
///
/// 背景（架构文档 §4.2）：原生凭据在 Keychain，WebView 的 Cookie jar 是独立的，
/// 不做交换则每次进 WebView 都要重登。两条路径：
///
/// - **方案 B（先行）**：把原生会话 Cookie 写进 WebView 的 CookieManager。
///   服务端零改动，HttpOnly 下页面 JS 读不到；缺点是撤销粒度粗（M6 切方案 C）。
/// - **方案 C（目标态）**：原生换一次性 ticket → 页面用 ticket 换专属短时会话。
///   ticket 走 URL fragment（`#ticket=...`），不进 Referer / 不落 access log。
///
/// 契约（草案，服务端待接线 D4）：
/// ```
/// ① POST /api/v1/auth/webview-ticket   需用户会话
///    Body: { device_id, ttl_s }
///    Resp: { ticket, expires_at }
/// ② 传递：https://<server>/#ticket=<ticket>
/// ③ POST /api/v1/auth/webview-exchange  免鉴权（由 Web 前端自行调用）
///    Body: { ticket }  →  200 + Set-Cookie: hg_sess=...; HttpOnly; SameSite=Lax
/// ```
///
/// 端侧职责边界：
/// - 只负责**签发**与**拼接 URL**；兑换由 Web 前端自己调（本文件不实现 exchange）。
/// - ticket **绝不写日志**，也不放进 [AppError] 文案。
/// - 服务端未实现 ticket 端点时必须**可失败降级**到方案 B，不得让用户卡死。
library;

import '../local/secure_store.dart';
import 'device_api.dart';
import 'http_client.dart';

/// WebView 认证透传结果。
enum WebViewAuthMode {
  /// 未做任何透传（无会话可用，需回原生登录）。
  none,

  /// 方案 C：ticket 签发成功，URL 已带 `#ticket=`。
  ticket,

  /// 方案 B：Cookie 已写入 CookieManager（ticket 不可用时的降级）。
  cookie,
}

/// 票据链路最终失败的**可解释原因**（M3：失败必须能变成用户读得懂的话）。
///
/// 为什么需要它：`prepareAuth` 返回 `none` 时调用方只知道「拿不到凭据」，
/// 无法区分「服务端没实现 ticket 端点」与「票过期且重签失败」，
/// 于是只能给一句笼统文案，用户不知道该重试还是该重新登录。
enum WebViewAuthFailure {
  /// 没有可用的设备身份（会退化为「回配对/登录」）。
  noDeviceId('设备身份缺失，请回配对页重新配对'),

  /// 首次签发的 ticket 在拼接前就已过期，且**重签预算已耗尽**。
  ticketExpired('一次性票据已过期且重签失败，请重试或回账号页重新登录'),

  /// 票据端点调用失败（网络 / 401 / 404），且没有可用的 Cookie 降级。
  ticketIssueFailed('无法获取登录凭据（票据签发失败），请检查网络或回账号页重新登录'),

  /// 设备令牌换新会话被服务端**明确拒绝**（401 已吊销 / 403 归属账号未知）。
  ///
  /// 为什么不复用 [ticketIssueFailed]：这两件事的自救动作根本不同。
  /// 票据失败可能是网络抖动，重试就好；而「设备绑定已失效」重试一万次
  /// 都不会变好，用户必须回账号页重新登录，或干脆重新配对一次。
  /// 把两者混成一句「请检查网络」等于让用户在原地打转。
  deviceSessionFailed('设备绑定已失效，请回账号页重新登录，或重新配对后再试'),

  /// 已用设备令牌换到新会话，但**仍然**签不出 ticket（端点未实现 / 服务端异常）。
  ///
  /// 属于**半成功**：会话续期这一步是通的，问题出在票据签发环节。
  /// 因此文案要给「重试」而不是「重新登录」—— 重新登录并不能修好
  /// 一个 404 的票据端点，只会让用户白丢一次已续好的会话。
  renewedButTicketFailed('登录凭据已续期，但仍无法取得内置页面票据，请重试'),

  /// Cookie 降级路径也不可用。
  cookieUnavailable('无法把登录凭据写入内置页面，请回账号页重新登录');

  const WebViewAuthFailure(this.message);

  /// 用户可读文案（不含任何凭据 / 服务端内部细节）。
  final String message;

  /// 「重试票据申请」这个动作对当前失败**是否有意义**。
  ///
  /// 判断依据：能不能靠「再来一次」变好。
  /// - [ticketExpired] / [ticketIssueFailed] / [renewedButTicketFailed]：
  ///   问题在签发环节（时钟 / 网络抖动 / 端点异常），重跑一次有救；
  /// - [deviceSessionFailed]：设备绑定**已被服务端否定**，重试一万次都是 401，
  ///   给这个按钮等于给用户一个点了没反应的死路；
  /// - [cookieUnavailable]：Cookie jar 写不进去，与票据无关；
  /// - [noDeviceId]：本机根本没配对过，该去配对页而不是重试。
  bool get ticketRetryHelps => switch (this) {
        WebViewAuthFailure.ticketExpired => true,
        WebViewAuthFailure.ticketIssueFailed => true,
        WebViewAuthFailure.renewedButTicketFailed => true,
        WebViewAuthFailure.deviceSessionFailed => false,
        WebViewAuthFailure.cookieUnavailable => false,
        WebViewAuthFailure.noDeviceId => false,
      };
}

/// 透传结果：给调用方决定加载哪个 URL。
class WebViewAuthResult {
  const WebViewAuthResult({
    required this.mode,
    required this.url,
    this.expiresAt,
    this.failure,
    this.ticketRenewCount = 0,
    this.sessionRenewCount = 0,
    this.cookieInjected = false,
  });

  final WebViewAuthMode mode;

  /// 要加载的入口 URL（方案 C 时已带 fragment；方案 B 时是裸入口）。
  final String url;

  /// ticket 过期时刻（服务端 `expires_at`，毫秒时间戳；方案 B/none 为 null）。
  final int? expiresAt;

  /// 失败原因（仅 [WebViewAuthMode.none] 时非空；成功路径必须为 null，
  /// 否则调用方无法区分「成功」与「带着失败原因却仍可用」）。
  final WebViewAuthFailure? failure;

  /// 本次为拿到**可用** ticket 而额外重签的次数（0 表示首发即成功）。
  ///
  /// 观测用：模拟器上若长期 >0，说明 TTL 与冷启动耗时已经打架，需要调 TTL。
  final int ticketRenewCount;

  /// 本次为拿到会话而用**设备令牌续期**的次数（0 表示用户会话未曾过期）。
  ///
  /// 观测用：真机上若长期 >0，说明用户会话 TTL（默认 7 天）短于用户的
  /// 实际使用间隔，属于**正常自愈**；若伴随 [failure] 出现，说明设备侧
  /// 或服务端配置有问题，需要排障。
  final int sessionRenewCount;

  /// 本次是否**额外**成功把原生会话写进了 WebView Cookie jar（观测位）。
  ///
  /// 为什么需要这个字段（P1 兜底加固）：方案 C（ticket）与方案 B（Cookie）不是
  /// 二选一，而是「主路径 + 兜底」的关系。ticket 签发成功只说明**票据拿到了**，
  /// 但页面能否真的登进去还取决于 Web 前端是否把 `#ticket=` 兑换成会话。
  /// 若兑换环节断链（前端未接线 / fragment 被冲掉），只带 ticket 的结果会让
  /// 端侧误以为「已就绪」，页面 `/auth/me` 却 401 —— 用户看到的就是 Web 登录页，
  /// 即「两轮登录」。
  ///
  /// 因此 ticket 成功后**仍会 best-effort 注入一次 Cookie**：
  /// - 成功 → 本字段为 `true`（ticket 与 Cookie 双写，任一条生效都能免登）；
  /// - 失败 / 无 [WebViewCookieSink] → 本字段为 `false`，但**绝不影响**
  ///   [mode] 与 [failure]（ticket 依旧成功，`ready` 依旧为 true）。
  ///
  /// 方案 B 降级成功时（[WebViewAuthMode.cookie]）恒为 `true`；
  /// 失败（[WebViewAuthMode.none]）恒为 `false`。
  final bool cookieInjected;

  bool get ready => mode != WebViewAuthMode.none;

  /// 失败时可读文案（成功时为空串，绝不拼出半截提示）。
  String get failureMessage => ready ? '' : (failure ?? WebViewAuthFailure.ticketIssueFailed).message;

  @override
  String toString() =>
      'WebViewAuthResult(${mode.name}${failure == null ? '' : ', ${failure!.name}'})';
}

/// ticket 签发响应（服务端待接线）。
class WebViewTicket {
  const WebViewTicket({required this.ticket, this.expiresAt});

  factory WebViewTicket.fromJson(Map<String, dynamic> json) {
    final raw = json['ticket'];
    final exp = json['expires_at'];
    return WebViewTicket(
      ticket: raw is String ? raw : '',
      expiresAt: exp is num ? exp.toInt() : null,
    );
  }

  final String ticket;
  final int? expiresAt;

  bool get isEmpty => ticket.isEmpty;

  /// 在 [nowMs]（毫秒时间戳）时刻是否**已过期**。
  ///
  /// 为什么要这条判定（M3 根因）：服务端签发的 ticket TTL 很短（默认 120s），
  /// 从签发到 WebView 真正发起首帧加载之间可能已跨过过期点（弱网、冷启动、
  /// 锁屏期间被系统挂起）。把**过期票**塞进 URL 不会立刻报错 ——
  /// 页面能加载出来，但 ticket 兑换失败，Web UI 停在未登录态/空白，
  /// 用户看到的就是「静默白屏」。端侧必须在拼 URL 之前就判废并重签。
  ///
  /// [expiresAt] 为空视为**未知**而非已过期：服务端可能尚未下发该字段，
  /// 此时按原行为放行（不做无依据的判废），避免把可用链路误判为失效。
  bool isExpiredAt(int nowMs) => expiresAt != null && expiresAt! <= nowMs;

  /// 令牌类字段绝不进日志/文案。
  @override
  String toString() => 'WebViewTicket(expires_at=$expiresAt)';
}

/// 把 ticket 拼到入口 URL 的 fragment 上（纯函数）。
///
/// 用 fragment 而不是 query 的原因：fragment 不会进 `Referer`，
/// 也不会出现在服务端 access log 的请求行里（§4.2 硬约束）。
/// 入口 URL 自带的 fragment（hash 路由）必须保留 —— 服务端 Web UI 是 hash 路由，
/// 把 `#/` 冲掉会导致页面白屏。
String appendTicketFragment(String entryUrl, String ticket) {
  final text = entryUrl.trim();
  if (text.isEmpty || ticket.isEmpty) return text;
  final encoded = Uri.encodeComponent(ticket);
  final uri = Uri.tryParse(text);
  if (uri == null) return text;

  // 已有 fragment（例如 `#/`）：在其后追加键值，避免冲掉 hash 路由。
  final existing = uri.fragment;
  final fragment = existing.isEmpty
      ? 'ticket=$encoded'
      : '$existing&ticket=$encoded';
  return uri.replace(fragment: fragment).toString();
}

/// 从 fragment 中取回 ticket（仅用于单测与排查，生产不在端侧消费）。
String? extractTicketFragment(String url) {
  final uri = Uri.tryParse(url.trim());
  if (uri == null) return null;
  for (final pair in uri.fragment.split('&')) {
    if (pair.startsWith('ticket=')) {
      final value = pair.substring('ticket='.length);
      return value.isEmpty ? null : Uri.decodeComponent(value);
    }
  }
  return null;
}

/// WebView ticket API（方案 C 签发 + 方案 B 降级）。
class WebViewTicketApi {
  WebViewTicketApi({
    required ApiClient client,
    required SecureStore store,
    DeviceApi? deviceApi,
    this.defaultTtlSeconds = 120,
  })  : _client = client,
        _store = store,
        // 默认自建一个 DeviceApi（同一 client + store），生产调用方无需改动；
        // 测试要编排续期响应时通过 [deviceApi] 注入 fake，可测性不降级。
        _device = deviceApi ?? DeviceApi(client: client, store: store);

  final ApiClient _client;
  final SecureStore _store;

  /// 设备令牌自续会话的入口（② 段）。
  ///
  /// 为什么由本类持有而不是让调用方各调各的：续期与「重试签票」必须紧邻，
  /// 中间隔着用户操作（点重试按钮）就会把一次自动自愈变成一次手动排障。
  final DeviceApi _device;

  /// ticket 默认存活时间（秒）。短 TTL 是一次性语义的兜底。
  final int defaultTtlSeconds;

  /// 签发一次性 WebView ticket。
  ///
  /// 请求体键集合**恰为** `{device_id, ttl_s}`（服务端 DisallowUnknownFields）。
  /// 失败（端点未实现 404 / 401 / 网络异常）一律抛出，由 [prepareAuth] 降级。
  Future<WebViewTicket> issue({
    required String deviceId,
    int? ttlSeconds,
  }) =>
      _client.post<WebViewTicket>(
        '/api/v1/auth/webview-ticket',
        // ⚠️ 只有这两个键，多一个即 400
        body: <String, dynamic>{
          'device_id': deviceId,
          'ttl_s': ttlSeconds ?? defaultTtlSeconds,
        },
        parse: (Object? data) => WebViewTicket.fromJson(mapOf(data)),
      );

  /// 方案 B：把原生会话 Cookie 交给 WebView CookieManager。
  ///
  /// 真实写入由平台适配器完成（`CookieManager` 属平台插件，测试环境不可用），
  /// 因此这里抽成可注入的 [WebViewCookieSink]：
  /// - 返回值表示「已写入」；false 会让 [prepareAuth] 判定为不可用。
  /// - HttpOnly 由服务端 `Set-Cookie` 决定，端侧不伪造。
  ///
  /// ## ⚠️ 前置有效性校验（Bug 2 修复点，勿删）
  /// 「Keychain 里有非空 token」**不等于**「这枚 token 服务端还认」。旧实现只
  /// 判前者，于是过期令牌被硬塞进 `hg_sess` 还报成功：页面 `/auth/me` 拿 401
  /// → 显示登录表单 → 用户在移动端 WebView 里再登一次 → 新会话只进 Cookie、
  /// 不认 Keychain → 原生与页面两套账，「单一登录」彻底破产。
  /// 因此写入前必须 `GET /auth/me` 问一句，**认才写**；不认就不写（返回 false，
  /// 由上层 fail-closed 引导回账号页）。
  Future<bool> injectSessionCookie({
    required WebViewCookieSink sink,
    required String baseUrl,
  }) async {
    final token = await _store.getUserToken();
    if (token == null || token.isEmpty) return false;
    // 死令牌写进 Cookie jar 的后果比「不写」严重得多（见上面的注释），
    // 所以这里的顺序不可交换：先验有效，再写。
    if (!await _device.isSessionValid()) return false;
    // 服务端 Cookie 名以 `hg_sess` 为准（§4.2 草案）；未接通时 sink 返回 false。
    return sink.writeSessionCookie(
      url: baseUrl,
      name: kSessionCookieName,
      value: token,
    );
  }

  /// 统一入口：ticket（方案 C）→ 设备令牌续期后重试 → Cookie（方案 B）。
  ///
  /// 三段式的**存在理由**（不是可选优化）：
  /// 用户会话默认 7 天过期（服务端 `session_ttl_h=168`），而设备令牌**无法**
  /// 通过 `/api/**` 的用户令牌中间件。第 8 天若还只走「ticket → Cookie」两段式，
  /// 两条路都会因为「没有有效用户会话」而失败，用户被彻底关在门外 ——
  /// 这正是本次要修的致命 bug。设备令牌是长期凭据且**不会过期**（只有吊销），
  /// 拿它换一份新会话是唯一正解。
  ///
  /// ```
  /// ① 签发 ticket（含过期重签预算 maxTicketRenewAttempts）
  ///    ├ 成功 → mode=ticket + **best-effort 补写 Cookie**（失败不降级）
  ///    └ 失败 → ②
  /// ② 用 device_token 换新 user_token（预算 maxSessionRenewAttempts）→ 重试 ①
  ///    ├ 成功 → mode=ticket + **best-effort 补写 Cookie**（用户完全无感）
  ///    └ 失败（owner unknown / 已吊销 / 网络）→ ③
  /// ③ Cookie 降级 + **前置有效性校验**
  ///    ├ 有效 → mode=cookie
  ///    └ 无效 → mode=none + 可解释 failure
  /// ```
  ///
  /// 两条路径都不可用时返回 [WebViewAuthMode.none]，调用方应退回原生登录，
  /// **不得**在 WebView 内弹登录表单（§6.1 决策 2 连带约束）。
  ///
  /// M3 加固（消除静默白屏）：
  /// 1. 签发出**已过期**的 ticket 时**不拼进 URL**，而是立刻重签（最多
  ///    [maxTicketRenewAttempts] 次）。过期票塞进 URL 不会报错，只会让页面
  ///    悄悄停在未登录态 —— 那就是白屏的成因。
  /// 2. 重签预算耗尽仍拿不到可用票 → 先尝试续期、再尝试 Cookie 降级；
  ///    降级也不可用时返回 **带 [WebViewAuthFailure] 的 none**，
  ///    调用方据此展示「可读文案 + 重试按钮」，而不是空白页。
  /// 3. [nowMsProvider] 可注入，让「已过期」在测试里可复现（不依赖真实时钟）。
  ///
  /// **fail-closed 铁律**：任何返回 [WebViewAuthMode.none] 的路径都不得让调用方
  /// 拿去当裸地址用；url 只作为失败信息载体（与历史行为一致）。
  ///
  /// P1 兜底加固（2026-11）：ticket 成功后**不再直接 return**，而是在返回前
  /// best-effort 补写一次 Cookie（见 [_withBestEffortCookie]）。这条补写只写
  /// [WebViewAuthResult.cookieInjected] 一个观测位，**不改变** mode / failure /
  /// url，因此 fail-closed 铁律不受影响 —— 它的价值在于：当 Web 前端的
  /// `#ticket=` 兑换环节断链时（两轮登录的成因），Cookie jar 里已有 `hg_sess`
  /// 可以兜住首帧。旧实现 ticket 一成功就 return，方案 B 沦为死代码。
  Future<WebViewAuthResult> prepareAuth({
    required String baseUrl,
    required String entryUrl,
    String? deviceId,
    WebViewCookieSink? cookieSink,
    int Function()? nowMsProvider,
  }) async {
    final id = deviceId ?? '';
    final nowMs = nowMsProvider ?? _defaultNowMs;
    var ticketRenewCount = 0;
    var sessionRenewCount = 0;
    WebViewAuthFailure? failure;

    if (id.isEmpty) {
      failure = WebViewAuthFailure.noDeviceId;
    } else {
      // ── ① ticket（现有逻辑，含过期重签预算）──
      final first = await _acquireTicket(
        deviceId: id,
        entryUrl: entryUrl,
        nowMs: nowMs,
        extraRenewBudget: maxTicketRenewAttempts,
      );
      ticketRenewCount += first.renewCount;
      if (first.result != null) {
        // ✅ 主路径成功，但**不急着 return**：先 best-effort 补一次 Cookie。
        // 原因见 [WebViewAuthResult.cookieInjected] —— ticket 只是半程，
        // 兑换环节断链时 Cookie 是唯一能让首帧免登的兜底；
        // 旧实现这里直接 return，导致方案 B 变成永远不可达的死代码。
        // ⚠️ 该补写**绝不影响** mode/failure：注入失败仍是 mode=ticket。
        final withCookie = await _withBestEffortCookie(
          _recount(first.result!, ticketRenewCount, sessionRenewCount),
          cookieSink,
          baseUrl,
        );
        return withCookie;
      }
      failure = first.failure ?? WebViewAuthFailure.ticketIssueFailed;

      // ── ② 设备令牌续期 → 重试一次 ① ──
      //
      // 用 while 而不是 for 的自增子句：下面每个分支都以 break/return 收尾
      // （续期只有一次机会，成功就重签票、失败就没别的路可走），
      // for 的 `attempt++` 会变成永不可达的死代码。
      var sessionAttempt = 0;
      while (sessionAttempt < maxSessionRenewAttempts) {
        sessionAttempt++;
        final DeviceSessionOutcome outcome;
        try {
          outcome = await _device.renewSession();
        } on Object {
          // 续期自身炸了（不该发生，renewSession 内部已全兜）：
          // 保留票据根因，不让一个次生异常覆盖真正的失败点。
          break;
        }
        if (outcome.isRejected) {
          // 401（已吊销）/ 403（owner_unknown）：确定性结论，重试无意义。
          failure = WebViewAuthFailure.deviceSessionFailed;
          break;
        }
        if (!outcome.renewed) {
          // 未配对 / 端点未实现 / 网络异常：**无法判定**。保留票据根因，
          // 不吓唬用户去重新配对（他可能只是地铁里没信号）。
          break;
        }
        sessionRenewCount++;
        final retried = await _acquireTicket(
          deviceId: id,
          entryUrl: entryUrl,
          nowMs: nowMs,
          extraRenewBudget: maxTicketRenewAttempts,
        );
        ticketRenewCount += retried.renewCount;
        if (retried.result != null) {
          // 与 ① 首发成功同款兜底：续期后重签成功同样只是「拿到票」，
          // 仍要 best-effort 补一次 Cookie，语义与首发路径完全一致。
          final withCookie = await _withBestEffortCookie(
            _recount(retried.result!, ticketRenewCount, sessionRenewCount),
            cookieSink,
            baseUrl,
          );
          return withCookie;
        }
        // 半成功：会话换到了，但票还是签不出来（端点 404 / 服务端异常）。
        // 文案必须指向「重试」而不是「重新登录」—— 重登修不好 404 的端点。
        failure = WebViewAuthFailure.renewedButTicketFailed;
        break;
      }
    }

    // ── ③ Cookie 降级（注入前强制校验有效性）──
    if (cookieSink != null) {
      final ok = await injectSessionCookie(sink: cookieSink, baseUrl: baseUrl);
      if (ok) {
        return WebViewAuthResult(
          mode: WebViewAuthMode.cookie,
          url: entryUrl,
          ticketRenewCount: ticketRenewCount,
          sessionRenewCount: sessionRenewCount,
          // 降级路径的唯一成功条件就是「Cookie 已经写进去了」。
          cookieInjected: true,
        );
      }
      // 只在**尚无原因**时才写入 cookieUnavailable：票据过期 / 签发失败 /
      // 设备绑定失效才是根因，Cookie 只是备用路径；用备用路径的失败覆盖根因
      // 会让用户看到「Cookie 写不进去」这种他根本无法自救的提示。
      failure ??= WebViewAuthFailure.cookieUnavailable;
    }

    return WebViewAuthResult(
      mode: WebViewAuthMode.none,
      url: entryUrl,
      failure: failure ?? WebViewAuthFailure.ticketIssueFailed,
      ticketRenewCount: ticketRenewCount,
      sessionRenewCount: sessionRenewCount,
      // 失败路径必然没有写入任何 Cookie（fail-closed 铁律）。
      cookieInjected: false,
    );
  }

  /// ticket 成功后的**best-effort** Cookie 补写（P1 兜底加固的唯一入口）。
  ///
  /// ## 为什么需要它
  /// 「两轮登录」的根因之一是端侧把 ticket 签发成功当成整体成功：
  /// ticket 只被拼进 URL fragment，**兑换由 Web 前端完成**。一旦兑换环节断链
  /// （前端未接线 / fragment 被冲掉 / 90s TTL 已过），页面 `/auth/me` 仍是 401，
  /// 用户就在 WebView 里再登一次 —— 而桌面端恰恰是靠方案 B（写入 `hg_sess`）
  /// 才通的。若 ticket 一成功就 return，方案 B 就成了永远走不到的死代码。
  ///
  /// ## 契约（不可越界的边界）
  /// - 这只是**兜底**，不是第二条主路径：返回值的 [WebViewAuthResult.mode] /
  ///   [WebViewAuthResult.failure] / [WebViewAuthResult.url] 一律以 [base] 为准，
  ///   仅 [WebViewAuthResult.cookieInjected] 可能被翻成 `true`。
  /// - [sink] 为空（WebViewPage 未装配 Cookie 端口）→ 原样返回，不抛异常。
  /// - 注入抛异常 / 返回 false → 原样返回 [base]：**绝不**让兜底的失败覆盖
  ///   ticket 成功的根因文案，也绝不把 `ready` 降级。
  /// - 红线 R3：失败只吞掉，不打印任何令牌 / ticket 内容。
  Future<WebViewAuthResult> _withBestEffortCookie(
    WebViewAuthResult base,
    WebViewCookieSink? sink,
    String baseUrl,
  ) async {
    if (sink == null) return base;
    try {
      final ok = await injectSessionCookie(sink: sink, baseUrl: baseUrl);
      return ok ? _copyWithCookieInjected(base, true) : base;
    } on Object {
      // 兜底失败必须完全静默：主路径（ticket）已经成功，这里任何异常
      // 都不该让用户看到一条与票据无关的错误。
      return base;
    }
  }

  /// 复制结果并只替换 [WebViewAuthResult.cookieInjected]（其余字段原样保留）。
  ///
  /// 用复制而不是改 `_recount` 的语义：`_recount` 负责**计数累加**，
  /// 两者职责不同，混在一处会让重试路径同时背两件事。
  WebViewAuthResult _copyWithCookieInjected(
    WebViewAuthResult base,
    bool cookieInjected,
  ) =>
      WebViewAuthResult(
        mode: base.mode,
        url: base.url,
        expiresAt: base.expiresAt,
        failure: base.failure,
        ticketRenewCount: base.ticketRenewCount,
        sessionRenewCount: base.sessionRenewCount,
        cookieInjected: cookieInjected,
      );

  /// 单段 ① 的执行体：签发 ticket，过期则按 [extraRenewBudget] 重签。
  ///
  /// 抽成独立方法（而不是塞进 [prepareAuth] 的循环）是因为第二段续期成功后
  /// 需要**原样重跑一遍**这段逻辑；复制一份等于留两条并行 code path。
  Future<_TicketAttempt> _acquireTicket({
    required String deviceId,
    required String entryUrl,
    required int Function() nowMs,
    required int extraRenewBudget,
  }) async {
    var renewCount = 0;
    var sawExpired = false;
    WebViewAuthFailure? failure;

    // 1 + extraRenewBudget：首发一次，随后在「过期/空票」时重签。
    for (var attempt = 0; attempt <= extraRenewBudget; attempt++) {
      final WebViewTicket ticket;
      try {
        ticket = await issue(deviceId: deviceId);
      } on Object {
        // 端点未接线（404）/ 401 / 网络异常 → 记录原因后交给上层决定下一步。
        failure = WebViewAuthFailure.ticketIssueFailed;
        break;
      }
      if (ticket.isEmpty) {
        failure = WebViewAuthFailure.ticketIssueFailed;
        break;
      }
      if (ticket.isExpiredAt(nowMs())) {
        // 关键分支：**绝不**把过期票拼进 URL（否则就是静默白屏）。
        sawExpired = true;
        failure = WebViewAuthFailure.ticketExpired;
        if (attempt < extraRenewBudget) renewCount++;
        continue; // 进入下一轮重签
      }
      return _TicketAttempt(
        result: WebViewAuthResult(
          mode: WebViewAuthMode.ticket,
          url: appendTicketFragment(entryUrl, ticket.ticket),
          expiresAt: ticket.expiresAt,
          ticketRenewCount: renewCount,
          // 本层不知道 Cookie 端口（sink 由 prepareAuth 持有），
          // 是否补写 Cookie 一律留到 prepareAuth 的 best-effort 环节决定。
          cookieInjected: false,
        ),
        renewCount: renewCount,
      );
    }
    if (sawExpired) failure = WebViewAuthFailure.ticketExpired;
    return _TicketAttempt(
      failure: failure ?? WebViewAuthFailure.ticketIssueFailed,
      renewCount: renewCount,
    );
  }

  /// 为拿到可用 ticket 允许的额外重签次数（首发之外）。
  ///
  /// 取 1 而不是无限重试：过期通常意味着「签发 → 加载」跨了 TTL，
  /// 再签一次就够；连续过期说明服务端时钟 / TTL 配置已经坏了，
  /// 无限重试只会变成请求风暴并把用户按在加载态。
  final int maxTicketRenewAttempts = 1;

  /// 为拿到新会话允许的设备令牌续期次数（ticket 之外）。
  ///
  /// 同样取 1：一次续期就能覆盖「用户会话过期」这个唯一场景。
  /// 连续失败说明设备绑定已被吊销 / 归属账号未知 / 服务端未实现该端点 ——
  /// 都是**确定性**结论，再试只会变成请求风暴，且把用户按在加载态。
  final int maxSessionRenewAttempts = 1;

  /// 把计数补进结果（重试路径复用同一个结果对象，计数需累加）。
  WebViewAuthResult _recount(
    WebViewAuthResult base,
    int ticketRenewCount,
    int sessionRenewCount,
  ) =>
      WebViewAuthResult(
        mode: base.mode,
        url: base.url,
        expiresAt: base.expiresAt,
        failure: base.failure,
        ticketRenewCount: ticketRenewCount,
        sessionRenewCount: sessionRenewCount,
        // ⚠️ 必须原样带上：否则重试路径（① 过期重签 / ② 续期后重签）
        // 会静默把「已补写 Cookie」这个观测位丢掉，退化成永远 false。
        cookieInjected: base.cookieInjected,
      );
}

/// 单段 ticket 尝试的内部结果（不外露）。
class _TicketAttempt {
  const _TicketAttempt({this.result, this.failure, this.renewCount = 0});

  /// 成功时非空（可直接返回给调用方）。
  final WebViewAuthResult? result;

  /// 失败原因（成功时为空）。
  final WebViewAuthFailure? failure;

  /// 本段内发生的重签次数（观测用）。
  final int renewCount;
}

/// 默认时钟（毫秒时间戳）。抽成函数便于测试注入 fake 时钟。
int _defaultNowMs() => DateTime.now().millisecondsSinceEpoch;

/// 服务端会话 Cookie 名（§4.2 草案；与服务端 `Set-Cookie` 对齐）。
const String kSessionCookieName = 'hg_sess';

/// WebView Cookie 写入端口（平台插件适配，测试可注入假实现）。
abstract class WebViewCookieSink {
  /// 把 [name]=[value] 写入 [url] 作用域的 Cookie jar。
  Future<bool> writeSessionCookie({
    required String url,
    required String name,
    required String value,
  });

  /// 清空会话 Cookie（登出 / 解绑时双向清理，§8 风险 4）。
  Future<void> clearSessionCookies();
}