/// Web 端入口地址构造（纯函数，便于单测）。
///
/// 为什么需要它：`normalizeBaseUrl` 内部用 `uri.replace(query: '', fragment: '')`
/// 归一化地址，结果会保留**空的** `?#` 尾巴（`http://host:8080` → `http://host:8080?#`）。
/// 直接字符串拼 `/` 会得到 `http://host:8080?#/` —— 路径落进 fragment，
/// 浏览器/WebView 会把它当片段而不是路径，页面会错加载。
/// 因此统一在这里重建 URI，显式丢弃 query 与 fragment。
library;

/// baseUrl → 要打开的 Web 根地址（结尾带 `/`，无 query / fragment）。
///
/// 非法或空地址返回空串，调用方据此展示「未配置」提示。
String webEntryUrl(String baseUrl) {
  final uri = webEntryUri(baseUrl);
  return uri == null ? '' : uri.toString();
}

/// baseUrl → 要加载的 URI；非法或空地址返回 null。
Uri? webEntryUri(String baseUrl) {
  final text = baseUrl.trim();
  if (text.isEmpty) return null;

  final parsed = Uri.tryParse(text);
  if (parsed == null) return null;
  if (parsed.scheme != 'http' && parsed.scheme != 'https') return null;
  if (parsed.host.isEmpty) return null;

  var path = parsed.path;
  if (path.isEmpty) {
    path = '/';
  } else if (!path.endsWith('/')) {
    path = '$path/';
  }

  return Uri(
    scheme: parsed.scheme,
    host: parsed.host,
    port: parsed.hasPort ? parsed.port : null,
    path: path,
  );
}
