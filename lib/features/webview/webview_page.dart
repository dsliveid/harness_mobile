/// WebView 全功能视图（服务端 `//go:embed web/dist` 的同一套 Web UI，内嵌进 App）。
///
/// 为什么要它：移动端只做「遥控器 + 轻执行」的高频路径，长尾功能（工作区浏览、
/// 详细配置、账号资料等）在 Web UI 里已经全量存在，内嵌复用即可，不必在端侧重写。
///
/// 三条工程红线：
/// 1. **不注入令牌**（R3）：页面只拿到 `window.harnessMobile` 能力对象，
///    凭据仍留在 Keychain，注入内容见 [buildBridgeScript]。
/// 2. **绝不白屏**（版本协商）：加载失败 / HTTP 4xx-5xx / 平台视图不可用，
///    都退化成可读错误 + 「重试」+「检查服务端地址」，而不是一片空白。
/// 3. **单向深链**：页面要唤起原生时只能跳 `harness://`，原生拦截并交给
///    [parseDeepLink] 白名单解析，原生→页面不存在反向通道。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../core/app/app_session.dart';
import '../../core/app/providers.dart';
import '../shared/ui_helpers.dart';
import '../shared/web_entry.dart';
import 'js_bridge.dart';

/// 内置浏览器抽象（**可注入**）。
///
/// 存在理由：`webview_flutter` 在 `flutter test` 的 Dart VM 环境下无法创建
/// 平台视图（会抛 MissingPluginException）。把「造视图 + 控制」抽成接口后，
/// 页面逻辑（空态 / 错误态 / 深链拦截 / 桥注入）都能在纯 Dart 环境断言。
abstract class WebViewFactory {
  MobileWebView create({
    required Uri initialUrl,
    required String bridgeScript,
    required void Function(Uri url) onPageStarted,
    required void Function(Uri url) onPageFinished,
    required void Function(String message) onLoadFailed,
    required bool Function(Uri url) onNavigationRequest,
  });
}

/// 单个内置浏览器实例。
abstract class MobileWebView {
  Widget build(BuildContext context);

  Future<void> reload();

  Future<bool> canGoBack();

  Future<void> goBack();

  void dispose();
}

/// 生产实现（真机 / 模拟器）。
WebViewFactory defaultWebViewFactory() => const PlatformWebViewFactory();

class PlatformWebViewFactory implements WebViewFactory {
  const PlatformWebViewFactory();

  @override
  MobileWebView create({
    required Uri initialUrl,
    required String bridgeScript,
    required void Function(Uri url) onPageStarted,
    required void Function(Uri url) onPageFinished,
    required void Function(String message) onLoadFailed,
    required bool Function(Uri url) onNavigationRequest,
  }) =>
      _PlatformWebView(
        initialUrl: initialUrl,
        bridgeScript: bridgeScript,
        onPageStarted: onPageStarted,
        onPageFinished: onPageFinished,
        onLoadFailed: onLoadFailed,
        onNavigationRequest: onNavigationRequest,
      );
}

class _PlatformWebView implements MobileWebView {
  _PlatformWebView({
    required Uri initialUrl,
    required String bridgeScript,
    required void Function(Uri url) onPageStarted,
    required void Function(Uri url) onPageFinished,
    required void Function(String message) onLoadFailed,
    required bool Function(Uri url) onNavigationRequest,
  }) {
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFFFFFFFF))
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (String url) => onPageStarted(Uri.parse(url)),
          onPageFinished: (String url) async {
            // 页面就绪后才注入桥：过早注入会被后续文档加载冲掉。
            try {
              await _controller.runJavaScript(bridgeScript);
            } catch (_) {
              // 注入失败不影响页面可用性（只是页面拿不到 openDeepLink）
            }
            onPageFinished(Uri.parse(url));
          },
          onWebResourceError: (WebResourceError error) {
            // 子资源（favicon / 图片）失败不当作整页失败，避免误报错误页。
            if (error.isForMainFrame == false) return;
            onLoadFailed(
              '页面加载失败：${error.description}'
              '${error.errorCode == 0 ? '' : '（错误码 ${error.errorCode}）'}',
            );
          },
          onHttpError: (HttpResponseError error) {
            final code = error.response?.statusCode;
            if (code == null) return;
            if (code < 400) return;
            onLoadFailed('服务端返回 $code，内置页面暂时不可用');
          },
          onNavigationRequest: (NavigationRequest request) {
            final uri = Uri.tryParse(request.url);
            if (uri == null) return NavigationDecision.prevent;
            return onNavigationRequest(uri)
                ? NavigationDecision.navigate
                : NavigationDecision.prevent;
          },
        ),
      )
      ..loadRequest(initialUrl);
  }

  late final WebViewController _controller;

  @override
  Widget build(BuildContext context) => WebViewWidget(controller: _controller);

  @override
  Future<void> reload() => _controller.reload();

  @override
  Future<bool> canGoBack() => _controller.canGoBack();

  @override
  Future<void> goBack() => _controller.goBack();

  @override
  void dispose() {
    // webview_flutter 无显式 dispose；平台视图随 widget 卸载回收。
  }
}

/// 全功能视图页。
class WebViewPage extends ConsumerStatefulWidget {
  const WebViewPage({
    super.key,
    this.webViewFactory,
    this.appVersion = '0.1.0',
    this.onDeepLink,
  });

  /// 测试注入点；为空时使用 [defaultWebViewFactory]。
  final WebViewFactory? webViewFactory;

  /// 版本协商上报给页面（`window.harnessMobile.version`）。
  final String appVersion;

  /// 深链处理钩子；为空时走内置默认行为（会话直接跳原生页）。
  final void Function(DeepLinkIntent intent)? onDeepLink;

  @override
  ConsumerState<WebViewPage> createState() => _WebViewPageState();
}

class _WebViewPageState extends ConsumerState<WebViewPage> {
  MobileWebView? _webView;

  /// 已为其创建过实例的 baseUrl（防 build 期重复创建）。
  String? _createdFor;

  String? _error;
  bool _loading = true;

  @override
  void dispose() {
    _webView?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final baseUrl = ref.watch(appSessionProvider).baseUrl;

    if (baseUrl.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text('全功能视图'), actions: _actions(null)),
        body: const EmptyBody(
          icon: Icons.language_outlined,
          title: '请先配置服务端地址',
          hint: '内置全功能视图直接加载服务端 Web UI，需要先填写服务端地址并完成配对。',
        ),
      );
    }

    _ensureWebView(baseUrl);

    final view = _webView;
    return Scaffold(
      appBar: AppBar(
        title: const Text('全功能视图'),
        actions: _actions(view),
      ),
      body: Column(
        children: <Widget>[
          if (_loading && _error == null)
            const LinearProgressIndicator(minHeight: 2),
          Expanded(child: _buildBody(theme, view)),
        ],
      ),
    );
  }

  List<Widget> _actions(MobileWebView? view) => <Widget>[
        IconButton(
          tooltip: '后退',
          onPressed: view == null ? null : () => _goBack(view),
          icon: const Icon(Icons.arrow_back),
        ),
        IconButton(
          tooltip: '刷新',
          onPressed: view == null ? null : () => _reload(view),
          icon: const Icon(Icons.refresh),
        ),
        IconButton(
          tooltip: '检查服务端地址',
          onPressed: () => context.push(AppRoutes.setup),
          icon: const Icon(Icons.settings_outlined),
        ),
      ];

  Widget _buildBody(ThemeData theme, MobileWebView? view) {
    if (_error != null) {
      return _ErrorState(
        message: _error!,
        onRetry: () => _reload(view ?? _webView),
        onOpenSetup: () => context.push(AppRoutes.setup),
      );
    }
    if (view == null) {
      return const LoadingBody(message: '正在准备内置页面…');
    }
    return view.build(context);
  }

  void _ensureWebView(String baseUrl) {
    if (_createdFor == baseUrl) return;
    _createdFor = baseUrl;
    // 平台视图创建必须在帧后执行：create() 可能同步回调 onPageStarted，
    // 在 build 期间 setState 会直接报错。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _createdFor != baseUrl) return;
      _createWebView(baseUrl);
    });
  }

  void _createWebView(String baseUrl) {
    final factory = widget.webViewFactory ?? defaultWebViewFactory();
    try {
      _webView?.dispose();
      final created = factory.create(
        initialUrl: webEntryUri(baseUrl) ?? Uri.parse('$baseUrl/'),
        bridgeScript: buildBridgeScript(appVersion: widget.appVersion),
        onPageStarted: (_) {
          if (!mounted) return;
          setState(() => _loading = true);
        },
        onPageFinished: (_) {
          if (!mounted) return;
          setState(() {
            _loading = false;
            _error = null;
          });
        },
        onLoadFailed: (String message) {
          if (!mounted) return;
          setState(() {
            _loading = false;
            _error = message;
          });
        },
        onNavigationRequest: _handleNavigation,
      );
      setState(() {
        _webView = created;
        _loading = true;
        _error = null;
      });
    } catch (error) {
      // 平台视图不可创建（测试环境 / 系统 WebView 缺失）→ 不留白屏。
      setState(() {
        _webView = null;
        _loading = false;
        _error = '当前设备无法创建内置浏览器：${friendlyError(error)}';
      });
    }
  }

  /// 返回 false 表示拦截该导航（不加载）。
  bool _handleNavigation(Uri uri) {
    if (uri.scheme != kDeepLinkScheme) return true;

    final intent = parseDeepLink(uri.toString());
    if (intent == null) {
      _toast('无法识别的页面意图，已忽略');
      return false;
    }
    _dispatchDeepLink(intent);
    return false;
  }

  void _dispatchDeepLink(DeepLinkIntent intent) {
    final handler = widget.onDeepLink;
    if (handler != null) {
      handler(intent);
      return;
    }
    switch (intent.kind) {
      case DeepLinkKind.session:
        context.push(AppRoutes.sessionMessages(intent.id));
      case DeepLinkKind.approval:
        // 审批详情没有独立路由（首屏即审批中心），提示用户回列表定位。
        _toast('已定位审批项：${intent.id}，请在审批中心查看');
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Future<void> _reload(MobileWebView? view) async {
    if (view == null) {
      final baseUrl = ref.read(appSessionProvider).baseUrl;
      if (baseUrl.isEmpty) return;
      setState(() {
        _createdFor = null;
        _error = null;
        _loading = true;
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await view.reload();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '重新加载失败：${friendlyError(error)}';
      });
    }
  }

  Future<void> _goBack(MobileWebView view) async {
    try {
      if (await view.canGoBack()) {
        await view.goBack();
        return;
      }
    } catch (_) {
      // 落到下面的兜底
    }
    if (!mounted) return;
    final navigator = Navigator.of(context);
    if (navigator.canPop()) navigator.pop();
  }
}

/// 加载失败态：可读文案 + 重试 + 地址入口（**绝不白屏**）。
class _ErrorState extends StatelessWidget {
  const _ErrorState({
    required this.message,
    required this.onRetry,
    required this.onOpenSetup,
  });

  final String message;
  final VoidCallback onRetry;
  final VoidCallback onOpenSetup;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Icon(
              Icons.cloud_off_outlined,
              size: 48,
              color: theme.colorScheme.error,
            ),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 6),
            Text(
              '可能是服务端未启动、地址填错，或该服务端版本未内置 Web 界面。',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.outline),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 12,
              children: <Widget>[
                FilledButton.icon(
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh),
                  label: const Text('重试'),
                ),
                OutlinedButton.icon(
                  onPressed: onOpenSetup,
                  icon: const Icon(Icons.settings_outlined),
                  label: const Text('检查服务端地址'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 供 `app.dart` 集成时统一取版本号（未接入 package_info 前的唯一来源）。
const String kMobileAppVersion = String.fromEnvironment(
  'APP_VERSION',
  defaultValue: '0.1.0',
);

