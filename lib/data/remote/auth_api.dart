/// 认证 API（对齐服务端 `internal/api/auth_handler.go:65-106`）。
///
/// 契约要点（已核实源码，勿改）：
/// - `POST /api/v1/auth/login`  请求 `{username, password}`（**免鉴权**）
///   响应 `{user:{id,username,display_name,role}, token:"..."}`
/// - `GET  /api/v1/auth/me`     响应**直接是 User 对象**（不包 `user` 字段，见
///   `auth_handler.go:94-95`）；为兼容旧版/网关包装，本层同时接受 `{user:{...}}` 形态
/// - `POST /api/v1/auth/logout` 204 空响应（幂等）
///
/// ⚠️ **单令牌模型**：服务端无 refresh 端点，故本层只落一个 user token；
/// 401 由上层引导重新登录，不做静默刷新。令牌绝不打印（红线 R3）。
library;

import '../../core/error/app_error.dart';
import '../local/secure_store.dart';
import 'http_client.dart';

/// 登录用户视图（服务端 `authUser`，`auth_handler.go:52-60`）。
class AuthUser {
  const AuthUser({
    required this.id,
    required this.username,
    required this.displayName,
    required this.role,
  });

  factory AuthUser.fromJson(Map<String, dynamic> json) => AuthUser(
        id: _stringOf(json['id']),
        username: _stringOf(json['username']),
        displayName: _stringOf(json['display_name']),
        role: _stringOf(json['role']),
      );

  final String id;
  final String username;
  final String displayName;
  final String role;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'username': username,
        'display_name': displayName,
        'role': role,
      };

  @override
  String toString() => 'AuthUser($username, role=$role)';
}

/// 认证 API。
class AuthApi {
  AuthApi({required ApiClient client, required SecureStore store})
      : _client = client,
        _store = store;

  final ApiClient _client;
  final SecureStore _store;

  /// 表单登录。成功后把**单令牌**写入 [SecureStore] 并返回用户信息。
  Future<AuthUser> login({
    required String username,
    required String password,
  }) async {
    final data = await _client.post<Map<String, dynamic>>(
      '/api/v1/auth/login',
      // 请求体键集合必须恰为 {username,password}（服务端 DisallowUnknownFields）
      body: <String, dynamic>{'username': username, 'password': password},
      options: ApiClient.skipAuth(),
      parse: mapOf,
    );

    final token = data['token'];
    if (token is! String || token.isEmpty) {
      throw const AppError(
        code: ErrorCode.unauthorized,
        message: '登录成功但服务端未返回令牌',
      );
    }
    await _store.setUserToken(token);
    return AuthUser.fromJson(_userPayload(data));
  }

  /// 首屏静默探测当前用户（避免闪登录页）。
  ///
  /// 兼容两种响应形态：直接 User 对象（当前服务端契约）与 `{user:{...}}`。
  Future<AuthUser> me() async {
    final data = await _client.get<Map<String, dynamic>>(
      '/api/v1/auth/me',
      parse: mapOf,
    );
    return AuthUser.fromJson(_userPayload(data));
  }

  /// 登出。无论服务端是否成功，本地令牌一律清除（用户意图是「我下线了」）。
  Future<void> logout() async {
    try {
      // 服务端返回 204 空响应，这里只关心状态码是否 2xx
      await _client.post<Map<String, dynamic>>(
        '/api/v1/auth/logout',
        parse: mapOf,
      );
    } finally {
      await _store.deleteUserToken();
    }
  }
}

/// 取用户对象：优先 `{user:{...}}`，否则视为直接 User 对象。
Map<String, dynamic> _userPayload(Map<String, dynamic> data) {
  final nested = data['user'];
  if (nested is Map<String, dynamic>) return nested;
  return data;
}

String _stringOf(Object? value) => value is String ? value : '';
