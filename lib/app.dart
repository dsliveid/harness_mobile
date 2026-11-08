/// 应用根组件 + 路由表（go_router）。
///
/// **首屏铁律**：身份齐备时首屏**必须**是审批中心（架构文档 §0.1 / §6.1）。
/// 启动判定链（[AppSession.stage] 为唯一事实来源）：
/// ```
/// 无 baseUrl     → /setup     服务端地址配置
/// 有地址无 device → /pairing   配对码
/// 已配对未登录    → /login     账号登录
/// 二者齐全        → /approvals 审批中心（首屏）
/// ```
///
/// 实现要点：`redirect` 直接读 [AppSession.stage] 推导目标路径，
/// 并把「用户已在当前阶段页」判掉，避免自我重定向死循环。
/// `refreshListenable` 绑到 [AppSession]（ChangeNotifier），
/// 阶段一变 go_router 自动重算 redirect —— 不需要页面自己 push。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'core/app/app_session.dart';
import 'core/app/providers.dart';
import 'features/approval/approval_center_page.dart';
import 'features/auth/login_page.dart';
import 'features/delivery/delivery_page.dart';
import 'features/pairing/pairing_page.dart';
import 'features/session/session_list_page.dart';
import 'features/session/session_messages_page.dart';
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
        // 允许从身份链路上的任意页自由进入设置页（改地址 / 解绑）
        if (location == AppRoutes.setup && target != AppRoutes.setup) return null;

        // 身份齐备后，允许在二级功能页之间自由浏览：
        // 首屏门禁只约束**入口**（必须落在审批中心），不限制用户主动进入
        // 会话 / 全功能视图 / 账号 / 投递，否则 redirect 会把用户反复弹回首屏。
        if (target == AppRoutes.approvals) {
          if (location == AppRoutes.approvals) return null;
          if (AppRoutes.secondaryPages.contains(location)) return null;
          if (location.startsWith('${AppRoutes.sessions}/')) return null;
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
        GoRoute(
          path: AppRoutes.login,
          builder: (BuildContext context, GoRouterState state) =>
              const LoginPage(),
        ),
        GoRoute(
          path: AppRoutes.approvals,
          builder: (BuildContext context, GoRouterState state) =>
              const ApprovalCenterPage(),
        ),
        GoRoute(
          path: AppRoutes.sessions,
          builder: (BuildContext context, GoRouterState state) =>
              const SessionListPage(),
        ),
        GoRoute(
          path: '/sessions/:sid',
          builder: (BuildContext context, GoRouterState state) =>
              SessionMessagesPage(
            sessionId: state.pathParameters['sid'] ?? '',
          ),
        ),
        // —— 批次 1：全功能视图（WebView 承载服务端 web/dist）——
        // 低频深水区（项目/工作区/工具市场等）不在原生重做，直接复用 Web UI。
        GoRoute(
          path: AppRoutes.webview,
          builder: (BuildContext context, GoRouterState state) =>
              const WebViewPage(),
        ),
        // —— 批次 1：账号页（含解绑 / 登出 / 注销降级指引）——
        GoRoute(
          path: AppRoutes.account,
          builder: (BuildContext context, GoRouterState state) =>
              const AccountPage(),
        ),
        // —— 批次 2：投递（相册/相机 → base64 内联交给 Agent）——
        GoRoute(
          path: AppRoutes.delivery,
          builder: (BuildContext context, GoRouterState state) =>
              const DeliveryPage(),
        ),
      ],
    );
    // 首次装配：读安全存储 + 配置，决定落在哪个阶段（幂等，重复调用无副作用）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _session.load();
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
