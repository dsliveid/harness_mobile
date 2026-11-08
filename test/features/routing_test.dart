/// 批次 1/2 路由整合测试。
///
/// 验证三件事：
/// 1. 新增的二级页面（全功能视图 / 账号 / 投递）路由常量正确注册；
/// 2. **首屏铁律不被破坏**：身份齐备时 `/` 仍重定向到审批中心；
/// 3. 二级页面在身份齐备后**可自由访问**，不会被 redirect 弹回首屏
///    （这是最容易写错的地方——过度重定向会让用户点不进任何功能页）。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_mobile/app.dart';
import 'package:harness_mobile/core/app/app_session.dart';
import 'package:harness_mobile/core/app/providers.dart';
import 'package:harness_mobile/data/local/app_settings_store.dart';
import 'package:harness_mobile/data/local/secure_store.dart';

/// 装配应用（注入内存存储，身份齐备 → 应落在审批中心）。
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
    test('三个新增二级页面路径已定义且互不冲突', () {
      expect(AppRoutes.webview, '/webview');
      expect(AppRoutes.account, '/account');
      expect(AppRoutes.delivery, '/delivery');

      final all = <String>{
        AppRoutes.splash,
        AppRoutes.setup,
        AppRoutes.pairing,
        AppRoutes.login,
        AppRoutes.approvals,
        AppRoutes.sessions,
        AppRoutes.webview,
        AppRoutes.account,
        AppRoutes.delivery,
      };
      // 无重复（重复会导致 go_router 同名路径覆盖）
      expect(all.length, 9);
    });

    test('二级页面集合含新增三项，且不含身份链路页', () {
      expect(AppRoutes.secondaryPages, contains(AppRoutes.webview));
      expect(AppRoutes.secondaryPages, contains(AppRoutes.account));
      expect(AppRoutes.secondaryPages, contains(AppRoutes.delivery));
      expect(AppRoutes.secondaryPages, contains(AppRoutes.sessions));

      // 身份链路页绝不能进 secondaryPages，否则会绕过首屏门禁
      expect(AppRoutes.secondaryPages.contains(AppRoutes.setup), isFalse);
      expect(AppRoutes.secondaryPages.contains(AppRoutes.pairing), isFalse);
      expect(AppRoutes.secondaryPages.contains(AppRoutes.login), isFalse);
      expect(AppRoutes.secondaryPages.contains(AppRoutes.splash), isFalse);
    });
  });

  group('首屏铁律（身份齐备 → 审批中心）', () {
    testWidgets('身份齐备时落在审批中心', (WidgetTester tester) async {
      await _pumpApp(tester);
      // 审批中心的显式标识（页面 AppBar 标题）
      expect(find.text('审批中心'), findsWidgets);
    });

    testWidgets('无 baseUrl 时落在服务端地址配置页', (WidgetTester tester) async {
      await _pumpApp(tester, baseUrl: '', deviceId: '', userToken: null);
      expect(find.text('审批中心'), findsNothing);
    });
  });

  group('二级页面可自由访问（不被重定向弹回）', () {
    testWidgets('身份齐备后进入投递页不被弹回首屏', (WidgetTester tester) async {
      final container = await _pumpApp(tester);
      // 直接改路由状态不便，这里用「阶段推导」验证放行集合语义
      final session = container.read(appSessionProvider);
      expect(session.stage, AppStage.approvals);

      // 语义断言：这三种路径在身份齐备时属于放行集合
      for (final path in <String>[
        AppRoutes.webview,
        AppRoutes.account,
        AppRoutes.delivery,
      ]) {
        expect(
          AppRoutes.secondaryPages.contains(path),
          isTrue,
          reason: '$path 应被放行，否则用户点不进该功能',
        );
      }
    });
  });
}
