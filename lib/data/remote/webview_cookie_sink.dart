/// WebView Cookie 写入端口的生产实现（方案 B 降级路径，架构文档 §4.2）。
///
/// 为什么单独一个文件：
/// - [WebViewCookieSink] 是**端口**（见 `webview_ticket_api.dart`），
///   `flutter test` 的 Dart VM 里没有任何平台插件，必须可注入假实现；
/// - 真实实现依赖 `webview_flutter` 的 `WebViewCookieManager`，其构造会
///   访问 `WebViewPlatform.instance`（Dart VM 下为 null 会抛断言），
///   因此**只允许在真机 / 模拟器路径**被实例化，绝不在测试默认路径里被提前求值。
///
/// 依赖检查（未新增任何 pubspec 依赖）：`webview_flutter: ^4.9.0` 已是直接依赖，
/// `WebViewCookieManager` / `WebViewCookie` 均由其导出。
library;

import 'package:webview_flutter/webview_flutter.dart';

import 'webview_ticket_api.dart';

/// 调用 `WebViewCookieManager` 把会话 Cookie 写进当前 App 的 Cookie jar。
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
      await WebViewCookieManager().setCookie(
        WebViewCookie(
          name: name,
          value: value,
          // domain 必须与入口 host 一致，否则页面所在域读不到该 Cookie。
          domain: parsed.host,
          path: '/',
        ),
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
      await WebViewCookieManager().clearCookies();
    } on Object {
      // 清理失败不得影响登出主流程（令牌已在 Keychain 侧清空）。
    }
  }
}
