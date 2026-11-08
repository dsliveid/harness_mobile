/// 安全存储（红线 R3：令牌只存 Keychain / Android Keystore）。
///
/// ⚠️ **契约修正（v1.1）**：服务端是**单令牌**模型，不是 access+refresh 双令牌。
/// 依据 `internal/api/auth_handler.go:65-84`：
///   - `POST /api/v1/auth/login` 请求 `{username, password}`
///   - 返回 `{user:{id,username,display_name,role}, token:"..."}`
///   - **不存在** refresh 端点；HTTP 会话 Cookie 只是同一 token 的另一种载体
/// 因此本层只存一个 user token；401 时直接引导重新登录，不做静默刷新。
library;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// 安全存储抽象。
abstract class SecureStore {
  /// 设备令牌（配对后获得，仅本机持有）。
  Future<void> setDeviceToken(String token);
  Future<String?> getDeviceToken();
  Future<void> deleteDeviceToken();

  /// 用户令牌（登录后获得，**单令牌**）。
  Future<void> setUserToken(String token);
  Future<String?> getUserToken();
  Future<void> deleteUserToken();

  /// 用户令牌是否存在（判断是否需要登录页）。
  Future<bool> hasUserToken();

  /// 清空全部（登出 / 解绑设备时调用）。
  Future<void> clearAll();
}

/// 令牌在日志中的安全表示（红线 R3：绝不打印明文）。
///
/// 长度 ≤ 8 时整体打码；否则保留首 4 + 尾 2。
String maskToken(String? token) {
  if (token == null || token.isEmpty) return '<empty>';
  if (token.length <= 8) return '***';
  return '${token.substring(0, 4)}***${token.substring(token.length - 2)}';
}

/// 存储键（集中定义，避免散落字符串拼写错误）。
abstract final class SecureKeys {
  static const String deviceToken = 'harness.device_token';
  static const String userToken = 'harness.user_token';
}

/// 基于 `flutter_secure_storage` 的生产实现。
///
/// - iOS：Keychain（`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`）
/// - Android：EncryptedSharedPreferences（由 Keystore 派生密钥加密）
class FlutterSecureStore implements SecureStore {
  FlutterSecureStore({FlutterSecureStorage? storage})
      : _storage = storage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(encryptedSharedPreferences: true),
              iOptions: IOSOptions(
                accessibility: KeychainAccessibility.first_unlock_this_device,
              ),
            );

  final FlutterSecureStorage _storage;

  @override
  Future<void> setDeviceToken(String token) =>
      _storage.write(key: SecureKeys.deviceToken, value: token);

  @override
  Future<String?> getDeviceToken() =>
      _storage.read(key: SecureKeys.deviceToken);

  @override
  Future<void> deleteDeviceToken() =>
      _storage.delete(key: SecureKeys.deviceToken);

  @override
  Future<void> setUserToken(String token) =>
      _storage.write(key: SecureKeys.userToken, value: token);

  @override
  Future<String?> getUserToken() => _storage.read(key: SecureKeys.userToken);

  @override
  Future<void> deleteUserToken() =>
      _storage.delete(key: SecureKeys.userToken);

  @override
  Future<bool> hasUserToken() async {
    final t = await getUserToken();
    return t != null && t.isNotEmpty;
  }

  @override
  Future<void> clearAll() async {
    await _storage.delete(key: SecureKeys.deviceToken);
    await _storage.delete(key: SecureKeys.userToken);
  }
}

/// 内存实现（测试与 CI 用，**绝不用于生产**）。
///
/// 通过 [clearedCount] 可断言「登出时确实清空了全部凭据」。
class InMemorySecureStore implements SecureStore {
  final Map<String, String> _data = {};

  /// `clearAll` 被调用次数（测试断言用）。
  int clearedCount = 0;

  /// 当前存了哪些键（测试断言「没有多余持久化」用）。
  Set<String> get keys => _data.keys.toSet();

  @override
  Future<void> setDeviceToken(String token) async {
    _data[SecureKeys.deviceToken] = token;
  }

  @override
  Future<String?> getDeviceToken() async => _data[SecureKeys.deviceToken];

  @override
  Future<void> deleteDeviceToken() async {
    _data.remove(SecureKeys.deviceToken);
  }

  @override
  Future<void> setUserToken(String token) async {
    _data[SecureKeys.userToken] = token;
  }

  @override
  Future<String?> getUserToken() async => _data[SecureKeys.userToken];

  @override
  Future<void> deleteUserToken() async {
    _data.remove(SecureKeys.userToken);
  }

  @override
  Future<bool> hasUserToken() async {
    final t = _data[SecureKeys.userToken];
    return t != null && t.isNotEmpty;
  }

  @override
  Future<void> clearAll() async {
    _data.clear();
    clearedCount++;
  }
}
