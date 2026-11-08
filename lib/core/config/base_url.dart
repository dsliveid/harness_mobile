/// 服务端地址归一化（纯函数，便于单测）。
///
/// 规则（与「用户在设置页手输地址」的真实使用场景对齐）：
/// - 去掉首尾空白；空串原样返回空串
/// - 没写 scheme 时补 `http://`（局域网自建服务端最常见形态）
/// - 只接受 `http` / `https`，其它 scheme 视为非法 → 空串
/// - 去掉尾部 `/`，避免拼出 `//api/v1`
/// - 保留路径前缀（服务端可挂在子路径，如 `https://host/harness`）
/// - 丢弃 query / fragment（baseUrl 只承载定位，不承载参数）
library;

String normalizeBaseUrl(String raw) {
  final text = raw.trim();
  if (text.isEmpty) return '';

  final withScheme = text.contains('://') ? text : 'http://$text';
  final uri = Uri.tryParse(withScheme);
  if (uri == null) return '';
  if (uri.scheme != 'http' && uri.scheme != 'https') return '';
  if (uri.host.isEmpty) return '';

  var path = uri.path;
  while (path.endsWith('/')) {
    path = path.substring(0, path.length - 1);
  }

  // ⚠️ 陷阱：`uri.replace(query: '', fragment: '')` 会生成 `http://host?#`
  // 空尾巴（Dart 把空串渲染成 `?` 与 `#` 分隔符），后续 dio 拼 baseUrl
  // 会把路径落错，服务端返回纯文本 404 → 端侧报「非预期格式的错误响应」。
  // 正确做法：用 Uri() 构造器重建，显式丢弃 query/fragment。
  return Uri(
    scheme: uri.scheme,
    host: uri.host,
    port: uri.hasPort ? uri.port : null,
    path: path,
  ).toString().isEmpty
      ? ''
      : _buildBase(uri, path);
}

/// 用显式构造器拼出干净的 baseUrl（无 `?#` 尾巴），path 自动补尾斜杠由调用方保证。
String _buildBase(Uri uri, String path) {
  final rebuilt = Uri(
    scheme: uri.scheme,
    host: uri.host,
    port: uri.hasPort ? uri.port : null,
    path: path.isEmpty ? '/' : path,
  ).toString();
  return rebuilt.endsWith('/') ? rebuilt : '$rebuilt/';
}

/// baseUrl 是否可用于发起请求（非空且 scheme/host 合法）。
bool isUsableBaseUrl(String baseUrl) => normalizeBaseUrl(baseUrl).isNotEmpty;
