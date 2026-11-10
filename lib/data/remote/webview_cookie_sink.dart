/// WebView Cookie 写入端口的生产实现（方案 B 降级路径，架构文档 §4.2）。
///
/// 为什么单独一个文件：
/// - [WebViewCookieSink] 是**端口**（见 `webview_ticket_api.dart`），
///   `flutter test` 的 Dart VM 里没有任何平台插件，必须可注入假实现；
/// - 真实实现依赖 `flutter_inappwebview` 的 `CookieManager`，其 `platform`
///   由 `PlatformCookieManager` 派生（Dart VM 下无插件实现，取用时抛异常），
///   因此**绝不在测试默认路径里被提前求值**。
///
/// 依赖检查：`flutter_inappwebview: ^6.1.5` 已是直接依赖，`CookieManager` /
/// `WebUri` 均由其 barrel 文件导出（迁移自 `webview_flutter` 的
/// `WebViewCookieManager` / `WebViewCookie`）。
library;

import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'webview_ticket_api.dart';

/// 调用 `CookieManager` 把会话 Cookie 写进当前 App 的 Cookie jar。
///
/// 语义约定（与 [WebViewCookieSink] 的契约一致）：
/// - 返回 `true` 仅表示「平台已接受写入」，不校验服务端是否认这个 Cookie；
/// - 任何平台异常（插件缺失 / 域非法 / WKWebView 版本限制）一律返回 `false`，
///   由 [WebViewTicketApi.prepareAuth] 判定为「方案 B 不可用」→ fail-closed；
/// - **绝不打印 Cookie 值**（红线 R3：令牌类字段不进日志）。
class PlatformWebViewCookieSink implements WebViewCookieSink {
  const PlatformWebViewCookieSink();

  @override
  Future<bool> writeSessionCookie({
    required String url,
    required String name,
    required String value,
  }) async {
    if (name.isEmpty || value.isEmpty) return false;
    final parsed = Uri.tryParse(url.trim());
    if (parsed == null || parsed.host.isEmpty) return false;
    try {
      // API 差异：`setCookie` 需要**完整 URL**（不再是 `WebViewCookie` 值对象 +
      // 独立的 domain/path 字段），且返回 `Future<bool>` 表示平台是否接受。
      // domain 仍与入口 host 一致，否则页面所在域读不到该 Cookie。
      await CookieManager.instance().setCookie(
        url: WebUri(parsed.toString()),
        name: name,
        value: value,
        domain: parsed.host,
        path: '/',
        // 原 `WebViewCookie` 不区分 scheme；这里按入口 scheme 派生，
        // 避免在 http 入口写入 secure Cookie 导致页面读不到（更严格、不会放宽）。
        isSecure: parsed.scheme.toLowerCase() == 'https',
      );
      return true;
    } on Object {
      // 平台插件不可用（Dart VM / 系统 WebView 缺失）→ 交给上层 fail-closed。
      return false;
    }
  }

  @override
  Future<void> clearSessionCookies() async {
    try {
      await CookieManager.instance().deleteAllCookies();
    } on Object {
      // 清理失败不得影响登出主流程（令牌已在 Keychain 侧清空）。
    }
  }
}
