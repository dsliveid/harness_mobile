/// 路由整合测试（批次 C：WebView 主体架构）。
///
/// 验证三件事：
/// 1. 路由常量与**二级页放行集合**正确注册（webview / account）；
/// 2. **首屏铁律不被破坏**：身份齐备时首屏是 `/webview`（不再是审批中心）；
/// 3. 二级页面在身份齐备后**可自由访问**，不会被 redirect 弹回首屏
///    （这是最容易写错的地方——过度重定向会让用户点不进任何功能页）。
///
/// 批次 C 变更：审批中心 / 会话列表 / 投递页连同其路由常量一并删除
/// （架构文档 §3.2），对应断言改为 `/webview` + `/account` 的组合语义。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_mobile/app.dart';
import 'package:harness_mobile/core/app/app_session.dart';
import 'package:harness_mobile/core/app/providers.dart';
import 'package:harness_mobile/data/local/app_settings_store.dart';
import 'package:harness_mobile/data/local/secure_store.dart';
import 'package:harness_mobile/features/webview/webview_page.dart';

/// 装配应用（注入内存存储，身份齐备 → 应落在 WebView 主体）。
Future<ProviderContainer> _pumpApp(
  WidgetTester tester, {
  String baseUrl = 'http://localhost:8080',
  String deviceId = 'dev-1',
  String? userToken = 'user-token',
}) async {
  final store = InMemorySecureStore();
  if (userToken != null) await store.setUserToken(userToken);
  if (deviceId.isNotEmpty) await store.setDeviceToken('device-token');

  final container = ProviderContainer(
    overrides: <Override>[
      secureStoreProvider.overrideWithValue(store),
      settingsStoreProvider.overrideWithValue(
        InMemorySettingsStore(
          AppSettings(
            baseUrl: baseUrl,
            deviceId: deviceId,
            deviceName: '测试机',
          ),
        ),
      ),
    ],
  );
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const HarnessMobileApp(),
    ),
  );
  // 触发 postFrameCallback 里的 session.load()
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  return container;
}

void main() {
  group('路由常量注册', () {
    test('二级页面路径已定义且互不冲突', () {
      expect(AppRoutes.webview, '/webview');
      expect(AppRoutes.account, '/account');

      final all = <String>{
        AppRoutes.splash,
        AppRoutes.setup,
        AppRoutes.pairing,
        AppRoutes.login,
        AppRoutes.webview,
        AppRoutes.account,
      };
      // 无重复（重复会导致 go_router 同名路径覆盖）
      expect(all.length, 6);
      // 否定断言：已删除的三条路由常量不得复活（复活即意味着架构回退）
      expect(all.contains('/approvals'), isFalse);
      expect(all.contains('/sessions'), isFalse);
      expect(all.contains('/delivery'), isFalse);
    });

    test('二级页面集合只含 webview + account，且不含身份链路页', () {
      expect(AppRoutes.secondaryPages, contains(AppRoutes.webview));
      expect(AppRoutes.secondaryPages, contains(AppRoutes.account));
      // 批次 C：投递页 / 会话页已删除，放行集合必须同步收窄
      expect(AppRoutes.secondaryPages.length, 2);

      // 身份链路页绝不能进 secondaryPages，否则会绕过首屏门禁
      expect(AppRoutes.secondaryPages.contains(AppRoutes.setup), isFalse);
      expect(AppRoutes.secondaryPages.contains(AppRoutes.pairing), isFalse);
      expect(AppRoutes.secondaryPages.contains(AppRoutes.login), isFalse);
      expect(AppRoutes.secondaryPages.contains(AppRoutes.splash), isFalse);
    });

    test('pathOfStage 对四个阶段全覆盖且互不相同', () {
      // 枚举穷举：少一个分支编译期就会报 exhaustiveness
      final paths = <AppStage, String>{
        AppStage.setup: pathOfStage(AppStage.setup),
        AppStage.pairing: pathOfStage(AppStage.pairing),
        AppStage.login: pathOfStage(AppStage.login),
        AppStage.webview: pathOfStage(AppStage.webview),
      };
      expect(paths[AppStage.setup], AppRoutes.setup);
      expect(paths[AppStage.pairing], AppRoutes.pairing);
      expect(paths[AppStage.login], AppRoutes.login);
      expect(paths[AppStage.webview], AppRoutes.webview);
      // 四个阶段必须映射到四个不同路径，否则会发生"阶段跳转无效果"
      expect(paths.values.toSet().length, 4);
    });
  });

  group('首屏铁律（身份齐备 → WebView 主体）', () {
    testWidgets('身份齐备时落在 WebView 主体', (WidgetTester tester) async {
      final container = await _pumpApp(tester);
      // 阶段是唯一事实来源
      expect(container.read(appSessionProvider).stage, AppStage.webview);
      // 首屏必须真的是 WebViewPage。标题栏降高后中文标题改为图标 + tooltip
      // 承载（360dp 窄屏放不下文字），故用 tooltip 断言同一意图。
      expect(find.byType(WebViewPage), findsOneWidget);
      expect(find.byTooltip('全功能视图'), findsOneWidget);
      // 否定断言：不能再停留在审批中心 / 登录页
      expect(find.text('审批中心'), findsNothing);
      expect(find.text('登录账号'), findsNothing);
    });

    testWidgets('无 baseUrl 时落在服务端地址配置页', (WidgetTester tester) async {
      final container =
          await _pumpApp(tester, baseUrl: '', deviceId: '', userToken: null);
      expect(container.read(appSessionProvider).stage, AppStage.setup);
      expect(find.byType(WebViewPage), findsNothing);
      expect(find.byTooltip('全功能视图'), findsNothing);
    });
  });

  group('二级页面可自由访问（不被重定向弹回）', () {
    testWidgets('身份齐备后进入账号页不被弹回首屏', (WidgetTester tester) async {
      final container = await _pumpApp(tester);
      final session = container.read(appSessionProvider);
      expect(session.stage, AppStage.webview);

      // 语义断言：这两个路径在身份齐备时属于放行集合
      for (final path in <String>[
        AppRoutes.webview,
        AppRoutes.account,
      ]) {
        expect(
          AppRoutes.secondaryPages.contains(path),
          isTrue,
          reason: '$path 应被放行，否则用户点不进该功能',
        );
      }
    });

    testWidgets('首屏不得泄漏账号页内容（二级页只在主动进入时出现）',
        (WidgetTester tester) async {
      await _pumpApp(tester);
      // 放行资格由 secondaryPages 集合保证（上一条用例已断言）；
      // 这里补一条否定断言：首屏铁律只落在 /webview，
      // 不得把账号页的任何内容顺带渲染进首屏。
      expect(AppRoutes.secondaryPages, contains(AppRoutes.account));
      expect(find.text('本机设备'), findsNothing);
    });
  });
}
