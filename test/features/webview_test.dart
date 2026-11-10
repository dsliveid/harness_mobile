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

  @override
  MobileWebView create({
    required Uri initialUrl,
    required String bridgeScript,
    required void Function(Uri url) onPageStarted,
    required void Function(Uri url) onPageFinished,
    required void Function(String message) onLoadFailed,
    required bool Function(Uri url) onNavigationRequest,
  }) {
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

Future<ProviderContainer> _pumpWebView(
  WidgetTester tester, {
  required String baseUrl,
  WebViewFactory? factory,
}) async {
  final store = InMemorySecureStore();
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
  await tester.pump(); // postFrameCallback → 创建 WebView
  await tester.pump();
  return container;
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

    testWidgets('baseUrl 就绪 → 加载根地址且注入桥脚本', (WidgetTester tester) async {
      final factory = _FakeWebViewFactory();
      await _pumpWebView(
        tester,
        baseUrl: 'http://localhost:8080',
        factory: factory,
      );

      expect(factory.initialUrl.toString(), 'http://localhost:8080/');
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
      await tester.pump();
      await tester.pump();

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
