/// 应用根组件 + 路由表（go_router）。
///
/// **首屏铁律**：身份齐备时首屏**必须**是全功能视图（WebView 主体，
/// 架构文档 §3.2 / §6.1 决策 2）。
/// 启动判定链（[AppSession.stage] 为唯一事实来源）：
/// ```
/// 无 baseUrl     → /setup     服务端地址配置
/// 有地址无 device → /pairing   配对码
/// 已配对未登录    → /login     账号登录（**只在原生**，WebView 内无登录表单）
/// 二者齐全        → /webview   全功能视图（首屏）
/// ```
///
/// 实现要点：`redirect` 直接读 [AppSession.stage] 推导目标路径，
/// 并把「用户已在当前阶段页」判掉，避免自我重定向死循环。
/// `refreshListenable` 绑到 [AppSession]（ChangeNotifier），
/// 阶段一变 go_router 自动重算 redirect —— 不需要页面自己 push。
///
/// 批次 C：审批中心 / 会话列表 / 会话消息 / 投递四个页面已删除，
/// 对应路由一并移除（深链 `harness://session/<sid>` 改为在 WebView 内定位）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'core/app/app_session.dart';
import 'core/app/providers.dart';
import 'features/auth/login_page.dart';
import 'features/pairing/pairing_page.dart';
import 'features/settings/account_page.dart';
import 'features/settings/setup_page.dart';
import 'features/webview/webview_page.dart';

class HarnessMobileApp extends ConsumerStatefulWidget {
  const HarnessMobileApp({super.key});

  @override
  ConsumerState<HarnessMobileApp> createState() => _HarnessMobileAppState();
}

class _HarnessMobileAppState extends ConsumerState<HarnessMobileApp> {
  late final AppSession _session;
  late final GoRouter _router;

  @override
  void initState() {
    super.initState();
    _session = ref.read(appSessionProvider);
    _router = GoRouter(
      initialLocation: AppRoutes.splash,
      // 阶段变化（配对/登录/登出）→ 自动重算 redirect
      refreshListenable: _session,
      redirect: (BuildContext context, GoRouterState state) {
        final location = state.matchedLocation;
        if (!_session.loaded) {
          // 尚未装配完成：停在 splash，避免闪一下错误的阶段页
          return location == AppRoutes.splash ? null : AppRoutes.splash;
        }
        final target = pathOfStage(_session.stage);
        if (location == target) return null;
        // 允许从身份链路上的任意页自由进入设置页（改地址 / 解绑）：
        // 已配对用户 `context.push('/setup')` 时阶段仍是 pairing/login/webview，
        // 若不在这里放行，redirect 会立刻把他弹回，设置页根本打不开。
        //
        // 🔴 这行的语义边界（勿擅改，真机实测踩过）：
        //   它只负责「允许**停留在** /setup」，**不负责**「让用户离开 /setup」。
        //   正因为这里 return null 会把 redirect 的自动跳转也一并吞掉，
        //   保存地址成功后的前进必须由 SetupPage 自己显式导航
        //   （见 setup_page.dart 的 `_continueAfterSave`）。
        //   若未来删掉这一行，表现为「从 WebView 点设置被瞬间弹回」；
        //   若未来把导航也从 SetupPage 删掉，表现为「保存并继续没有反应」。
        if (location == AppRoutes.setup && target != AppRoutes.setup) return null;

        // 身份齐备后，允许在二级功能页之间自由浏览：
        // 首屏门禁只约束**入口**（必须落在审批中心），不限制用户主动进入
        // 会话 / 全功能视图 / 账号 / 投递，否则 redirect 会把用户反复弹回首屏。
        if (target == AppRoutes.webview) {
          if (location == AppRoutes.webview) return null;
          if (AppRoutes.secondaryPages.contains(location)) return null;
        }
        return target;
      },
      routes: <RouteBase>[
        GoRoute(
          path: AppRoutes.splash,
          builder: (BuildContext context, GoRouterState state) =>
              const _SplashPage(),
        ),
        GoRoute(
          path: AppRoutes.setup,
          builder: (BuildContext context, GoRouterState state) =>
              const SetupPage(),
        ),
        GoRoute(
          path: AppRoutes.pairing,
          builder: (BuildContext context, GoRouterState state) =>
              const PairingPage(),
        ),
        // —— 登录只在原生（§6.1 决策 2）：WebView 内不提供登录表单 ——
        GoRoute(
          path: AppRoutes.login,
          builder: (BuildContext context, GoRouterState state) =>
              const LoginPage(),
        ),
        // —— 首屏：全功能视图（WebView 承载服务端 web/dist）——
        // 会话/审批/投递等长尾功能全部由 Web UI 承担，原生不再重做。
        GoRoute(
          path: AppRoutes.webview,
          builder: (BuildContext context, GoRouterState state) =>
              const WebViewPage(),
        ),
        // —— 账号页（含解绑 / 登出 / 注销降级指引）——
        GoRoute(
          path: AppRoutes.account,
          builder: (BuildContext context, GoRouterState state) =>
              const AccountPage(),
        ),
      ],
    );
    // 首次装配：读安全存储 + 配置，决定落在哪个阶段（幂等，重复调用无副作用）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _session.load().then((_) {
        if (!mounted) return;
        // 装配完成后启动设备长连接（App 级资源，与页面无关）。
        //
        // 放在 load() 之后是必须的：deviceWsController.start() 依赖
        // `session.baseUrl` 与 `session.deviceId`（由 load 填充），
        // 提前调用会因两者为空而直接返回 false，永远连不上。
        //
        // 失败（未配置/未配对/无 device_token）时静默——那是正常状态，
        // 不是错误；状态机保持 disconnected，UI 展示「未连接」。
        ref.read(deviceWsControllerProvider).start().catchError((Object _) => false);
      });
    });
  }

  @override
  void dispose() {
    _router.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'harness',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF2F6FED)),
        useMaterial3: true,
      ),
      routerConfig: _router,
    );
  }
}

/// 启动页（装配完成前的短暂占位）。
class _SplashPage extends StatelessWidget {
  const _SplashPage();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Icon(
              Icons.verified_user_outlined,
              size: 56,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(height: 16),
            const SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2.5),
            ),
          ],
        ),
      ),
    );
  }
}
