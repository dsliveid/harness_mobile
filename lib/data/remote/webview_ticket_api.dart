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

/// 透传结果：给调用方决定加载哪个 URL。
class WebViewAuthResult {
  const WebViewAuthResult({
    required this.mode,
    required this.url,
    this.expiresAt,
  });

  final WebViewAuthMode mode;

  /// 要加载的入口 URL（方案 C 时已带 fragment；方案 B 时是裸入口）。
  final String url;

  /// ticket 过期时刻（服务端 `expires_at`，毫秒时间戳；方案 B/none 为 null）。
  final int? expiresAt;

  bool get ready => mode != WebViewAuthMode.none;

  @override
  String toString() => 'WebViewAuthResult(${mode.name})';
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
    this.defaultTtlSeconds = 120,
  })  : _client = client,
        _store = store;

  final ApiClient _client;
  final SecureStore _store;

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
  Future<bool> injectSessionCookie({
    required WebViewCookieSink sink,
    required String baseUrl,
  }) async {
    final token = await _store.getUserToken();
    if (token == null || token.isEmpty) return false;
    // 服务端 Cookie 名以 `hg_sess` 为准（§4.2 草案）；未接通时 sink 返回 false。
    return sink.writeSessionCookie(
      url: baseUrl,
      name: kSessionCookieName,
      value: token,
    );
  }

  /// 统一入口：优先 ticket（方案 C），失败自动降级 Cookie（方案 B）。
  ///
  /// 两条路径都不可用时返回 [WebViewAuthMode.none]，调用方应退回原生登录，
  /// **不得**在 WebView 内弹登录表单（§6.1 决策 2 连带约束）。
  Future<WebViewAuthResult> prepareAuth({
    required String baseUrl,
    required String entryUrl,
    String? deviceId,
    WebViewCookieSink? cookieSink,
  }) async {
    final id = deviceId ?? '';

    if (id.isNotEmpty) {
      try {
        final ticket = await issue(deviceId: id);
        if (!ticket.isEmpty) {
          return WebViewAuthResult(
            mode: WebViewAuthMode.ticket,
            url: appendTicketFragment(entryUrl, ticket.ticket),
            expiresAt: ticket.expiresAt,
          );
        }
      } on Object {
        // 服务端未接线（404）/ 401 / 网络异常 → 静默降级到方案 B。
      }
    }

    if (cookieSink != null) {
      final ok = await injectSessionCookie(sink: cookieSink, baseUrl: baseUrl);
      if (ok) {
        return WebViewAuthResult(mode: WebViewAuthMode.cookie, url: entryUrl);
      }
    }

    return WebViewAuthResult(mode: WebViewAuthMode.none, url: entryUrl);
  }
}

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