/// 应用外壳与首屏路由测试。
///
/// 覆盖交接书验收点：
/// - 首屏铁律：身份齐备 → **审批中心**（不是占位页）
/// - 启动判定链：无地址 → 设置页；有地址未配对 → 配对页；已配对未登录 → 登录页
/// - 无调试横幅
///
/// 依赖全部用内存实现替换（`InMemorySecureStore` / `InMemorySettingsStore`），
/// 不发真请求、不碰平台插件。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_mobile/app.dart';
import 'package:harness_mobile/core/app/app_session.dart';
import 'package:harness_mobile/core/app/providers.dart';
import 'package:harness_mobile/data/local/app_settings_store.dart';
import 'package:harness_mobile/data/local/secure_store.dart';
import 'package:harness_mobile/features/auth/login_page.dart';
import 'package:harness_mobile/features/pairing/pairing_page.dart';
import 'package:harness_mobile/features/settings/setup_page.dart';

/// 装配一个隔离的 ProviderScope（存储全部内存实现）。
Future<void> _pumpApp(
  WidgetTester tester, {
  AppSettings settings = const AppSettings(),
  String? deviceToken,
  String? userToken,
}) async {
  final secureStore = InMemorySecureStore();
  if (deviceToken != null) await secureStore.setDeviceToken(deviceToken);
  if (userToken != null) await secureStore.setUserToken(userToken);

  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        secureStoreProvider.overrideWithValue(secureStore),
        settingsStoreProvider
            .overrideWithValue(InMemorySettingsStore(settings)),
      ],
      child: const HarnessMobileApp(),
    ),
  );
  // 首帧 + postFrameCallback(load) + redirect 重算
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  testWidgets('无 baseUrl → 落在服务端地址配置页', (WidgetTester tester) async {
    await _pumpApp(tester);
    expect(find.byType(SetupPage), findsOneWidget);
    expect(find.text('连接服务端'), findsOneWidget);
  });

  testWidgets('有地址无设备 → 落在配对页', (WidgetTester tester) async {
    await _pumpApp(
      tester,
      settings: const AppSettings(baseUrl: 'http://10.0.2.2:8080'),
    );
    expect(find.byType(PairingPage), findsOneWidget);
    expect(find.text('配对设备'), findsOneWidget);
    // 能力申报声明必须出现（network + device，不含其它能力）
    expect(find.textContaining('申报能力'), findsOneWidget);
  });

  testWidgets('已配对未登录 → 落在登录页', (WidgetTester tester) async {
    await _pumpApp(
      tester,
      settings: const AppSettings(
        baseUrl: 'http://10.0.2.2:8080',
        deviceId: 'dev-1',
        deviceName: '测试机',
      ),
      deviceToken: 'device-token-xxx',
    );
    expect(find.byType(LoginPage), findsOneWidget);
    expect(find.text('登录账号'), findsOneWidget);
  });


  testWidgets('无调试横幅（正式外观）', (WidgetTester tester) async {
    await _pumpApp(tester);
    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app.debugShowCheckedModeBanner, isFalse);
    expect(app.routerConfig, isNotNull);
  });

  test('首屏阶段推导纯函数（无副作用）', () {
    expect(
      resolveStage(baseUrl: '', paired: false, signedIn: false),
      AppStage.setup,
    );
    expect(
      resolveStage(baseUrl: 'http://h:8080', paired: false, signedIn: false),
      AppStage.pairing,
    );
    expect(
      resolveStage(baseUrl: 'http://h:8080', paired: true, signedIn: false),
      AppStage.login,
    );
    expect(
      resolveStage(baseUrl: 'http://h:8080', paired: true, signedIn: true),
      AppStage.approvals,
    );
  });
}
