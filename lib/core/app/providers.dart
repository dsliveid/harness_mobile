/// 应用依赖注入（Riverpod 2.x Provider 图）。
///
/// 只承载「全局单例」：安全存储、配置存储、生物识别闸门、API 工厂、会话状态。
/// 页面内的列表/加载态用各自 StatefulWidget 局部状态管理，避免为一次性数据
/// 造 AsyncNotifier 反而增加生命周期复杂度。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/local/app_settings_store.dart';
import '../../data/local/secure_store.dart';
import 'api_services.dart';
import 'app_session.dart';
import 'biometric_gate.dart';

/// 安全存储（令牌，红线 R3）。
final Provider<SecureStore> secureStoreProvider = Provider<SecureStore>(
  (Ref ref) => FlutterSecureStore(),
);

/// 配置存储（服务端地址 + 设备身份）。
final Provider<SettingsStore> settingsStoreProvider = Provider<SettingsStore>(
  (Ref ref) => SecureSettingsStore(),
);

/// 生物识别闸门（高风险审批前置）。
final Provider<BiometricGate> biometricGateProvider =
    Provider<BiometricGate>((Ref ref) => LocalAuthBiometricGate());

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
