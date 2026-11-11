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

// ---------------------------------------------------------------------------
// 编译期注入（调试提速）
// ---------------------------------------------------------------------------
//
// 为什么需要：`flutter run` 时每次都要在 App 里手填服务端地址（Windows 桌面端
// 尤其烦：窗口重建即重填一遍）。脚本侧 `--server-url` 通过 `--dart-define=BASE_URL=...`
// 传进来，启动即生效。
//
// ⚠️ 未注入时 `kInjectedBaseUrl` 是空串，[resolveStartupBaseUrl] 会原样回落到本地
// 存储值，行为与加这个特性之前**逐字节一致**，不影响任何既有调用方与测试。

/// 编译期注入的服务端地址（`flutter run --dart-define=BASE_URL=http://...`）。
///
/// 空串 = 未注入（正常发布包的默认形态）。
const String kInjectedBaseUrl = String.fromEnvironment('BASE_URL');

/// 解析「本次启动生效」的 baseUrl：**注入值优先于本地存储值**。
///
/// 语义边界（刻意如此）：注入值只影响运行期视图，**不写回存储**。
/// 否则用 `--server-url` 调试一次就会永久污染用户的配置，之后在设置页改了地址
/// 会「改了不生效」，排查成本极高。调试注入应当是「本次运行覆盖」。
///
/// 注入值也走 [normalizeBaseUrl] 归一化；非法注入（如 `ftp://x`、空 host）会被
/// 归一化成空串，从而自然回落到本地存储值——不会让一个坏参数把 App 卡在 setup 页。
String resolveStartupBaseUrl({
  required String saved,
  required String injected,
}) {
  final fromBuild = normalizeBaseUrl(injected);
  if (fromBuild.isNotEmpty) return fromBuild;
  return normalizeBaseUrl(saved);
}
