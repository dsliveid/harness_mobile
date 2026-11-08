/// 应用级会话状态（首屏门禁的唯一事实来源）。
///
/// 启动判定链（架构文档 §5.1）：
/// ```
/// 无 baseUrl           → 服务端地址配置页（setup）
/// 有地址但无 device    → 配对页（pairing）
/// 已配对但未登录        → 登录页（login）
/// 二者齐全             → 审批中心（approvals，首屏铁律）
/// ```
///
/// 令牌本身**永远**只存在 `SecureStore`（红线 R3），本类只持有「是否已登录」的
/// 布尔视图，绝不缓存 token 明文。
library;

import 'package:flutter/foundation.dart';

import '../../core/config/base_url.dart';
import '../../data/local/app_settings_store.dart';
import '../../data/local/secure_store.dart';

/// 首屏阶段。
enum AppStage {
  /// 尚未配置服务端地址。
  setup,

  /// 已配置地址，未完成设备配对。
  pairing,

  /// 已配对，未登录账号。
  login,

  /// 身份齐备 → 审批中心。
  approvals,
}

/// 纯函数：由三个事实推导首屏阶段（便于无副订单测）。
AppStage resolveStage({
  required String baseUrl,
  required bool paired,
  required bool signedIn,
}) {
  if (baseUrl.isEmpty) return AppStage.setup;
  if (!paired) return AppStage.pairing;
  if (!signedIn) return AppStage.login;
  return AppStage.approvals;
}

/// 阶段对应的路由路径。
String pathOfStage(AppStage stage) {
  switch (stage) {
    case AppStage.setup:
      return AppRoutes.setup;
    case AppStage.pairing:
      return AppRoutes.pairing;
    case AppStage.login:
      return AppRoutes.login;
    case AppStage.approvals:
      return AppRoutes.approvals;
  }
}

/// 路由路径常量（go_router 与 redirect 共用，避免字符串散落）。
abstract final class AppRoutes {
  static const String splash = '/';
  static const String setup = '/setup';
  static const String pairing = '/pairing';
  static const String login = '/login';
  static const String approvals = '/approvals';
  static const String sessions = '/sessions';

  /// 全功能视图（WebView 承载服务端 `web/dist`）。
  static const String webview = '/webview';

  /// 账号页（解绑 / 登出 / 注销降级指引）。
  static const String account = '/account';

  /// 投递页（相册/相机 → base64 内联）。
  static const String delivery = '/delivery';

  /// 会话消息流：`/sessions/<sid>`。
  static String sessionMessages(String sessionId) => '/sessions/$sessionId';

  /// 允许在「已进入审批中心」后自由访问的二级页面。
  ///
  /// 首屏门禁只约束**入口**，不限制用户从审批中心主动进入这些功能页，
  /// 否则 redirect 会把用户反复弹回首屏。
  static const Set<String> secondaryPages = {
    sessions,
    webview,
    account,
    delivery,
  };
}

/// 应用级会话状态。
class AppSession extends ChangeNotifier {
  AppSession({required SettingsStore settings, required SecureStore tokens})
      : _settings = settings,
        _tokens = tokens;

  final SettingsStore _settings;
  final SecureStore _tokens;

  String _baseUrl = '';
  String _deviceId = '';
  String _deviceName = '';
  bool _signedIn = false;
  bool _loaded = false;

  String get baseUrl => _baseUrl;

  String get deviceId => _deviceId;

  String get deviceName => _deviceName;

  bool get signedIn => _signedIn;

  /// 是否已完成首次装配（避免启动瞬间误判到 setup 页）。
  bool get loaded => _loaded;

  bool get paired => _deviceId.isNotEmpty;

  AppStage get stage => resolveStage(
        baseUrl: _baseUrl,
        paired: paired,
        signedIn: _signedIn,
      );

  /// 从本地存储装配（启动时调用一次）。
  Future<void> load() async {
    final saved = await _settings.load();
    _baseUrl = normalizeBaseUrl(saved.baseUrl);
    _deviceId = saved.deviceId;
    _deviceName = saved.deviceName;
    _signedIn = await _tokens.hasUserToken();
    _loaded = true;
    notifyListeners();
  }

  /// 保存服务端地址（自动归一化；非法地址抛 [ArgumentError]）。
  Future<void> saveBaseUrl(String raw) async {
    final normalized = normalizeBaseUrl(raw);
    if (normalized.isEmpty) {
      throw ArgumentError.value(raw, 'baseUrl', '服务端地址不合法');
    }
    _baseUrl = normalized;
    await _save();
    notifyListeners();
  }

  /// 记录配对结果（device_token 已由 DeviceApi 写入 Keychain，此处只存非机密身份）。
  Future<void> markPaired({
    required String deviceId,
    required String deviceName,
  }) async {
    _deviceId = deviceId;
    _deviceName = deviceName;
    await _save();
    notifyListeners();
  }

  /// 记录登录成功（user_token 已由 AuthApi 写入 Keychain）。
  Future<void> markSignedIn() async {
    _signedIn = true;
    notifyListeners();
  }

  /// 登出：清空用户令牌与本机设备身份视图，回到配对页。
  Future<void> signOut() async {
    await _tokens.clearAll();
    _signedIn = false;
    notifyListeners();
  }

  /// 解绑设备（设备被吊销 / 用户主动重置）。
  Future<void> resetPairing() async {
    await _tokens.clearAll();
    _signedIn = false;
    _deviceId = '';
    await _save();
    notifyListeners();
  }

  Future<void> _save() => _settings.save(
        AppSettings(
          baseUrl: _baseUrl,
          deviceId: _deviceId,
          deviceName: _deviceName,
        ),
      );
}
