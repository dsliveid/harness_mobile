/// WebView 全功能视图（服务端 `//go:embed web/dist` 的同一套 Web UI，内嵌进 App）。
///
/// 为什么要它：移动端只做「遥控器 + 轻执行」的高频路径，长尾功能（工作区浏览、
/// 详细配置、账号资料等）在 Web UI 里已经全量存在，内嵌复用即可，不必在端侧重写。
///
/// 四条工程红线：
/// 1. **不注入令牌**（R3）：页面只拿到 `window.harnessMobile` 能力对象，
///    凭据仍留在 Keychain，注入内容见 [buildBridgeScript]。
/// 2. **绝不白屏**（版本协商）：加载失败 / HTTP 4xx-5xx / 平台视图不可用，
///    都退化成可读错误 + 「重试」+「检查服务端地址」，而不是一片空白。
/// 3. **单向深链**：页面要唤起原生时只能跳 `harness://`，原生拦截并交给
///    [parseDeepLink] 白名单解析，原生→页面不存在反向通道。
/// 4. **首帧必带凭据 + App 级解锁门**（批次 C-4 / C-2，本次接线）：
///    - 首帧 URL **必须**由 [WebViewTicketApi.prepareAuth] 产出（ticket 优先、
///      Cookie 降级），**绝不**用裸地址 `webEntryUri(baseUrl)` 直接放行 ——
///      服务端 Web UI 没有登录表单，裸地址进去只会卡在登录墙/白屏；
///    - 两条路径都失败时 **fail-closed**：不创建 WebView，展示错误态 + 重试 +
///      「回账号页重新登录」的下一步指引；
///    - 身份齐备（[AppStage.webview]）时先过生物识别门禁（[WebViewLock]），
///      未解锁不创建 WebView（凭据不进内存也进不了页面）。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/app/api_services.dart';
import '../../core/app/app_session.dart';
import '../../core/app/providers.dart';
import '../../core/app/webview_lock.dart';
import '../../data/remote/webview_ticket_api.dart';
import '../shared/ui_helpers.dart';
import '../shared/web_entry.dart';
import 'js_bridge.dart';

/// 内置浏览器抽象（**可注入**）。
///
/// 存在理由：`flutter_inappwebview` 在 `flutter test` 的 Dart VM 环境下无法创建
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

/// 生产实现的 [InAppWebView] 适配。
///
/// 与 `webview_flutter` 的**结构性差异**（迁移要点）：
/// - 控制器不再能在构造期 `new` 出来，只能由 widget 的 `onWebViewCreated`
///   回调交给端侧，因此 [_controller] 在首个帧渲染前恒为 `null`；
/// - 导航回调全部挂在 **widget 上**（不再有 `NavigationDelegate` 对象）；
/// - 首帧 URL 走 `initialUrlRequest`，**不**在构造期主动 `loadUrl`
///   （平台视图尚未挂载时调用会抛异常）。
class _PlatformWebView implements MobileWebView {
  _PlatformWebView({
    required Uri initialUrl,
    required String bridgeScript,
    required void Function(Uri url) onPageStarted,
    required void Function(Uri url) onPageFinished,
    required void Function(String message) onLoadFailed,
    required bool Function(Uri url) onNavigationRequest,
  })  : _initialUrlRequest = URLRequest(url: WebUri(initialUrl.toString())),
        _bridgeScript = bridgeScript,
        _onPageStarted = onPageStarted,
        _onPageFinished = onPageFinished,
        _onLoadFailed = onLoadFailed,
        _onNavigationRequest = onNavigationRequest;

  final URLRequest _initialUrlRequest;
  final String _bridgeScript;
  final void Function(Uri url) _onPageStarted;
  final void Function(Uri url) _onPageFinished;
  final void Function(String message) _onLoadFailed;
  final bool Function(Uri url) _onNavigationRequest;

  InAppWebViewController? _controller;

  /// **不变量 1：桥注入一次性标记。**
  ///
  /// `onLoadStop`（对应原 `onPageFinished`）**不是**「首次加载完成」的同义词：
  /// SPA 内部 `history.pushState` / 重定向在部分平台会让它重复触发。
  /// 没有这个标记，桥脚本会在同一次文档里被反复 `evaluateJavascript`。
  /// 复位点只有 [InAppWebView.onLoadStart]（顶层新文档开始）——
  /// 新文档必须重新拿到桥，而 SPA 内部路由不产生新文档、不触发 `onLoadStart`。
  bool _bridgeInjected = false;

  /// widget 已卸载 / 实例已被页面丢弃：此后一律不再向外回调，
  /// 避免已废弃的实例把旧状态写回页面（对应 `_generation` 语义）。
  bool _disposed = false;

  /// 设置对象**只建一次**：`InAppWebView` 每次收到新的 settings 实例都会
  /// 向平台重推一遍设置，放在 `build` 里会产生无谓的跨平台往返。
  final InAppWebViewSettings _settings = InAppWebViewSettings(
    javaScriptEnabled: true,
    // 显式打开：`shouldOverrideUrlLoading` 是深链白名单的唯一拦截点，
    // 不能依赖「传了回调就自动推断为 true」的隐式行为。
    useShouldOverrideUrlLoading: true,
    transparentBackground: false,
  );

  @override
  Widget build(BuildContext context) => InAppWebView(
        initialUrlRequest: _initialUrlRequest,
        initialSettings: _settings,
        onWebViewCreated: (InAppWebViewController controller) {
          _controller = controller;
        },
        onLoadStart: (InAppWebViewController _, WebUri? url) {
          if (_disposed) return;
          // 新文档开始 → 允许在新文档里重新注入一次桥（见 [_bridgeInjected]）。
          _bridgeInjected = false;
          if (url == null) return;
          _onPageStarted(Uri.parse(url.toString()));
        },
        onLoadStop: (InAppWebViewController controller, WebUri? url) async {
          if (_disposed) return;
          if (!_bridgeInjected) {
            // 先占位再注入：注入是异步的，期间若 onLoadStop 再次触发，
            // 不能再发一份（否则同一页面并发注入两次）。
            _bridgeInjected = true;
            // 页面就绪后才注入桥：过早注入会被后续文档加载冲掉。
            try {
              await controller.evaluateJavascript(source: _bridgeScript);
            } catch (_) {
              // **不变量 2**：注入失败只让页面拿不到 openDeepLink，
              // 绝不升级成错误页 / 白屏（页面本身已可用）。
              // 复位标记，让后续的 onLoadStop 还能补一次（桥脚本自身幂等，
              // 重复调用不会污染页面）。
              _bridgeInjected = false;
            }
            if (_disposed) return;
          }
          if (url == null) return;
          _onPageFinished(Uri.parse(url.toString()));
        },
        onReceivedError: (
          InAppWebViewController _,
          WebResourceRequest request,
          WebResourceError error,
        ) {
          if (_disposed) return;
          // **不变量 3**：子资源（favicon / 图片）失败不当作整页失败。
          // 判定与原 `webview_flutter` 实现**逐字保持等价**：只有明确的
          // `isForMainFrame == false` 才忽略；`bool?` 为 null 时按「可能整页失败」
          // 处理（宁可提示可读错误，也不静默白屏）。
          if (request.isForMainFrame == false) return;
          final type = error.type.toValue();
          _onLoadFailed(
            '页面加载失败：${error.description}'
            '${type.isEmpty ? '' : '（$type）'}',
          );
        },
        onReceivedHttpError: (
          InAppWebViewController _,
          WebResourceRequest request,
          WebResourceResponse errorResponse,
        ) {
          if (_disposed) return;
          // 同 [onReceivedError] 的「不变量 3」口径：只忽略明确的子资源错误。
          if (request.isForMainFrame == false) return;
          final code = errorResponse.statusCode;
          if (code == null) return;
          if (code < 400) return;
          _onLoadFailed('服务端返回 $code，内置页面暂时不可用');
        },
        shouldOverrideUrlLoading: (
          InAppWebViewController _,
          NavigationAction navigationAction,
        ) async {
          if (_disposed) return NavigationActionPolicy.CANCEL;
          final raw = navigationAction.request.url?.toString();
          final uri = raw == null ? null : Uri.tryParse(raw);
          if (uri == null) return NavigationActionPolicy.CANCEL;
          return _onNavigationRequest(uri)
              ? NavigationActionPolicy.ALLOW
              : NavigationActionPolicy.CANCEL;
        },
      );

  @override
  Future<void> reload() async {
    final controller = _controller;
    if (controller == null) return;
    await controller.reload();
  }

  @override
  Future<bool> canGoBack() async {
    final controller = _controller;
    if (controller == null) return false;
    return controller.canGoBack();
  }

  @override
  Future<void> goBack() async {
    final controller = _controller;
    if (controller == null) return;
    await controller.goBack();
  }

  @override
  void dispose() {
    // 平台侧 dispose 由 [InAppWebView] 的 State.dispose 统一负责
    // （它会调用 `platform.dispose()`）；这里再调一次 `controller.dispose()`
    // 会造成重复释放。只做「停止向外回调 + 断开引用」。
    _disposed = true;
    _controller = null;
  }
}

/// 全功能视图页。
class WebViewPage extends ConsumerStatefulWidget {
  const WebViewPage({
    super.key,
    this.webViewFactory,
    this.appVersion = '0.1.0',
    this.onDeepLink,
    this.onDeepLinkRejected,
  });

  /// 测试注入点；为空时使用 [defaultWebViewFactory]。
  final WebViewFactory? webViewFactory;

  /// 版本协商上报给页面（`window.harnessMobile.version`）。
  final String appVersion;

  /// 深链处理钩子；为空时走内置默认行为（会话直接跳原生页）。
  final void Function(DeepLinkIntent intent)? onDeepLink;

  /// 深链被白名单拒绝时的回调（M2：拒绝必须可观测，不许静默吞掉）。
  ///
  /// 与 [onDeepLink] 对称存在：两者覆盖 `resolveDeepLink` 的**全部**分支，
  /// 调用方（含测试）可以据此断言「每一条下发的深链都有确定性归属」。
  final void Function(DeepLinkRejection rejection)? onDeepLinkRejected;

  @override
  ConsumerState<WebViewPage> createState() => _WebViewPageState();
}

/// 首帧认证彻底失败时的用户文案（fail-closed，**绝不**裸地址放行）。
///
/// 为什么要写「回账号页重新登录」：服务端 Web UI **没有登录表单**
/// （§6.1 决策 2：登录只发生在原生），凭据拿不到时在 WebView 里无论如何
/// 都进不去，唯一正确的用户动作是回原生身份链路重新走一遍。
const String kWebViewAuthFailedMessage = '无法为内置页面获取登录凭据：'
    '一次性票据（ticket）与 Cookie 注入两条路径都不可用。';

/// 是否要把 [WebViewLock] 当作进入 WebView 的门（纯函数，便于单测）。
///
/// 设计要点（交接书任务 2 第 4 条）：
/// 只有「身份齐备且即将进入 WebView 主体」（[AppStage.webview]）时才要求生物识别。
/// 其余阶段即便本页被渲染出来（例如登出瞬间正在过渡、或测试里直接 pump 本页），
/// 也**不得**把用户锁死在门口 —— 那些阶段还没有可保护的会话，锁上去只会
/// 让用户看到一个永远点不开的解锁屏。
bool shouldGateWebView(AppStage stage) => stage == AppStage.webview;

class _WebViewPageState extends ConsumerState<WebViewPage> {
  MobileWebView? _webView;

  /// 已为其创建过实例的 baseUrl（防 build 期重复创建）。
  String? _createdFor;

  /// 认证 / 创建代次：每次「重新创建」自增。
  ///
  /// 异步化后的必备护栏：`prepareAuth` 里有网络往返，期间用户可能点重试、
  /// 切页或回前台重锁。旧请求回来时代次已变，直接丢弃结果，
  /// 避免「旧凭据覆盖新状态」或对已 unmount 的 widget 调 setState。
  int _generation = 0;

  String? _error;

  /// 当前错误是否属于「拿不到凭据」的 fail-closed 分支（决定是否提示回账号页）。
  bool _authBlocked = false;

  /// 凭据链路的**结构化失败原因**（M3）：非空时错误 UI 才能给出精准提示与
  /// 「重试票据申请」动作，而不是只丢一句笼统文案。
  WebViewAuthFailure? _authFailure;

  bool _loading = true;

  /// 解锁失败的提示（锁屏内联展示，比 SnackBar 更容易被用户看到与重试）。
  String? _lockError;

  /// 待定位的会话 id（`harness://session/<sid>` 深链暂存）。
  ///
  /// 首帧未就绪时深链可能先到，直接丢弃会让「推送点开会话」功能静默失效；
  /// 因此暂存意图，待 `onPageFinished` 后由 [_consumePendingSession] 消费。
  String? _pendingSessionId;

  @override
  void dispose() {
    _generation++;
    _webView?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final session = ref.watch(appSessionProvider);
    final baseUrl = session.baseUrl;

    // App 级解锁门（批次 C-2）：`watch` 让 UI 随锁状态变化自动重建
    // （回前台超时重锁由 WebViewLock 内部 observer 负责，这里只响应）。
    final lock = ref.watch(webViewLockProvider);
    final gated = shouldGateWebView(session.stage);

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

    // 未解锁 → 只渲染锁屏，**不创建** WebView（凭据不进内存也进不了页面）。
    if (gated && lock.isLocked) {
      // 已创建的实例若因重新加锁（回前台超时 / 手动锁定）而失去意义，
      // 立刻丢弃，避免锁定期间页面仍持有已注入的凭据。
      // 放在帧后执行：build 内不能产生副作用。
      if (_webView != null || _createdFor != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _dropWebView();
        });
      }
      return Scaffold(
        appBar: AppBar(
          title: const Text('全功能视图'),
          actions: _actions(null),
        ),
        body: _LockState(
          authenticating: lock.state == WebViewLockState.authenticating,
          error: _lockError,
          onUnlock: _unlock,
          onOpenAccount: () => context.push(AppRoutes.account),
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
        // 只有「凭据不可用」才引导回账号页重新登录：加载失败与地址错误
        // 重新登录并无意义，多给一个错误动作只会让用户更困惑。
        onOpenAccount:
            _authBlocked ? () => context.push(AppRoutes.account) : null,
        authFailure: _authFailure,
        // M3：票据类失败额外给「重试票据申请」，一键重签而不必重走全链路。
        onRetryTicket: _authBlocked && _authFailure != null
            ? () => _reload(null)
            : null,
      );
    }
    if (view == null) {
      return const LoadingBody(message: '正在准备内置页面…');
    }
    return view.build(context);
  }

  /// 请求解锁（fail-closed：拿不到结果即保持锁定）。
  ///
  /// [WebViewLock.unlock] 在闸门抛异常时会**先回滚 locked 再 rethrow**，
  /// 因此这里必须 catch 住异常并给出可读提示，否则异常会冒到 framework
  /// 变成红屏；回滚由状态机保证，UI 只需重建（watch 已订阅）。
  Future<void> _unlock() async {
    final lock = ref.read(webViewLockProvider);
    setState(() => _lockError = null);
    try {
      final ok = await lock.unlock();
      if (!mounted) return;
      if (!ok) {
        setState(() => _lockError = '身份验证未通过，请重试（不支持跳过验证）');
      }
    } on Object catch (error) {
      if (!mounted) return;
      // 状态已由状态机回滚到 locked，按钮可再次点击重试。
      setState(() => _lockError = '解锁失败：${friendlyError(error)}，请重试');
    }
  }

  /// 丢弃已创建的 WebView 并要求下次进入重新走认证。
  void _dropWebView() {
    final view = _webView;
    if (view == null && _createdFor == null) return;
    _generation++;
    _createdFor = null;
    _webView = null;
    view?.dispose();
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
      _authBlocked = false;
      _authFailure = null;
    });
  }

  void _ensureWebView(String baseUrl) {
    if (_createdFor == baseUrl) return;
    _createdFor = baseUrl;
    final generation = ++_generation;
    // 平台视图创建必须在帧后执行：create() 可能同步回调 onPageStarted，
    // 在 build 期间 setState 会直接报错；认证还有网络往返，更必须在帧后。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || generation != _generation) return;
      unawaited(_createWebView(baseUrl, generation));
    });
  }

  /// 先认证、后创建（批次 C-4 核心）。
  ///
  /// 顺序不可颠倒：`initialUrl` 必须在 `create()` 之前就带好凭据，
  /// 否则页面首帧就会打到「要求登录但没有登录表单」的墙上，用户直接卡死。
  Future<void> _createWebView(String baseUrl, int generation) async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
      _authBlocked = false;
    });

    final auth = await _prepareAuth(baseUrl);
    // 每次 await 之后都必须重新校验：widget 可能已 unmount，
    // 或代次已被「重试 / 重新加锁 / 地址变更」推进（旧结果必须丢弃）。
    if (!mounted || generation != _generation) return;

    final entry = auth.ready ? Uri.tryParse(auth.url) : null;
    if (entry == null) {
      // fail-closed：**绝不**退回 `webEntryUri(baseUrl)` 裸地址放行。
      // M3：错误文案必须**带具体原因**（票据过期 / 签发失败 / Cookie 不可用），
      // 并在前缀保留统一抬头，让用户一眼知道问题类别 + 下一步动作。
      final reason = auth.failureMessage;
      setState(() {
        _webView = null;
        _loading = false;
        _authBlocked = true;
        _error = '$kWebViewAuthFailedMessage\n原因：$reason';
        _authFailure = auth.failure;
      });
      return;
    }
    setState(() => _authFailure = null);

    final factory = widget.webViewFactory ?? defaultWebViewFactory();
    try {
      _webView?.dispose();
      final created = factory.create(
        initialUrl: entry,
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
          // 页面就绪：消费首帧前暂存的会话定位意图。
          _consumePendingSession();
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
      if (!mounted || generation != _generation) {
        created.dispose();
        return;
      }
      setState(() {
        _webView = created;
        _loading = true;
        _error = null;
        _authBlocked = false;
      });
    } catch (error) {
      if (!mounted || generation != _generation) return;
      // 平台视图不可创建（测试环境 / 系统 WebView 缺失）→ 不留白屏。
      setState(() {
        _webView = null;
        _loading = false;
        _error = '当前设备无法创建内置浏览器：${friendlyError(error)}';
      });
    }
  }

  /// 首帧认证：一次性 ticket 优先（过期自动重签），失败降级 Cookie 注入。
  ///
  /// M3 起**永不返回 null**：失败时返回 `mode == none` 且带
  /// [WebViewAuthFailure] 的结果，调用方据此展示可读文案（而不是白屏）。
  /// 返回 null 会让「失败原因」在函数边界上丢失，那正是静默白屏的成因。
  ///
  /// 注意：这里用 `ref.read` 而不是 [servicesOf]（后者内部 `watch`），
  /// 因为本方法在帧后的异步上下文里执行，`watch` 只允许在 build 中使用。
  Future<WebViewAuthResult> _prepareAuth(String baseUrl) async {
    final entry = webEntryUri(baseUrl);
    final services = _servicesFor(baseUrl);
    final sink = ref.read(webViewCookieSinkProvider);
    final deviceId = ref.read(appSessionProvider).deviceId;

    if (entry == null) {
      return const WebViewAuthResult(
        mode: WebViewAuthMode.none,
        url: '',
        failure: WebViewAuthFailure.ticketIssueFailed,
      );
    }
    if (services == null) {
      return WebViewAuthResult(
        mode: WebViewAuthMode.none,
        url: entry.toString(),
        failure: WebViewAuthFailure.ticketIssueFailed,
      );
    }

    try {
      return await services.webviewTicket.prepareAuth(
        baseUrl: baseUrl,
        entryUrl: entry.toString(),
        deviceId: deviceId,
        cookieSink: sink,
      );
    } on Object {
      // prepareAuth 内部已对 ticket / Cookie 逐级降级，这里只兜极端异常。
      // 兜底同样是 fail-closed，但**必须带原因**，否则用户又看到白屏。
      return WebViewAuthResult(
        mode: WebViewAuthMode.none,
        url: entry.toString(),
        failure: WebViewAuthFailure.ticketIssueFailed,
      );
    }
  }

  /// 取 baseUrl 绑定的 API 集合（异步上下文版，等价于 [servicesOf] 但用 read）。
  ApiServices? _servicesFor(String baseUrl) {
    if (baseUrl.isEmpty) return null;
    return ref.read(apiFactoryProvider).forBaseUrl(baseUrl);
  }

  /// 返回 false 表示拦截该导航（不加载）。
  ///
  /// M2 铁律：未知深链**必须显式拒绝并给出可见反馈**，绝不静默吞掉。
  /// 拒绝路径走 [resolveDeepLink] 拿到的 [DeepLinkDecision.rejectMessage]，
  /// 用户能看到「为什么没反应」而不是以为 App 卡死了。
  bool _handleNavigation(Uri uri) {
    if (uri.scheme != kDeepLinkScheme) return true;

    final decision = resolveDeepLink(uri.toString());
    final intent = decision.intent;
    if (intent == null) {
      _rejectDeepLink(decision, uri);
      return false;
    }
    _dispatchDeepLink(intent);
    return false;
  }

  /// 显式拒绝未知 / 非法深链：可见提示 + 可选回调 + 记录（不含敏感信息）。
  void _rejectDeepLink(DeepLinkDecision decision, Uri uri) {
    final rejection = decision.rejection ?? DeepLinkRejection.unknownHost;
    // 只记录 scheme/host（可能被构造成恶意串，不落完整 URL 到日志）。
    debugPrint('深链被拒绝 reason=${rejection.name} host=${uri.host}');
    widget.onDeepLinkRejected?.call(rejection);
    _toast(decision.rejectMessage);
  }

  /// 深链派发（批次 C：白名单只剩 `session` / `reauth` 两类）。
  ///
  /// 架构铁律：**会话不再有原生页面**，因此这里绝不 `context.push` 任何会话路由
  /// （会话消息 / 会话列表 / 审批中心 / 投递四个原生路由常量均已随批次 C 删除，
  /// 复活其中任何一个都等于架构回退）。会话深链落成「在 WebView 内定位」。
  ///
  /// 定位机制与其诚实边界（实测核准，勿按想象改）：
  /// - 服务端 SPA 只注册了 `GET /{$}` 与 `GET /login` 两个入口
  ///   （harness_go `internal/api/router.go`），`static.go` 的 serveStatic 没有
  ///   SPA fallback，请求 `/sessions/<id>` 会**直接 404**；
  /// - `web/src` 也没有会话级 URL 路由（全仓仅 `LoginPage.tsx` 读
  ///   `window.location.search`），Web UI 是内存 store 内切会话；
  /// - [MobileWebView] 当前也不提供实例创建后的 `loadRequest` 能力。
  ///
  /// 因此端侧**无法**凭空把 Web 页面导航到某个会话；正确做法是
  /// 「待定位意图暂存 + 页面就绪后消费」，绝不静默丢弃意图。
  void _dispatchDeepLink(DeepLinkIntent intent) {
    final handler = widget.onDeepLink;
    if (handler != null) {
      handler(intent);
      return;
    }
    switch (intent.kind) {
      case DeepLinkKind.session:
        _pendingSessionId = intent.id;
        if (_error == null && !_loading && _webView != null) {
          _consumePendingSession();
        } else {
          // 首帧未就绪：先记住意图，等 onPageFinished 回来再消费。
          _toast('已记录要打开的会话，页面就绪后为你定位');
        }
      case DeepLinkKind.reauth:
        // 语义：Cookie 失效 → 回原生重签一次性 ticket（复用已有签发能力），
        // 拿不到票时 fail-closed 提示回登录，不给静默放行、不伪造凭据。
        unawaited(_handleReauthDeepLink());
    }
  }

  /// 消费暂存的会话定位意图。
  ///
  /// 现阶段 Web UI 无会话级 URL 路由，端侧只能把页面刷新到工作区最新状态
  /// （`reload` 是 [MobileWebView] 已有的唯一导航能力）并明确告知用户目标
  /// 会话 id，由用户在 Web 工作区内确认。**不假装已定位成功**。
  void _consumePendingSession() {
    final sid = _pendingSessionId;
    if (sid == null || sid.isEmpty) return;
    _pendingSessionId = null;
    unawaited(_reload(_webView));
    _toast('已刷新 Web 工作区，请在其中打开会话 $sid');
  }

  /// `harness://reauth`：用已有 [WebViewTicketApi.issue] 重签一次性 ticket。
  Future<void> _handleReauthDeepLink() async {
    final services = servicesOf(ref);
    final deviceId = ref.read(appSessionProvider).deviceId;
    if (services == null || deviceId.isEmpty) {
      _toast('登录已失效，请回账号页重新登录');
      return;
    }
    try {
      final ticket = await services.webviewTicket.issue(deviceId: deviceId);
      if (!mounted) return;
      if (ticket.isEmpty) {
        _toast('凭据重签未返回票据，请回账号页重新登录');
        return;
      }
      _toast('凭据已重签，正在刷新 Web 工作区');
      await _reload(_webView);
    } on Object {
      // 服务端端点未接线 / 网络异常 / 未授权：一律安全降级为「回原生登录」。
      if (!mounted) return;
      _toast('凭据重签失败，请回账号页重新登录');
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
      // 没有实例（认证失败 / 被丢弃）：重新走一遍完整认证流程，
      // **绝不**退回裸地址（否则点重试等于绕过 fail-closed）。
      final baseUrl = ref.read(appSessionProvider).baseUrl;
      if (baseUrl.isEmpty) return;
      _dropWebView();
      // 解锁门未过的状态下不发起认证：避免带着凭据去创建不该存在的实例。
      final lock = ref.read(webViewLockProvider);
      final stage = ref.read(appSessionProvider).stage;
      if (shouldGateWebView(stage) && lock.isLocked) {
        setState(() {
          _loading = false;
          _error = null;
          _authBlocked = false;
        });
        return;
      }
      _createdFor = baseUrl;
      final generation = ++_generation;
      unawaited(_createWebView(baseUrl, generation));
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
      _authBlocked = false;
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
    this.onOpenAccount,
    this.authFailure,
    this.onRetryTicket,
  });

  final String message;
  final VoidCallback onRetry;
  final VoidCallback onOpenSetup;

  /// 非空时额外给一个「回账号页重新登录」的出口。
  ///
  /// 只用于**凭据不可用**的 fail-closed 分支：Web UI 没有登录表单，
  /// 拿不到 ticket/Cookie 时用户唯一能自救的动作就是回原生重新登录。
  final VoidCallback? onOpenAccount;

  /// 凭据链路的结构化失败原因（M3）：用于把提示语精准化。
  final WebViewAuthFailure? authFailure;

  /// 非空时展示「重试票据申请」按钮（M3：过期票必须能一键重签）。
  ///
  /// 与 [onRetry] 的区别：[onRetry] 走完整的「认证 + 建视图」链路，
  /// 本按钮只在**票据类**失败时出现，语义更明确（用户能看懂自己在重试什么）。
  final VoidCallback? onRetryTicket;

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
              onOpenAccount == null
                  ? '可能是服务端未启动、地址填错，或该服务端版本未内置 Web 界面。'
                  : '内置页面没有登录表单，请回账号页确认登录状态后重试。',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.outline),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: <Widget>[
                FilledButton.icon(
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh),
                  label: const Text('重试'),
                ),
                if (onRetryTicket != null)
                  FilledButton.tonalIcon(
                    onPressed: onRetryTicket,
                    icon: const Icon(Icons.vpn_key_outlined),
                    label: const Text('重试票据申请'),
                  ),
                OutlinedButton.icon(
                  onPressed: onOpenSetup,
                  icon: const Icon(Icons.settings_outlined),
                  label: const Text('检查服务端地址'),
                ),
                if (onOpenAccount != null)
                  OutlinedButton.icon(
                    onPressed: onOpenAccount,
                    icon: const Icon(Icons.account_circle_outlined),
                    label: const Text('回账号页重新登录'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// App 级解锁门（批次 C-2，架构文档 §4.7.1）。
///
/// 位置：身份齐备（[AppStage.webview]）且 [WebViewLock] 未解锁时**替代**整个
/// WebView 主体渲染。三条铁律在 UI 层的体现：
/// 1. **无跳过按钮**：只有「解锁」与「回账号页」，后者用于登出而不是绕过；
/// 2. **fail-closed 可见**：闸门拒绝 / 抛异常都由页面 `_unlock` 转成可读文案
///    内联展示，用户能看懂并重试，而不是看到一个永久转圈或红屏；
/// 3. **验证中禁用按钮**：防止连点弹出多个系统验证框（状态机也会拒）。
class _LockState extends StatelessWidget {
  const _LockState({
    required this.authenticating,
    required this.error,
    required this.onUnlock,
    required this.onOpenAccount,
  });

  final bool authenticating;
  final String? error;
  final VoidCallback onUnlock;
  final VoidCallback onOpenAccount;

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
              Icons.fingerprint,
              size: 56,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(height: 16),
            Text('解锁后进入工作区', style: theme.textTheme.titleMedium),
            const SizedBox(height: 6),
            Text(
              '为保护本机凭据，进入内置工作区前需要验证指纹或面容。',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.outline),
            ),
            if (error != null) ...<Widget>[
              const SizedBox(height: 12),
              Text(
                error!,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.error),
              ),
            ],
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: authenticating ? null : onUnlock,
              icon: authenticating
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.lock_open),
              label: Text(authenticating ? '正在验证…' : '解锁'),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: onOpenAccount,
              child: const Text('回账号页'),
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
