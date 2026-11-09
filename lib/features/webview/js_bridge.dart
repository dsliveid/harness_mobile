/// 最小 JS 桥（红线 R3/R9：**绝不把令牌注入 WebView**）。
///
/// 设计铁律：
/// 1. 只允许 **WebView → 原生** 单向传递「意图」，且只走 `harness://` 深链
///    （页面把 `window.location.href` 指向深链 → 原生拦截导航请求）。
///    原生 → 页面**只**注入一个能力声明对象，不含任何凭据。
/// 2. 注入到页面的对象是
///    `window.harnessMobile = { installed, version, capabilities, openDeepLink }`。
///    `device_token` / `user_token` 永远留在 Dart 层（Keychain），页面拿不到、抄不走。
/// 3. 本文件的两个构造函数都是**纯函数**，便于单测直接断言脚本文本，
///    无需真正创建平台视图。
///
/// 批次 C 变化（架构文档 §4.3）：
/// - 新增 `capabilities` 能力声明（审批只读 / 禁止建项目 / 允许传图 / 不执行命令）；
/// - 深链白名单去掉 `approval`（审批中心已删除），新增 `reauth`；
/// - **不提供任何登录入口**（§6.1 决策 2：登录只在原生）。
library;

/// 深链意图类型（白名单，未知类型一律拒绝）。
enum DeepLinkKind {
  /// `harness://session/<会话 id>` → WebView 直达该会话（推送点开用）。
  session,

  /// `harness://reauth` → Cookie 失效时请求原生重签 ticket / 重新解锁。
  reauth,
}

/// 解析出的结构化意图。
class DeepLinkIntent {
  const DeepLinkIntent({
    required this.kind,
    required this.id,
    required this.rawUrl,
  });

  final DeepLinkKind kind;

  /// 目标对象 id（会话 id）；[DeepLinkKind.reauth] 时为空串。
  final String id;

  /// 原始 URL（仅用于日志排查，不含敏感信息）。
  final String rawUrl;

  @override
  String toString() => 'DeepLinkIntent(${kind.name}, id=$id)';
}

/// 深链 scheme（与页面约定一致）。
const String kDeepLinkScheme = 'harness';

/// 移动端能力声明（与原生化能力保持一致，§4.3）。
///
/// ⚠️ **这不是安全边界**（可被绕过），仅用于 Web UI 体验降级；
/// 真正的强制在服务端（协议 §5.3）。
const Map<String, bool> kMobileCapabilities = <String, bool>{
  'approvalDecide': false,
  'createProject': false,
  'fileUpload': true,
  'exec': false,
};

/// 构造注入页面的桥脚本。
///
/// 注意：本函数**不允许**出现任何凭据字段（`device_token` / `user_token` 等）。
/// 单测 `webview_test.dart` 会对产出文本做否定断言，改动前请先看测试。
String buildBridgeScript({
  required String appVersion,
  Map<String, bool> capabilities = kMobileCapabilities,
}) {
  final version = _escapeJsString(appVersion);
  final caps = capabilities.entries
      .map((MapEntry<String, bool> e) =>
          '      ${_jsKey(e.key)}: ${e.value ? 'true' : 'false'}')
      .join(',\n');
  return '''
(function () {
  if (window.harnessMobile && window.harnessMobile.installed) { return; }
  var scheme = '$kDeepLinkScheme://';
  window.harnessMobile = {
    installed: true,
    version: '$version',
    capabilities: {
$caps
    },
    openDeepLink: function (intent) {
      if (typeof intent !== 'string') { return false; }
      if (intent.indexOf(scheme) !== 0) { return false; }
      window.location.href = intent;
      return true;
    }
  };
})();
''';
}

/// 解析页面下发的深链。
///
/// 只接受两种形态：
/// - `harness://session/<id>`
/// - `harness://reauth`
///
/// 其余（含 `https://`、`harness://approval/...`、未知类型、session 缺 id）
/// 一律返回 null —— 白名单机制，避免页面用任意 URL 诱导端侧行为。
DeepLinkIntent? parseDeepLink(String url) {
  final text = url.trim();
  if (text.isEmpty) return null;

  final uri = Uri.tryParse(text);
  if (uri == null) return null;
  if (uri.scheme.toLowerCase() != kDeepLinkScheme) return null;

  // 必须写成 `harness://<type>`；`harness:<type>` 这种简写不接受。
  final host = uri.host.toLowerCase();
  final DeepLinkKind kind;
  switch (host) {
    case 'session':
      kind = DeepLinkKind.session;
    case 'reauth':
      kind = DeepLinkKind.reauth;
    default:
      return null;
  }

  if (kind == DeepLinkKind.reauth) {
    return DeepLinkIntent(kind: kind, id: '', rawUrl: text);
  }

  if (uri.pathSegments.isEmpty) return null;
  final id = uri.pathSegments.first.trim();
  if (id.isEmpty) return null;

  return DeepLinkIntent(kind: kind, id: id, rawUrl: text);
}

/// JS 对象键：只允许标识符字符，其余直接丢弃（防注入）。
String _jsKey(String raw) {
  final buffer = StringBuffer();
  for (final code in raw.codeUnits) {
    final isLower = code >= 0x61 && code <= 0x7A;
    final isUpper = code >= 0x41 && code <= 0x5A;
    final isDigit = code >= 0x30 && code <= 0x39;
    if (isLower || isUpper || isDigit || code == 0x5F) {
      buffer.writeCharCode(code);
    }
  }
  return buffer.isEmpty ? '_' : buffer.toString();
}

/// JS 单引号字符串转义（版本号来自构建期常量，仍需防注入）。
String _escapeJsString(String raw) {
  final buffer = StringBuffer();
  for (final code in raw.codeUnits) {
    if (code == 0x5C) {
      buffer.write(r'\\');
    } else if (code == 0x27) {
      buffer.write(r"\'");
    } else if (code == 0x0A) {
      buffer.write(r'\n');
    } else if (code == 0x0D) {
      buffer.write(r'\r');
    } else {
      buffer.writeCharCode(code);
    }
  }
  return buffer.toString();
}