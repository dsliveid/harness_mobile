/// 深链白名单对齐测试（M2）。
///
/// 交接书的验收要求是两类断言，缺一不可：
/// 1. **已知深链直达**：`harness://session/<id>` 与 `harness://reauth` 必须
///    被解析成确定意图并派发到对应处理路径；
/// 2. **未知深链显式拒绝**：不许静默吞掉 —— 必须携带可读原因（[DeepLinkRejection]）
///    且在 UI 上给出用户可见反馈（SnackBar 文案），同时在拦截点上返回 false。
///
/// 第三类（防回退）：已随批次 C 删除的 `approval` 深链必须**继续被拒**，
/// 且身份链路页绝不能凭深链绕过首屏门禁（secondaryPages 不含 setup/pairing/
/// login/splash —— 由 `routing_test.dart` 独立守住，这里只做交叉复核）。
library;

import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_mobile/core/app/api_services.dart';
import 'package:harness_mobile/core/app/app_session.dart';
import 'package:harness_mobile/core/app/providers.dart';
import 'package:harness_mobile/data/local/app_settings_store.dart';
import 'package:harness_mobile/data/local/secure_store.dart';
import 'package:harness_mobile/features/webview/js_bridge.dart';
import 'package:harness_mobile/features/webview/webview_page.dart';

/// 假的内置浏览器实例（Dart VM 下无法创建真实平台视图）。
class _FakeWebView implements MobileWebView {
  int reloadCount = 0;

  @override
  Widget build(BuildContext context) =>
      const Center(child: Text('内置页面', textDirection: TextDirection.ltr));

  @override
  Future<void> reload() async => reloadCount++;

  @override
  Future<bool> canGoBack() async => false;

  @override
  Future<void> goBack() async {}

  @override
  void dispose() {}
}

/// 捕获导航处理器，供测试直接模拟 `shouldOverrideUrlLoading`。
class _FakeFactory implements WebViewFactory {
  Uri? initialUrl;
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
    navigationHandler = onNavigationRequest;
    final created = _FakeWebView();
    view = created;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      onPageFinished(initialUrl);
    });
    return created;
  }
}

/// 票据可用适配器（首帧认证必须成功，否则页面走 fail-closed 不建视图）。
class _TicketAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async =>
      ResponseBody.fromString(
        '{"ticket":"tk-abc123","expires_at":1893456000000}',
        200,
        headers: <String, List<String>>{
          Headers.contentTypeHeader: <String>[Headers.jsonContentType],
        },
      );

  @override
  void close({bool force = false}) {}
}

Future<ProviderContainer> _pump(
  WidgetTester tester,
  _FakeFactory factory, {
  void Function(DeepLinkIntent intent)? onDeepLink,
  void Function(DeepLinkRejection rejection)? onDeepLinkRejected,
}) async {
  final store = InMemorySecureStore();
  await store.setUserToken('ut-1');
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
      apiFactoryProvider.overrideWithValue(
        ApiFactory(
          store: store,
          dio: Dio()..httpClientAdapter = _TicketAdapter(),
        ),
      ),
      // 解锁门已移除（2026-11 取消生物锁）：这里无需再 override 任何锁 provider。
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
          onDeepLink: onDeepLink,
          onDeepLinkRejected: onDeepLinkRejected,
        ),
      ),
    ),
  );
  // postFrame → prepareAuth（网络往返）→ create → onPageFinished，多跳异步。
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 1));
  }
  return container;
}

void main() {
  group('resolveDeepLink：已知深链直达（白名单命中）', () {
    test('harness://session/<id> → session 意图且携带 id', () {
      final decision = resolveDeepLink('harness://session/sess-42');
      expect(decision.accepted, isTrue);
      expect(decision.rejected, isFalse);
      expect(decision.rejection, isNull);
      // 拒绝文案必须为空串：命中白名单时绝不能顺手弹一个「已拒绝」
      expect(decision.rejectMessage, '');

      final intent = decision.intent!;
      expect(intent.kind, DeepLinkKind.session);
      expect(intent.id, 'sess-42');
      expect(intent.rawUrl, 'harness://session/sess-42');
    });

    test('harness://reauth → reauth 意图且 id 为空串（不可伪造目标）', () {
      final decision = resolveDeepLink('harness://reauth');
      expect(decision.accepted, isTrue);
      final intent = decision.intent!;
      expect(intent.kind, DeepLinkKind.reauth);
      expect(intent.id, '');
    });

    test('大小写与首尾空白容忍后仍直达', () {
      final a = resolveDeepLink('  HARNESS://SESSION/evt-9  ').intent;
      expect(a, isNotNull);
      expect(a!.kind, DeepLinkKind.session);
      expect(a.id, 'evt-9');

      final b = resolveDeepLink('HARNESS://REAUTH').intent;
      expect(b, isNotNull);
      expect(b!.kind, DeepLinkKind.reauth);
    });

    test('parity：parseDeepLink 与 resolveDeepLink 结论必须一致', () {
      // parseDeepLink 是简版包装，两者绝不允许分叉（分叉即静默吞链）
      for (final url in <String>[
        'harness://session/s1',
        'harness://reauth',
        'harness://unknown/x',
        'harness://session',
        'https://evil.com',
        '',
      ]) {
        final intent = parseDeepLink(url);
        final decision = resolveDeepLink(url);
        expect(intent?.kind, decision.intent?.kind, reason: 'URL=$url');
        expect(intent?.id, decision.intent?.id, reason: 'URL=$url');
        // accepted / rejected 必须与 intent 的 null 性严格互补
        expect(decision.accepted, intent != null, reason: 'URL=$url');
      }
    });
  });

  group('resolveDeepLink：未知深链显式拒绝（带可读原因）', () {
    test('未知类型 → unknownHost，且文案含「已拒绝」而非「已忽略」', () {
      final decision = resolveDeepLink('harness://unknown/x');
      expect(decision.rejected, isTrue);
      expect(decision.intent, isNull);
      expect(decision.rejection, DeepLinkRejection.unknownHost);
      // 核心红线：措辞必须是「拒绝」，静默忽略等于吞掉用户意图
      expect(decision.rejectMessage, contains('已拒绝'));
      expect(decision.rejectMessage, isNot(contains('已忽略')));
      // 原因必须可读（不能是空串 / 英文枚举名糊弄用户）
      expect(decision.rejectMessage, contains(DeepLinkRejection.unknownHost.reason));
    });

    test('已删除的 harness://approval/<id> 必须继续被拒（防架构回退）', () {
      for (final url in <String>[
        'harness://approval/abc',
        'harness://approval',
        'harness://approvals/abc',
      ]) {
        final decision = resolveDeepLink(url);
        expect(decision.rejected, isTrue, reason: 'URL=$url');
        expect(decision.rejection, DeepLinkRejection.unknownHost);
      }
    });

    test('session 缺 id → missingId（不构造空 id 意图）', () {
      for (final url in <String>[
        'harness://session',
        'harness://session/',
        'harness://session/   ',
      ]) {
        final decision = resolveDeepLink(url);
        expect(decision.rejected, isTrue, reason: 'URL=$url');
        expect(decision.rejection, DeepLinkRejection.missingId, reason: 'URL=$url');
      }
    });

    test('非 harness scheme → wrongScheme（含 https / javascript / file / intent）', () {
      for (final url in <String>[
        'https://evil.com',
        'javascript:alert(1)',
        'file:///etc/passwd',
        'intent://session/x',
      ]) {
        final decision = resolveDeepLink(url);
        expect(decision.rejected, isTrue, reason: 'URL=$url');
        expect(decision.rejection, DeepLinkRejection.wrongScheme, reason: 'URL=$url');
      }
    });

    test('空串 / 纯空白 → empty', () {
      for (final url in <String>['', '   ', '\n\t']) {
        final decision = resolveDeepLink(url);
        expect(decision.rejected, isTrue);
        expect(decision.rejection, DeepLinkRejection.empty);
        expect(decision.rejectMessage, isNotEmpty);
      }
    });

    test('五种拒绝原因全部有非空可读文案（无「哑巴拒绝」）', () {
      for (final rejection in DeepLinkRejection.values) {
        expect(rejection.reason.trim(), isNotEmpty, reason: rejection.name);
        final message =
            DeepLinkDecision.rejected(rejection).rejectMessage;
        expect(message, contains(rejection.reason), reason: rejection.name);
        expect(message, contains('已拒绝'), reason: rejection.name);
      }
    });
  });

  group('WebViewPage 深链拦截（直达 / 拒绝两条路径都可见）', () {
    testWidgets('已知深链 → 拦截导航并派发意图（不加载页面）', (WidgetTester tester) async {
      final factory = _FakeFactory();
      final captured = <DeepLinkIntent>[];
      await _pump(tester, factory, onDeepLink: captured.add);

      final handler = factory.navigationHandler!;
      // 普通地址放行（不能被深链白名单误伤）
      expect(handler(Uri.parse('http://localhost:8080/sessions')), isTrue);
      expect(captured, isEmpty);

      // session 深链：拦截 + 派发
      expect(handler(Uri.parse('harness://session/sess-42')), isFalse);
      expect(captured.length, 1);
      expect(captured.first.kind, DeepLinkKind.session);
      expect(captured.first.id, 'sess-42');

      // reauth 深链：拦截 + 派发
      expect(handler(Uri.parse('harness://reauth')), isFalse);
      expect(captured.length, 2);
      expect(captured[1].kind, DeepLinkKind.reauth);
      expect(captured[1].id, '');
    });

    testWidgets('未知深链 → 拦截 + onDeepLinkRejected + 用户可见 SnackBar（不静默吞掉）',
        (WidgetTester tester) async {
      final factory = _FakeFactory();
      final rejected = <DeepLinkRejection>[];
      final accepted = <DeepLinkIntent>[];
      await _pump(
        tester,
        factory,
        onDeepLink: accepted.add,
        onDeepLinkRejected: rejected.add,
      );

      final handler = factory.navigationHandler!;
      expect(handler(Uri.parse('harness://unknown/x')), isFalse);
      await tester.pump(); // flush SnackBar 插入

      // ① 拒绝原因被记录（可观测，不是静默）
      expect(rejected, <DeepLinkRejection>[DeepLinkRejection.unknownHost]);
      // ② 绝不能走「已接受」通道
      expect(accepted, isEmpty);
      // ③ 用户看得见：SnackBar 文案含原因 + 「已拒绝」
      expect(
        find.textContaining(DeepLinkRejection.unknownHost.reason),
        findsOneWidget,
      );
      expect(find.textContaining('已拒绝'), findsOneWidget);
      // ④ 否定断言：旧文案「已忽略」必须消失（这是静默吞链的标志）
      expect(find.textContaining('已忽略'), findsNothing);
    });

    testWidgets('无回调注入时未知深链同样给出可见提示（默认路径不哑巴）',
        (WidgetTester tester) async {
      final factory = _FakeFactory();
      await _pump(tester, factory);

      final handler = factory.navigationHandler!;
      expect(handler(Uri.parse('harness://approval/abc')), isFalse);
      await tester.pump();

      expect(find.textContaining('已拒绝'), findsOneWidget);
      expect(find.textContaining(DeepLinkRejection.unknownHost.reason),
          findsOneWidget);
    });

    testWidgets('缺 id 的 session 深链被拒并给出专属原因', (WidgetTester tester) async {
      final factory = _FakeFactory();
      final rejected = <DeepLinkRejection>[];
      await _pump(tester, factory, onDeepLinkRejected: rejected.add);

      expect(factory.navigationHandler!(Uri.parse('harness://session')), isFalse);
      await tester.pump();

      expect(rejected, <DeepLinkRejection>[DeepLinkRejection.missingId]);
      expect(
        find.textContaining(DeepLinkRejection.missingId.reason),
        findsOneWidget,
      );
    });
  });

  group('深链不得绕过首屏门禁（交叉复核 routing 约束）', () {
    test('身份链路页绝不在 secondaryPages（深链无法借道进入 setup/pairing/login）', () {
      // 与 routing_test.dart 同口径复核：M2 改白名单时绝不能顺手放宽这个集合。
      expect(AppRoutes.secondaryPages, contains(AppRoutes.webview));
      expect(AppRoutes.secondaryPages, contains(AppRoutes.account));
      expect(AppRoutes.secondaryPages.length, 2);
      for (final identityPath in <String>[
        AppRoutes.setup,
        AppRoutes.pairing,
        AppRoutes.login,
        AppRoutes.splash,
      ]) {
        expect(AppRoutes.secondaryPages.contains(identityPath), isFalse,
            reason: '$identityPath 属于身份链路，不得被深链/redirect 放行');
      }
    });

    test('白名单只有 session / reauth / settings 三个类型（新增类型必须改白名单与测试）', () {
      expect(DeepLinkKind.values.length, 3);
      expect(
        DeepLinkKind.values.map((DeepLinkKind k) => k.name).toSet(),
        <String>{'session', 'reauth', 'settings'},
      );
    });

    test('harness://settings → settings 意图（契约三：页面浮标回原生设置页）', () {
      final decision = resolveDeepLink('harness://settings');
      expect(decision.accepted, isTrue, reason: decision.rejectMessage);
      expect(decision.intent!.kind, DeepLinkKind.settings);
      expect(decision.intent!.id, isEmpty);
    });
  });
}
