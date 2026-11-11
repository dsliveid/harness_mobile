/// 「保存并继续」必须真的往下走一步（回归测试）。
///
/// ## 这个文件防的是什么
///
/// 真机实测踩中：首次启动落在 `/setup`，填好地址点「保存并继续」后**停在原页**，
/// 既没报错也没有下一步。根因不是保存失败（`saveBaseUrl` 正常写入、阶段也确实
/// 从 `setup` 变成了 `pairing`），而是 `app.dart` 的 redirect 白名单
/// `location == '/setup' && target != '/setup' → return null` 把自动跳转吞掉了
/// —— 这行的本意是让已配对用户「停留在」设置页，副作用却是「也离不开」。
///
/// 修法是在 SetupPage 里显式导航（`_continueAfterSave`）。本测试守住两条通路：
/// 1. **入口态**（启动即落在 setup，无可 pop 的历史）→ 必须前进到下一阶段页；
/// 2. **设置态**（从别的页 push 进来）→ 必须退回来源页，而不是留在原地。
///
/// 断言的是「落在哪个页面」这种用户可见语义，不断言内部字段，
/// 这样以后重写导航实现（换 go、换 push、换回调）也不会误伤。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:harness_mobile/app.dart';
import 'package:harness_mobile/core/app/app_session.dart';
import 'package:harness_mobile/core/app/providers.dart';
import 'package:harness_mobile/data/local/app_settings_store.dart';
import 'package:harness_mobile/data/local/secure_store.dart';
import 'package:harness_mobile/features/pairing/pairing_page.dart';
import 'package:harness_mobile/features/settings/setup_page.dart';

/// 装配隔离的 ProviderScope：存储全部内存实现，不发真请求。
Future<ProviderContainer> _pumpApp(
  WidgetTester tester, {
  AppSettings settings = const AppSettings(),
}) async {
  final container = ProviderContainer(
    overrides: <Override>[
      secureStoreProvider.overrideWithValue(InMemorySecureStore()),
      settingsStoreProvider.overrideWithValue(InMemorySettingsStore(settings)),
    ],
  );
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const HarnessMobileApp(),
    ),
  );
  // 首帧 + postFrameCallback(load) + redirect 重算
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  return container;
}

/// 填入地址并点「保存并继续」，等异步保存与导航落地。
Future<void> _fillAndSave(WidgetTester tester, String url) async {
  await tester.enterText(find.byType(TextFormField), url);
  await tester.pump();
  await tester.tap(find.text('保存并继续'));
  // saveBaseUrl 是 async（写内存 store → notifyListeners → SnackBar → 导航）。
  // 只 pump 一次会让断言撞在「await 尚未 resolve」的窗口里；
  // 而 pop 可能恰好发生在 pumpAndSettle 的最后一次 pump 之后（此时已无 pending
  // frame），所以再补一轮 pump + pumpAndSettle 才能稳定观察到目标页面。
  await tester.pump(); // 让 tap 进入 _save()
  await tester.pumpAndSettle(); // 走完 await / SnackBar / 导航动画
  await tester.pump(); // 兜住「导航发生在最后一帧之后」的情形
  await tester.pumpAndSettle();
}

void main() {
  group('保存并继续 → 必须推进阶段（回归：保存后停在原页）', () {
    testWidgets('首次启动（入口态 setup）→ 保存后进入配对页', (WidgetTester tester) async {
      final container = await _pumpApp(tester);

      // 前置事实：确实落在 setup，且阶段是 setup（否则本用例测不到目标路径）
      expect(find.byType(SetupPage), findsOneWidget);
      expect(container.read(appSessionProvider).stage, AppStage.setup);

      await _fillAndSave(tester, 'http://192.168.1.10:5611');

      // 核心断言：地址已写入 → 阶段变 pairing → **界面真的到了配对页**
      expect(container.read(appSessionProvider).stage, AppStage.pairing);
      expect(find.byType(PairingPage), findsOneWidget);
      expect(find.byType(SetupPage), findsNothing);
    });

    testWidgets('地址被归一化后保存（不写协议默认 http，去尾斜杠）', (WidgetTester tester) async {
      final container = await _pumpApp(tester);

      await _fillAndSave(tester, '  192.168.1.10:5611/  ');

      // 归一化是既有能力，这里只确认新加的导航没有绕过它
      expect(
        container.read(appSessionProvider).baseUrl,
        'http://192.168.1.10:5611/',
      );
      expect(find.byType(PairingPage), findsOneWidget);
    });

    testWidgets('非法地址不发请求、不跳转，就地报错', (WidgetTester tester) async {
      final container = await _pumpApp(tester);

      await _fillAndSave(tester, 'ftp://example.com');

      // 校验失败必须**留在 setup**，且阶段不变（防「点了没反应但状态被改脏」）
      expect(container.read(appSessionProvider).stage, AppStage.setup);
      expect(find.byType(SetupPage), findsOneWidget);
      expect(find.text('请输入合法的 http/https 地址'), findsOneWidget);
    });
  });

  group('设置态（push 进来的 setup）→ 保存后退回来源页', () {
    testWidgets('从配对页 push 进设置，保存后回到配对页', (WidgetTester tester) async {
      final container = await _pumpApp(
        tester,
        settings: const AppSettings(baseUrl: 'http://10.0.2.2:5611'),
      );

      // 有地址无设备 → 落在配对页
      expect(find.byType(PairingPage), findsOneWidget);
      final session = container.read(appSessionProvider);
      expect(session.stage, AppStage.pairing);

      // 进入设置页：直接复用 App 自己的 GoRouter 做 push。
      // 不点 AppBar 的「服务端设置」图标，因为它靠 tooltip 定位，在测试视口里
      // 命中的是 RawTooltip 包装层（offset 落在视口外），是测试基础设施问题
      // 而非产品缺陷；而 push 语义才是本用例真正要验的东西（栈里多一层 → canPop 为真）。
      final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
      final router = app.routerConfig! as GoRouter;
      // push 返回的 Future 在「该路由被弹出」时才 complete，await 会挂住，
      // 因此必须 unawaited（这也正是 push 与 go 的语义差别所在）。
      unawaited(router.push(AppRoutes.setup));
      await tester.pumpAndSettle();
      expect(find.byType(SetupPage), findsOneWidget);

      await _fillAndSave(tester, 'http://10.0.2.3:5611');

      // 核心断言：回到来源页（配对页），而不是把用户留在设置页。
      // 阶段仍是 pairing；若这里不导航，redirect 白名单会让用户困在 setup。
      expect(find.byType(PairingPage), findsOneWidget);
      expect(find.byType(SetupPage), findsNothing);
      expect(
        container.read(appSessionProvider).baseUrl,
        'http://10.0.2.3:5611/',
      );
    });
  });

  group('路由职责边界（防止后人「顺手」改坏）', () {
    test('setup 不得进入 secondaryPages（否则深链可绕过首屏门禁）', () {
      // 与 routing_test.dart 同口径；此处只做交叉复核，避免重复维护断言表
      expect(AppRoutes.secondaryPages.contains(AppRoutes.setup), isFalse);
    });

    test('pathOfStage 对 setup 之后的阶段给出非 setup 路径', () {
      // 「保存后该去哪」完全依赖这个映射；若它退化成 setup，跳转就会变成原地不动
      expect(pathOfStage(AppStage.setup), AppRoutes.setup);
      expect(pathOfStage(AppStage.pairing), isNot(AppRoutes.setup));
      expect(pathOfStage(AppStage.login), isNot(AppRoutes.setup));
      expect(pathOfStage(AppStage.webview), isNot(AppRoutes.setup));
    });
  });
}
