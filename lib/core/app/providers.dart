/// 应用依赖注入（Riverpod 2.x Provider 图）。
///
/// 只承载「全局单例」：安全存储、配置存储、API 工厂、会话状态。
/// 页面内的列表/加载态用各自 StatefulWidget 局部状态管理，避免为一次性数据
/// 造 AsyncNotifier 反而增加生命周期复杂度。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/local/app_settings_store.dart';
import '../../data/local/secure_store.dart';
import '../../data/remote/webview_cookie_sink.dart';
import '../../data/remote/webview_ticket_api.dart';
import '../../data/ws/device_connection.dart';
import '../../data/ws/websocket_device_connection.dart';
import 'api_services.dart';
import 'app_session.dart';
import 'device_ws_controller.dart';

/// 安全存储（令牌，红线 R3）。
final Provider<SecureStore> secureStoreProvider = Provider<SecureStore>(
  (Ref ref) => FlutterSecureStore(),
);

/// 配置存储（服务端地址 + 设备身份）。
final Provider<SettingsStore> settingsStoreProvider = Provider<SettingsStore>(
  (Ref ref) => SecureSettingsStore(),
);

/// API 工厂（按 baseUrl 缓存实例）。
final Provider<ApiFactory> apiFactoryProvider = Provider<ApiFactory>(
  (Ref ref) => ApiFactory(store: ref.watch(secureStoreProvider)),
);

/// 应用级会话状态（首屏门禁事实来源）。
final Provider<AppSession> appSessionProvider = Provider<AppSession>(
  (Ref ref) {
    final session = AppSession(
      settings: ref.watch(settingsStoreProvider),
      tokens: ref.watch(secureStoreProvider),
    );
    ref.onDispose(session.dispose);
    return session;
  },
);

/// 取「当前 baseUrl 绑定」的 API 集合。
///
/// ⚠️ 刻意做成**函数**而不是 Provider：`AppSession` 是 ChangeNotifier 而非
/// Riverpod 的 AsyncNotifier，baseUrl 变更不会让普通 Provider 失效 —— 写成
/// Provider 会把首次算出的 client 永久缓存，用户改地址后仍打旧服务器。
/// [ApiFactory] 内部按 baseUrl 做缓存，所以这里反复调用不会新建 Dio。
///
/// 未配置地址（或地址非法）时返回 null，调用方据此展示「请先配置服务端」。
ApiServices? servicesOf(WidgetRef ref) {
  final baseUrl = ref.watch(appSessionProvider).baseUrl;
  if (baseUrl.isEmpty) return null;
  return ref.watch(apiFactoryProvider).forBaseUrl(baseUrl);
}

/// WebView 会话 Cookie 写入端口（方案 B 降级路径，架构文档 §4.2）。
///
/// 抽成 Provider 的理由：真实实现依赖 `flutter_inappwebview` 平台插件
/// （`CookieManager`），`flutter test` 的 Dart VM 里不可用；
/// 测试通过 override 注入假实现来断言「Cookie 值必须只进 Cookie jar、
/// 绝不能出现在 URL / 日志里」。
final Provider<WebViewCookieSink> webViewCookieSinkProvider =
    Provider<WebViewCookieSink>((Ref ref) => const PlatformWebViewCookieSink());

/// 设备长连接工厂（**仅供测试**覆盖；生产用 [WebSocketDeviceConnection]）。
final Provider<DeviceConnectionFactory> deviceConnectionFactoryProvider =
    Provider<DeviceConnectionFactory>(
  (Ref ref) =>
      (Uri endpoint) => WebSocketDeviceConnection(endpoint),
);

/// 设备长连接控制器（App 级单例）。
///
/// ## 为什么需要这一层（而不直接把 `DeviceWsClient` 放 Provider）
/// `DeviceWsClient` 的 `deviceToken` 是**构造期**参数（会被编进 endpoint 的
/// `?token=`），而令牌存在 Keychain 里必须 `await` 读取。Riverpod 的普通
/// `Provider` 是同步的，直接在里面 await 会把整条链路异步化
/// （变成 `FutureProvider` → 每个页面每次 build 都要处理 loading 态）。
///
/// 因此这里引入一个 `ChangeNotifier` 作为中介：
/// - Provider 只负责同步构造控制器（不含令牌读取）；
/// - 控制器内部在 `start()` 时**异步**读令牌、构造真实 client、启动连接；
/// - UI 订阅本控制器即可拿到状态、并可在 `initState` 中 attach 生命周期桥。
///
/// ## 生命周期铁律（2026-11 用户决策）
/// - **登出（`signOut`）不断开**：WS 绑定「这台设备被授权接入」，与
///   「当前登录的是谁」正交。登出只清 user_token，device_token 仍在，
///   连接继续跑（服务端据此仍能看到本设备在线）。
/// - **解绑（`resetPairing`）必须断开**：device_token 已被 `clearAll()` 抹掉，
///   继续重连只会持续 401 打满日志。由会话层显式调 [DeviceWsController.stop]。
final ChangeNotifierProvider<DeviceWsController> deviceWsControllerProvider =
    ChangeNotifierProvider<DeviceWsController>((Ref ref) {
  final controller = DeviceWsController(
    store: ref.watch(secureStoreProvider),
    factory: ref.watch(deviceConnectionFactoryProvider),
    session: ref.watch(appSessionProvider),
  );
  // ⚠️ ChangeNotifierProvider 已接管 dispose，**不要**再写
  // `ref.onDispose(controller.dispose)`（会双 dispose 并抛
  // `ChangeNotifier was used after being disposed`）。
  return controller;
});

