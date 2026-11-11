/// WebView 桥与全功能视图的出口门禁测试（批次 C：WebView 主体架构）。
///
/// 覆盖交接书的四条硬约束：
/// 1. **R3（不注入令牌）**：注入页面的脚本里绝不能出现任何令牌字段
///    （`device_token` / `deviceToken` / `user_token` / `access_token`）。
/// 2. 桥只暴露 `harnessMobile` 能力声明 + `openDeepLink`。
/// 3. 深链严格白名单：只认 `harness://session/<id>` 与 `harness://reauth`，
///    其它（含 https、`harness://approval/...`、未知类型、缺 id）一律 null。
/// 4. **版本协商不白屏**：加载失败 → 可读错误 + 重试；baseUrl 为空 → 空态文案。
///
/// 批次 C 变更：审批中心已删除，深链白名单同步去掉 `approval`、新增 `reauth`；
/// 原 `DeepLinkKind.approval` 的用例改写为「approval 必须被拒」的否定断言，
/// 并补上 reauth 的正向断言（覆盖率不降反升）。
library;

import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_mobile/core/app/api_services.dart';
import 'package:harness_mobile/core/app/providers.dart';
import 'package:harness_mobile/data/local/app_settings_store.dart';
import 'package:harness_mobile/data/local/secure_store.dart';
import 'package:harness_mobile/data/remote/webview_ticket_api.dart';
import 'package:harness_mobile/features/settings/account_page.dart';
import 'package:harness_mobile/features/shared/connection_state_ui.dart';
import 'package:harness_mobile/features/webview/js_bridge.dart';
import 'package:harness_mobile/features/webview/webview_page.dart';

/// 假的内置浏览器实例（Dart VM 环境下无法创建真实平台视图）。
class _FakeWebView implements MobileWebView {
  _FakeWebView({required this.label});

  final String label;
  int reloadCount = 0;

  @override
  Widget build(BuildContext context) => Center(
        child: Text(label, textDirection: TextDirection.ltr),
      );

  @override
  Future<void> reload() async {
    reloadCount++;
  }

  @override
  Future<bool> canGoBack() async => false;

  @override
  Future<void> goBack() async {}

  @override
  void dispose() {}
}

/// 捕获 create() 入参，便于断言「注入了什么脚本、加载了哪个地址」。
class _FakeWebViewFactory implements WebViewFactory {
  _FakeWebViewFactory({this.failWith});

  /// 非空时在 create 里立刻回调 onLoadFailed，模拟加载失败。
  final String? failWith;

  Uri? initialUrl;
  String? bridgeScript;
  bool Function(Uri url)? navigationHandler;
  _FakeWebView? view;

  /// create 调用次数（验证重锁后重建、重试不会重复创建）。
  int createCount = 0;

  @override
  MobileWebView create({
    required Uri initialUrl,
    required String bridgeScript,
    required void Function(Uri url) onPageStarted,
    required void Function(Uri url) onPageFinished,
    required void Function(String message) onLoadFailed,
    required bool Function(Uri url) onNavigationRequest,
  }) {
    createCount++;
    this.initialUrl = initialUrl;
    this.bridgeScript = bridgeScript;
    navigationHandler = onNavigationRequest;
    final created = _FakeWebView(label: '内置页面 ${initialUrl.host}');
    view = created;
    if (failWith != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        onLoadFailed(failWith!);
      });
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        onPageFinished(initialUrl);
      });
    }
    return created;
  }
}

/// 静默适配器：所有出网请求返回 401（模拟「拿不到账号信息」的弱网/未授权场景）。
class _SilentAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return ResponseBody.fromString(
      '{"code":"unauthorized","message":"未登录"}',
      401,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>[Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// 票据可用适配器：`POST /api/v1/auth/webview-ticket` 返回一次性 ticket。
///
/// 批次 C-4 起首帧**必须先认证**，因此所有「要真创建 WebView」的用例
/// 都必须让凭据链路成功，否则页面会走 fail-closed 分支（那是另一组用例）。
class _TicketAdapter implements HttpClientAdapter {
  _TicketAdapter({this.ticket = 'tk-abc123'});

  final String ticket;
  final List<RequestOptions> requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    if (options.path == '/api/v1/auth/webview-ticket') {
      return ResponseBody.fromString(
        '{"ticket":"$ticket","expires_at":1893456000000}',
        200,
        headers: <String, List<String>>{
          Headers.contentTypeHeader: <String>[Headers.jsonContentType],
        },
      );
    }
    return ResponseBody.fromString('{"code":"not_found"}', 404, headers: <String, List<String>>{
      Headers.contentTypeHeader: <String>[Headers.jsonContentType],
    });
  }

  @override
  void close({bool force = false}) {}
}

Future<ProviderContainer> _pumpWebView(
  WidgetTester tester, {
  required String baseUrl,
  WebViewFactory? factory,
  HttpClientAdapter? adapter,
  String? userToken,
  WebViewCookieSink? cookieSink,
}) async {
  final store = InMemorySecureStore();
  if (userToken != null) await store.setUserToken(userToken);
  final dio = Dio();
  // 默认让凭据链路成功（ticket 模式），否则页面按设计走 fail-closed 不建 WebView。
  dio.httpClientAdapter = adapter ?? _TicketAdapter();
  final container = ProviderContainer(
    overrides: <Override>[
      secureStoreProvider.overrideWithValue(store),
      settingsStoreProvider.overrideWithValue(
        InMemorySettingsStore(
          AppSettings(
            baseUrl: baseUrl,
            deviceId: baseUrl.isEmpty ? '' : 'dev-1',
            deviceName: baseUrl.isEmpty ? '' : '测试机',
          ),
        ),
      ),
      apiFactoryProvider.overrideWithValue(ApiFactory(store: store, dio: dio)),
      if (cookieSink != null)
        webViewCookieSinkProvider.overrideWithValue(cookieSink),
    ],
  );
  addTearDown(container.dispose);
  await container.read(appSessionProvider).load();

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: WebViewPage(
          webViewFactory: factory ?? _FakeWebViewFactory(),
          appVersion: '1.2.3',
        ),
      ),
    ),
  );
  // postFrameCallback → prepareAuth（含网络往返）→ create，链路有多个异步跳，
  // 单次 pump 不足以跑完；这里循环推进若干帧（不用 pumpAndSettle：
  // 加载中的 LinearProgressIndicator 是无限动画，会把它拖到超时）。
  await _settle(tester);
  return container;
}

/// 反复推进帧，直到没有新的异步跳（最多 [times] 轮）。
///
/// 认证链路 = postFrame → await prepareAuth → await create，属于纯 microtask
/// 串联，`pump()` 会 flush microtask 队列，因此逐帧推进即可收敛。
Future<void> _settle(WidgetTester tester, {int times = 8}) async {
  for (var i = 0; i < times; i++) {
    await tester.pump(const Duration(milliseconds: 1));
  }
}

/// 记录型 Cookie sink：验证「Cookie 值只进 Cookie jar，不进 URL」。
class _RecordingCookieSink implements WebViewCookieSink {
  _RecordingCookieSink({this.succeeds = true});

  /// false 用于构造「方案 B 也不可用」的 fail-closed 场景。
  final bool succeeds;

  final List<({String url, String name, String value})> writes =
      <({String url, String name, String value})>[];

  @override
  Future<bool> writeSessionCookie({
    required String url,
    required String name,
    required String value,
  }) async {
    writes.add((url: url, name: name, value: value));
    return succeeds;
  }

  @override
  Future<void> clearSessionCookies() async {}
}

/// 全部 404 的适配器：模拟「服务端尚未实现 webview-ticket 端点」。
///
/// 注意 `/api/v1/auth/me` 单独返回 200：本适配器服务的是「票据不可用 → 走
/// Cookie 降级」这组用例，而 Cookie 降级前有**强制的有效性校验**（Bug 2 修复）。
/// 若这里也 404，降级会被正确地判为不可用 —— 那属于另一组 fail-closed 用例。
class _NotFoundAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.path == '/api/v1/auth/me') {
      return ResponseBody.fromString(
        '{"id":"u1","username":"alice"}',
        200,
        headers: <String, List<String>>{
          Headers.contentTypeHeader: <String>[Headers.jsonContentType],
        },
      );
    }
    return ResponseBody.fromString(
      '{"code":"not_found","message":"未实现"}',
      404,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>[Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// 全部 404 **且** 会话无效的适配器：模拟「票据与 Cookie 双双不可用」。
///
/// 与 [_NotFoundAdapter] 的唯一差别是 `/auth/me` 也 401：这是 Bug 2 修复后的
/// 新语义 —— 会话无效时 Cookie 注入必须被拦下，于是链路走到 fail-closed。
class _DeadSessionAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return ResponseBody.fromString(
      '{"error":{"code":"unauthorized","message":"会话已失效"}}',
      options.path == '/api/v1/auth/me' ? 401 : 404,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>[Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  group('buildBridgeScript（R3：绝不注入令牌）', () {
    test('脚本不含任何令牌字样', () {
      final script = buildBridgeScript(appVersion: '1.2.3');

      // R3 核心断言：这些字符串一旦出现，说明凭据被泄漏到页面上下文。
      expect(script.contains('device_token'), isFalse);
      expect(script.contains('deviceToken'), isFalse);
      expect(script.contains('user_token'), isFalse);
      expect(script.contains('userToken'), isFalse);
      expect(script.contains('access_token'), isFalse);
      expect(script.contains('refresh_token'), isFalse);
      expect(script.contains('Authorization'), isFalse);
      expect(script.contains('token'), isFalse);
      expect(script.contains('Bearer'), isFalse);
      expect(script.contains('password'), isFalse);
    });

    test('脚本暴露 harnessMobile 与 openDeepLink', () {
      final script = buildBridgeScript(appVersion: '1.2.3');
      expect(script.contains('harnessMobile'), isTrue);
      expect(script.contains('openDeepLink'), isTrue);
      // 版本协商：构建期版本号必须出现在脚本里（页面据此提示「请升级 App」）
      expect(script.contains('1.2.3'), isTrue);
      expect(script.contains('harness://'), isTrue);
    });

    test('版本号做 JS 字符串转义（防注入）', () {
      final script = buildBridgeScript(appVersion: "1.0'; alert(1); //");
      expect(script.contains(r"\'"), isTrue);
      // 未被转义的裸引号只会出现在正常的模板位置（开头的 scheme 行）
      expect(script.contains("alert(1)"), isTrue); // 内容仍在，但被转义后只是字符串
      expect(script.contains(r"1.0\'; alert(1); //"), isTrue);
    });
  });

  group('parseDeepLink（白名单深链）', () {
    test('harness://reauth → reauth（Cookie 失效时请求原生重签）', () {
      final intent = parseDeepLink('harness://reauth');
      expect(intent, isNotNull);
      expect(intent!.kind, DeepLinkKind.reauth);
      // reauth 无目标对象，id 必须是空串（不可伪造一个假 id 诱导端侧行为）
      expect(intent.id, '');
    });

    test('harness://session/xyz → session + xyz', () {
      final intent = parseDeepLink('harness://session/xyz');
      expect(intent, isNotNull);
      expect(intent!.kind, DeepLinkKind.session);
      expect(intent.id, 'xyz');
    });

    test('https://evil.com → null', () {
      expect(parseDeepLink('https://evil.com'), isNull);
    });

    test('harness://unknown/x → null（未知类型）', () {
      expect(parseDeepLink('harness://unknown/x'), isNull);
    });

    test('已删除的 harness://approval/<id> 必须被拒（批次 C 收窄白名单）', () {
      // 审批中心已删除，页面若还发 approval 深链说明 Web 端未同步升级，
      // 端侧必须拒绝而不是"尽力处理"，否则会给用户假的功能入口。
      expect(parseDeepLink('harness://approval/abc'), isNull);
      expect(parseDeepLink('harness://approval'), isNull);
    });

    test('缺 id / 空串 / 非 URL 一律 null', () {
      expect(parseDeepLink('harness://session'), isNull);
      expect(parseDeepLink('harness://session/'), isNull);
      expect(parseDeepLink(''), isNull);
      expect(parseDeepLink('   '), isNull);
      expect(parseDeepLink('not a url'), isNull);
    });

    test('大小写与尾部斜杠容忍', () {
      final intent = parseDeepLink('HARNESS://SESSION/evt-9');
      expect(intent, isNotNull);
      expect(intent!.kind, DeepLinkKind.session);
      expect(intent.id, 'evt-9');
    });

    test('reauth 大小写容忍（Host 归一化）', () {
      final intent = parseDeepLink('HARNESS://REAUTH');
      expect(intent, isNotNull);
      expect(intent!.kind, DeepLinkKind.reauth);
    });

    test('javascript: / file: 等危险 scheme 被拒', () {
      expect(parseDeepLink('javascript:alert(1)'), isNull);
      expect(parseDeepLink('file:///etc/passwd'), isNull);
      expect(parseDeepLink('intent://session/x'), isNull);
    });
  });

  group('WebViewPage（版本协商不白屏）', () {
    testWidgets('baseUrl 为空 → 展示空态文案，不创建 WebView', (WidgetTester tester) async {
      final factory = _FakeWebViewFactory();
      await _pumpWebView(tester, baseUrl: '', factory: factory);

      expect(find.text('请先配置服务端地址'), findsOneWidget);
      expect(find.textContaining('需要先填写服务端地址'), findsOneWidget);
      // 空态下不应该去创建平台视图
      expect(factory.initialUrl, isNull);
    });

    testWidgets('baseUrl 就绪 → 首帧 URL 带 ticket 且注入桥脚本（R3 不泄漏）',
        (WidgetTester tester) async {
      final factory = _FakeWebViewFactory();
      await _pumpWebView(
        tester,
        baseUrl: 'http://localhost:8080',
        factory: factory,
      );

      // 批次 C-4：首帧必须由 prepareAuth 产出，ticket 走 fragment。
      expect(factory.initialUrl!.fragment, 'ticket=tk-abc123');
      expect(factory.initialUrl!.query, isEmpty);
      // 否定断言：首帧 URL 里绝不能出现设备令牌明文
      expect(factory.initialUrl.toString().contains('device_token'), isFalse);
      expect(factory.bridgeScript, isNotNull);
      expect(factory.bridgeScript!.contains('harnessMobile'), isTrue);
      // R3：真实注入路径上同样不允许出现令牌字样
      expect(factory.bridgeScript!.contains('token'), isFalse);
    });

    testWidgets('加载失败 → 可读错误 + 重试 + 检查地址，不白屏', (WidgetTester tester) async {
      final factory = _FakeWebViewFactory(failWith: '服务端返回 500，内置页面暂时不可用');
      await _pumpWebView(
        tester,
        baseUrl: 'http://localhost:8080',
        factory: factory,
      );
      await tester.pump();

      expect(find.textContaining('服务端返回 500'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);
      expect(find.text('检查服务端地址'), findsWidgets);
    });

    testWidgets('深链导航被拦截并派发意图，普通 URL 放行', (WidgetTester tester) async {
      final factory = _FakeWebViewFactory();
      final List<DeepLinkIntent> captured = <DeepLinkIntent>[];
      final store = InMemorySecureStore();
      final container = ProviderContainer(
        overrides: <Override>[
          secureStoreProvider.overrideWithValue(store),
          settingsStoreProvider.overrideWithValue(
            InMemorySettingsStore(
              const AppSettings(
                baseUrl: 'http://localhost:8080',
                deviceId: 'dev-1',
                deviceName: '测试机',
              ),
            ),
          ),
          // 首帧需真实创建 WebView → 凭据链路必须可用（ticket 模式）。
          apiFactoryProvider.overrideWithValue(
            ApiFactory(store: store, dio: Dio()..httpClientAdapter = _TicketAdapter()),
          ),
        ],
      );
      addTearDown(container.dispose);
      await container.read(appSessionProvider).load();

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: WebViewPage(
              webViewFactory: factory,
              onDeepLink: captured.add,
            ),
          ),
        ),
      );
      await _settle(tester);

      final handler = factory.navigationHandler;
      expect(handler, isNotNull);

      // 普通页面导航：放行
      expect(handler!(Uri.parse('http://localhost:8080/sessions')), isTrue);
      // 深链：拦截 + 派发
      expect(handler(Uri.parse('harness://session/sess-42')), isFalse);
      expect(captured.length, 1);
      expect(captured.first.kind, DeepLinkKind.session);
      expect(captured.first.id, 'sess-42');
      // 未知深链：拦截但不派发
      expect(handler(Uri.parse('harness://unknown/x')), isFalse);
      expect(captured.length, 1);
    });

    testWidgets('未注入 onDeepLink 时 session 深链不崩溃且不丢弃意图（页面内定位）',
        (WidgetTester tester) async {
      // 批次 C 回归守护：默认分发路径曾引用已删除的会话路由与已注销的审批深链枚举。
      // 修复后默认路径必须：① 拦截深链；② 不跳任何原生页面；③ 记住意图并在
      // 页面就绪后消费（刷新 Web 工作区），绝不静默丢弃。
      final factory = _FakeWebViewFactory();
      final container = await _pumpWebView(
        tester,
        baseUrl: 'http://localhost:8080',
        factory: factory,
      );
      expect(container, isNotNull);

      final handler = factory.navigationHandler;
      expect(handler, isNotNull);
      expect(handler!(Uri.parse('harness://session/sess-99')), isFalse);

      await tester.pump();
      await tester.pump();

      // 页面仍是 WebView 主体（没有 push 任何原生会话页）
      expect(find.byType(WebViewPage), findsOneWidget);
      // 标题栏降高后中文标题改由 tooltip 承载（见 webview_page 的 _buildAppBar）
      expect(find.byTooltip('全功能视图'), findsOneWidget);
      // 意图被消费：reload 至少被触发一次（即「在 WebView 内定位」的现有能力）
      expect(factory.view!.reloadCount, greaterThanOrEqualTo(1));
      expect(tester.takeException(), isNull);
    });
  });

  group('首帧认证注入（批次 C-4：先认证再创建）', () {
    testWidgets('ticket 可用 → initialUrl 含 #ticket= 且不含 device_token 明文',
        (WidgetTester tester) async {
      final factory = _FakeWebViewFactory();
      final adapter = _TicketAdapter(ticket: 'tk-secret-42');
      await _pumpWebView(
        tester,
        baseUrl: 'http://localhost:8080',
        factory: factory,
        adapter: adapter,
      );

      final url = factory.initialUrl!;
      expect(url.fragment, 'ticket=tk-secret-42');
      // 硬约束：ticket 走 fragment（不进 Referer / access log），query 必须为空
      expect(url.query, isEmpty);
      // 否定断言：设备令牌绝不出现在 URL 任何位置
      expect(url.toString().contains('device_token'), isFalse);
      expect(url.toString().contains('dev-1'), isFalse);
      // 确实调用了签发端点
      expect(
        adapter.requests.map((RequestOptions r) => r.path),
        contains('/api/v1/auth/webview-ticket'),
      );
    });

    testWidgets('ticket 不可用 → 降级 Cookie 注入，且 Cookie 值不出现在 URL 里',
        (WidgetTester tester) async {
      final factory = _FakeWebViewFactory();
      final sink = _RecordingCookieSink();
      await _pumpWebView(
        tester,
        baseUrl: 'http://localhost:8080',
        factory: factory,
        // ticket 端点 404（服务端未接线时的真实形态）
        adapter: _NotFoundAdapter(),
        cookieSink: sink,
        userToken: 'user-token-xyz',
      );

      // 走了 Cookie 路径
      expect(sink.writes, hasLength(1));
      expect(sink.writes.single.name, kSessionCookieName);
      expect(sink.writes.single.value, 'user-token-xyz');
      // 拿到的仍是裸入口（fragment 为空），但凭据只在 Cookie jar 里
      final url = factory.initialUrl!;
      expect(url.fragment, isEmpty);
      // 最关键否定断言：Cookie 值绝不能出现在 URL 中
      expect(url.toString().contains('user-token-xyz'), isFalse);
      expect(url.toString().contains(kSessionCookieName), isFalse);
    });

    testWidgets('ticket 与 Cookie 双双失败 → fail-closed：不创建 WebView，展示错误态与重试',
        (WidgetTester tester) async {
      final factory = _FakeWebViewFactory();
      final sink = _RecordingCookieSink(succeeds: false);
      await _pumpWebView(
        tester,
        baseUrl: 'http://localhost:8080',
        factory: factory,
        // 票据 404 + 会话 401：Cookie 降级会被前置校验正确拦下 → fail-closed
        adapter: _DeadSessionAdapter(),
        cookieSink: sink,
        // 无用户令牌 → injectSessionCookie 直接返回 false
      );

      // ★ 最关键的否定断言：绝不创建 WebView（也就绝不会裸地址放行）
      expect(factory.initialUrl, isNull);
      expect(factory.bridgeScript, isNull);
      // 可读错误 + 重试 + 明确的下一步（回账号页重新登录）
      expect(find.textContaining('无法为内置页面获取登录凭据'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);
      expect(find.text('回账号页重新登录'), findsOneWidget);
      expect(find.textContaining('没有登录表单'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('fail-closed 后点重试仍走认证（不退回裸地址）', (WidgetTester tester) async {
      final factory = _FakeWebViewFactory();
      await _pumpWebView(
        tester,
        baseUrl: 'http://localhost:8080',
        factory: factory,
        adapter: _NotFoundAdapter(),
        cookieSink: _RecordingCookieSink(succeeds: false),
      );
      expect(factory.initialUrl, isNull);

      await tester.tap(find.text('重试'));
      await _settle(tester);

      // 依然失败 → 依然不创建；但路径必须还是认证链路（不是裸地址）
      expect(factory.initialUrl, isNull);
      expect(find.textContaining('无法为内置页面获取登录凭据'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('加载失败错误态不误挂「回账号页」按钮（只有凭据问题才引导重登）',
        (WidgetTester tester) async {
      final factory = _FakeWebViewFactory(failWith: '服务端返回 500，内置页面暂时不可用');
      await _pumpWebView(
        tester,
        baseUrl: 'http://localhost:8080',
        factory: factory,
      );

      expect(find.textContaining('服务端返回 500'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);
      expect(find.text('回账号页重新登录'), findsNothing);
    });
  });


  group('工具栏降高（窄屏优化：40dp 图标条 + 状态圆点）', () {
    testWidgets('工具栏高度显著低于默认 56dp，且不再渲染中文标题文字',
        (WidgetTester tester) async {
      final factory = _FakeWebViewFactory();
      await _pumpWebView(
        tester,
        baseUrl: 'http://localhost:8080',
        factory: factory,
      );

      // 测试环境无系统状态栏 insets，故 AppBar 实测高度即 toolbarHeight。
      final appBarSize = tester.getSize(find.byType(AppBar));
      expect(appBarSize.height, lessThanOrEqualTo(44),
          reason: '工具栏未降高，仍占用默认 56dp');
      // 标题文字已移除（否则 360dp 窄屏会与右侧图标抢空间）
      expect(find.text('全功能视图'), findsNothing);
      expect(find.byTooltip('全功能视图'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('操作区收敛为纯图标：状态圆点 + 后退 + 刷新（设置移入长按弹层）',
        (WidgetTester tester) async {
      final factory = _FakeWebViewFactory();
      await _pumpWebView(
        tester,
        baseUrl: 'http://localhost:8080',
        factory: factory,
      );

      expect(find.byType(ConnectionStateDot), findsOneWidget);
      expect(find.byIcon(Icons.arrow_back), findsOneWidget);
      expect(find.byIcon(Icons.refresh), findsOneWidget);
      // 正常分支不再常驻设置图标（改用长按状态圆点进入）
      expect(find.byIcon(Icons.settings_outlined), findsNothing);
      // 中文 Chip 已不再占用工具栏
      expect(find.byType(ConnectionStateChip), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('长按状态圆点弹出详情弹层，承接「检查服务端地址」入口',
        (WidgetTester tester) async {
      final factory = _FakeWebViewFactory();
      await _pumpWebView(
        tester,
        baseUrl: 'http://localhost:8080',
        factory: factory,
      );

      await tester.longPress(find.byType(ConnectionStateDot));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // 弹层里给出完整状态详情（detail / actionHint 信息不能因为降高就丢）
      expect(find.text('设备连接状态'), findsOneWidget);
      expect(find.byType(ConnectionStateChip), findsOneWidget);
      expect(find.text('检查服务端地址'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('无 baseUrl 分支保留可见的设置入口（引导页不能只靠长按）',
        (WidgetTester tester) async {
      final factory = _FakeWebViewFactory();
      await _pumpWebView(tester, baseUrl: '', factory: factory);

      expect(find.text('请先配置服务端地址'), findsOneWidget);
      expect(find.byIcon(Icons.settings_outlined), findsOneWidget);
      // 引导页没有 WebView 可操作，后退/刷新应禁用而非隐藏
      expect(find.byIcon(Icons.arrow_back), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('AccountPage（注销降级方案）', () {
    testWidgets('展示账号信息与诚实的注销指引，解绑需二次确认', (WidgetTester tester) async {
      final store = InMemorySecureStore();
      await store.setUserToken('user-token');
      final settings = InMemorySettingsStore(
        const AppSettings(
          baseUrl: 'http://localhost:8080',
          deviceId: 'dev-1',
          deviceName: '测试机',
        ),
      );
      final container = ProviderContainer(
        overrides: <Override>[
          secureStoreProvider.overrideWithValue(store),
          settingsStoreProvider.overrideWithValue(settings),
          apiFactoryProvider.overrideWithValue(
            ApiFactory(store: store, dio: Dio()..httpClientAdapter = _SilentAdapter()),
          ),
        ],
      );
      addTearDown(container.dispose);
      await container.read(appSessionProvider).load();

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: AccountPage()),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(find.text('本机设备'), findsOneWidget);
      expect(find.text('测试机'), findsOneWidget);
      expect(find.text('解除本机绑定'), findsOneWidget);
      expect(find.text('账号数据的删除需在 Web 端完成'), findsOneWidget);

      // 注销指引弹窗必须给出 Web 端地址，且不得声称已在端侧删除
      await tester.ensureVisible(find.text('注销账号'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('注销账号'));
      await tester.pumpAndSettle();
      expect(find.text('账号数据的删除需在 Web 端完成。'), findsOneWidget);
      // 新版 baseUrl 归一化会补尾斜杠（防 ?# 空尾巴陷阱），弹窗内 Text 与
      // 复制用的 controller 各渲染一份 → findsWidgets（至少一个即可）
      expect(find.textContaining('http://localhost:8080'), findsWidgets);
      expect(find.text('复制地址'), findsOneWidget);
      await tester.tap(find.text('知道了'));
      await tester.pumpAndSettle();

      // 解除本机绑定：先弹二次确认，取消则不清数据
      await tester.ensureVisible(find.text('解除本机绑定'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('解除本机绑定'));
      await tester.pumpAndSettle();
      expect(find.text('解除本机绑定？'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(store.getUserToken(), completion(isNotNull));

      // 确认后清空全部本地凭据
      await tester.ensureVisible(find.text('解除本机绑定'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('解除本机绑定'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('解除绑定'));
      await tester.pumpAndSettle();
      expect(await store.getUserToken(), isNull);
      expect(await store.getDeviceToken(), isNull);
      expect(store.clearedCount, greaterThan(0));
    });
  });
}
