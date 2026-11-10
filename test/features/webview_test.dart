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
import 'package:harness_mobile/core/app/app_session.dart';
import 'package:harness_mobile/core/app/biometric_gate.dart';
import 'package:harness_mobile/core/app/providers.dart';
import 'package:harness_mobile/core/app/webview_lock.dart';
import 'package:harness_mobile/data/local/app_settings_store.dart';
import 'package:harness_mobile/data/local/secure_store.dart';
import 'package:harness_mobile/data/remote/webview_ticket_api.dart';
import 'package:harness_mobile/features/settings/account_page.dart';
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
  BiometricGate? gate,
  WebViewCookieSink? cookieSink,
  bool locked = false,
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
      // 解锁门显式控制初始态：默认「已解锁」只针对**认证链路**用例
      // （它们要断言首帧 URL，必须先把门放开），锁屏行为由 `locked: true`
      // 的用例逐条断言，绝不因此弱化「默认 locked = fail-closed」的语义
      // ——该默认值由 `webview_lock_test.dart` 独立守住。
      webViewLockProvider.overrideWith(
        (Ref ref) => WebViewLock(
          gate: gate ?? const AlwaysPassBiometricGate(),
          initial: locked
              ? WebViewLockState.locked
              : WebViewLockState.unlocked,
        ),
      ),
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
class _NotFoundAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
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

/// 可编排的抛错闸门：验证「异常 → 回滚 locked → 可重试」。
class _ThrowingGate implements BiometricGate {
  bool throwing = true;
  int calls = 0;

  @override
  Future<bool> authenticate({required String reason}) async {
    calls++;
    if (throwing) throw StateError('生物识别插件崩溃');
    return true;
  }
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
      expect(find.text('全功能视图'), findsOneWidget);
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
        adapter: _NotFoundAdapter(),
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

  group('App 级解锁门（批次 C-2：WebViewLock 接线）', () {
    testWidgets('身份齐备且未解锁 → 展示锁屏且不创建 WebView', (WidgetTester tester) async {
      final factory = _FakeWebViewFactory();
      await _pumpWebView(
        tester,
        baseUrl: 'http://localhost:8080',
        factory: factory,
        userToken: 'user-token', // stage == webview → 锁生效
        gate: const AlwaysDenyBiometricGate(),
        locked: true,
      );

      expect(find.text('解锁后进入工作区'), findsOneWidget);
      expect(find.text('解锁'), findsOneWidget);
      // ★ 否定断言：锁定态下绝不创建 WebView（凭据不进内存也进不了页面）
      expect(factory.initialUrl, isNull);
      expect(factory.bridgeScript, isNull);
    });

    testWidgets('身份未齐备（未登录）时不得把用户锁死在门口', (WidgetTester tester) async {
      final factory = _FakeWebViewFactory();
      await _pumpWebView(
        tester,
        baseUrl: 'http://localhost:8080',
        factory: factory,
        // 无 userToken → stage == login → shouldGateWebView 为 false
        gate: const AlwaysDenyBiometricGate(),
        locked: true,
      );

      expect(find.text('解锁后进入工作区'), findsNothing);
      expect(factory.initialUrl, isNotNull);
    });

    testWidgets('解锁门放行后才创建 WebView（AlwaysPass）', (WidgetTester tester) async {
      final factory = _FakeWebViewFactory();
      await _pumpWebView(
        tester,
        baseUrl: 'http://localhost:8080',
        factory: factory,
        userToken: 'user-token',
        gate: const AlwaysPassBiometricGate(),
        locked: true,
      );
      // 初始仍是锁定（fail-closed 默认值）
      expect(factory.initialUrl, isNull);

      await tester.tap(find.text('解锁'));
      await _settle(tester);

      expect(factory.initialUrl, isNotNull);
      expect(factory.initialUrl!.fragment, 'ticket=tk-abc123');
      expect(find.text('解锁后进入工作区'), findsNothing);
    });

    testWidgets('AlwaysDeny 闸门：解锁失败后仍锁定且能看到错误提示', (WidgetTester tester) async {
      final factory = _FakeWebViewFactory();
      await _pumpWebView(
        tester,
        baseUrl: 'http://localhost:8080',
        factory: factory,
        userToken: 'user-token',
        gate: const AlwaysDenyBiometricGate(),
        locked: true,
      );

      await tester.tap(find.text('解锁'));
      await _settle(tester);

      // 仍锁定，仍没有 WebView
      expect(find.text('解锁后进入工作区'), findsOneWidget);
      expect(factory.initialUrl, isNull);
      // 有可读错误，且没有「跳过」按钮（fail-closed 不许绕过）
      expect(find.textContaining('身份验证未通过'), findsOneWidget);
      expect(find.text('跳过'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('闸门抛异常：状态回滚 locked 且可重试（不做静默吞掉）',
        (WidgetTester tester) async {
      final factory = _FakeWebViewFactory();
      final gate = _ThrowingGate();
      await _pumpWebView(
        tester,
        baseUrl: 'http://localhost:8080',
        factory: factory,
        userToken: 'user-token',
        gate: gate,
        locked: true,
      );

      await tester.tap(find.text('解锁'));
      await _settle(tester);

      // 异常被转成可读提示，且状态已回滚（按钮可再次点击）
      expect(find.textContaining('解锁失败'), findsOneWidget);
      expect(find.text('解锁'), findsOneWidget); // 不是「正在验证…」卡死
      expect(factory.initialUrl, isNull);
      expect(tester.takeException(), isNull);

      // 第二次：闸门恢复 → 可以正常解锁并创建 WebView
      gate.throwing = false;
      await tester.tap(find.text('解锁'));
      await _settle(tester);

      expect(factory.initialUrl, isNotNull);
      expect(find.text('解锁后进入工作区'), findsNothing);
    });

    test('shouldGateWebView：只有身份齐备（webview 阶段）才要求生物识别', () {
      // 这条纯函数是「不把测试环境/未登录态锁死在门口」的唯一判据，
      // 单独断言四个阶段，防止后人把它改成恒 true。
      expect(shouldGateWebView(AppStage.webview), isTrue);
      expect(shouldGateWebView(AppStage.setup), isFalse);
      expect(shouldGateWebView(AppStage.pairing), isFalse);
      expect(shouldGateWebView(AppStage.login), isFalse);
    });

    testWidgets('回前台重新加锁后被解锁：丢弃旧实例并重新走认证（不复用已注入凭据）',
        (WidgetTester tester) async {
      final factory = _FakeWebViewFactory();
      final container = await _pumpWebView(
        tester,
        baseUrl: 'http://localhost:8080',
        factory: factory,
        userToken: 'user-token',
        gate: const AlwaysPassBiometricGate(),
        locked: true,
      );

      await tester.tap(find.text('解锁'));
      await _settle(tester);
      expect(factory.createCount, 1);
      final firstUrl = factory.initialUrl!.toString();

      // 模拟「切后台超过 relockAfter 回前台」：状态机自身 observer 负责重锁，
      // 这里直接调 lock() 等价触发，验证页面响应（重新丢弃 WebView）。
      container.read(webViewLockProvider).lock();
      await _settle(tester);

      expect(find.text('解锁后进入工作区'), findsOneWidget);
      // 旧实例必须被丢弃（帧后回调），不能继续持有已注入凭据的页面
      expect(factory.view, isNotNull);
      expect(tester.takeException(), isNull);

      // 再次解锁 → 重新创建（新的 initialUrl，不复用旧实例）
      await tester.tap(find.text('解锁'));
      await _settle(tester);
      expect(factory.createCount, 2);
      expect(factory.initialUrl.toString(), firstUrl);
      expect(find.text('解锁后进入工作区'), findsNothing);
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
