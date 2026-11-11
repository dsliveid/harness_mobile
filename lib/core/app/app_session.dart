/// 应用级会话状态（首屏门禁的唯一事实来源）。
///
/// 启动判定链（架构文档 §5.1 / §6.1 决策 2）：
/// ```
/// 无 baseUrl           → 服务端地址配置页（setup）
/// 有地址但无 device    → 配对页（pairing）
/// 已配对但未登录        → 登录页（login）
/// 二者齐全             → 全功能视图（webview，首屏铁律）
/// ```
///
/// 批次 C 变化：身份齐备后的首屏由「审批中心」改为「WebView 主体」
/// （审批中心 / 会话页 / 投递页已整体删除，见架构文档 §3.2）。
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

  /// 身份齐备 → 全功能视图（WebView 主体）。
  webview,
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
  return AppStage.webview;
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
    case AppStage.webview:
      return AppRoutes.webview;
  }
}

/// 路由路径常量（go_router 与 redirect 共用，避免字符串散落）。
abstract final class AppRoutes {
  static const String splash = '/';
  static const String setup = '/setup';
  static const String pairing = '/pairing';
  static const String login = '/login';

  /// 首屏（身份齐备）：全功能视图（WebView 承载服务端 `web/dist`）。
  static const String webview = '/webview';

  /// 账号页（解绑 / 登出 / 注销降级指引）。
  static const String account = '/account';

  /// 允许在「已进入首屏（WebView）」后自由访问的二级页面。
  ///
  /// 首屏门禁只约束**入口**，不限制用户从 WebView 主动进入这些功能页，
  /// 否则 redirect 会把用户反复弹回首屏。
  static const Set<String> secondaryPages = {
    webview,
    account,
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
  ///
  /// baseUrl 走 [resolveStartupBaseUrl]：`--dart-define=BASE_URL=...` 注入值优先于
  /// 本地存储值（脚本 `run.sh --server-url` 的落地链路）。未注入时行为与旧版一致。
  Future<void> load() async {
    final saved = await _settings.load();
    _baseUrl = resolveStartupBaseUrl(
      saved: saved.baseUrl,
      injected: kInjectedBaseUrl,
    );
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

  /// 记录登录成功（user_token 已由 AuthApi / DeviceApi 写入 Keychain）。
  ///
  /// 两条入口共用：表单登录（[AuthApi.login]）与「配对即登录」
  /// （[DeviceApi.pair] 一并下发 user_token）。本方法**不写令牌**，
  /// 只把「已登录」的事实翻成 true，令牌始终只在 `SecureStore`（红线 R3）。
  Future<void> markSignedIn() async {
    _signedIn = true;
    notifyListeners();
  }

  /// 登出：只清**用户令牌**，保留设备令牌与设备绑定视图，回到登录页。
  ///
  /// 🔴 语义铁律（2026-11 修正，勿回退）：
  /// 配对（这台机器被授权接入）与登录（这个人是谁）是**正交**的两件事：
  /// - `device_token` 证明「本机被授权接入」，长期有效，是设备长连接
  ///   （`/api/v1/devices/ws`）的唯一凭据；
  /// - `user_token` 证明「当前登录的是谁」，登出即撤销。
  ///
  /// 因此本方法**只调 `deleteUserToken()`**，绝不再用 `clearAll()`：
  /// 旧实现调 `clearAll()` 会连 `device_token` 一并抹掉，而 [paired] 只读
  /// `_deviceId`（Settings 里的非机密字段），于是产生「UI 说已配对、
  /// Keychain 里没有令牌」的不一致死局 —— 服务端没有任何端点能重新下发
  /// `device_token`（只有消费新配对码的 `POST /devices/pair`），
  /// 用户登出一次就必须回桌面端重新生成配对码，与本文档承诺完全相反。
  ///
  /// 若确实要连设备身份一起清掉（换机 / 设备被吊销），那是
  /// [resetPairing]，不是本方法。
  Future<void> signOut() async {
    await _tokens.deleteUserToken();
    _signedIn = false;
    notifyListeners();
  }

  /// 解绑设备（设备被吊销 / 用户主动重置）。
  ///
  /// 与 [signOut] 的区别：这里**同时**清空设备身份并落盘，[stage] 回到
  /// [AppStage.pairing]；且 `clearAll()` 会一并清掉用户令牌，因此解绑
  /// 必然导致「未登录」—— 这正是账号页确认文案要提示用户的事实。
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
