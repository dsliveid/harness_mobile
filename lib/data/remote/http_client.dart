/// HTTP 客户端（dio 封装）。
///
/// 职责（**只做传输与错误归一，不含业务**）：
/// - 注入鉴权头（`Authorization: <token>`，服务端单令牌模型）
/// - 服务端错误体归一成 [AppError]
/// - R7：`DisallowUnknownFields` 导致的 400 必须把服务端 message 原样透出
///
/// ⚠️ **无 401 静默刷新**：服务端只发一个 token 且**没有 refresh 端点**
/// （`auth_handler.go:65-84`）。401 直接上抛，由业务层引导重新登录。
library;

import 'package:dio/dio.dart';

import '../../core/error/app_error.dart';
import '../local/secure_store.dart';

/// 令牌提供者（由 SecureStore 注入，便于测试替换）。
class TokenProvider {
  TokenProvider(this._store);

  final SecureStore _store;

  Future<String?> userToken() => _store.getUserToken();

  Future<void> saveUserToken(String token) => _store.setUserToken(token);

  Future<void> clearUserToken() => _store.deleteUserToken();

  Future<String?> deviceToken() => _store.getDeviceToken();

  Future<void> saveDeviceToken(String token) => _store.setDeviceToken(token);

  Future<void> clearDeviceToken() => _store.deleteDeviceToken();
}

/// API 客户端。
class ApiClient {
  ApiClient({
    required String baseUrl,
    required TokenProvider tokens,
    Dio? dio,
  })  : _tokens = tokens,
        _dio = dio ?? Dio() {
    _dio.options = BaseOptions(
      baseUrl: baseUrl,
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 30),
      sendTimeout: const Duration(seconds: 30),
      // 非 2xx 不直接抛，交由 request() 统一归一为 AppError
      validateStatus: (status) => status != null && status < 500,
      headers: {'Accept': 'application/json'},
      // 服务端错误体是 {"error":{...}}，自行解析而不依赖 Dio 的默认异常
      responseType: ResponseType.json,
    );

    _dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          // skipAuth 的请求（登录、配对）不注入令牌
          if (options.extra[skipAuthKey] == true) {
            handler.next(options);
            return;
          }
          final token = await _tokens.userToken();
          if (token != null && token.isNotEmpty) {
            // 服务端只认 Bearer 前缀（middleware.go:240-251 的 bearerToken
            // 要求 "Bearer " 前缀，大小写不敏感）；裸 token 会被判 401。
            options.headers['Authorization'] = 'Bearer $token';
          }
          handler.next(options);
        },
      ),
    );
  }

  /// 免鉴权标记键。
  static const String skipAuthKey = 'skipAuth';

  final Dio _dio;
  final TokenProvider _tokens;

  /// 标记请求免鉴权（登录、配对）。
  static Options skipAuth() => Options(extra: {skipAuthKey: true});

  /// 用**设备令牌**（而非用户令牌）鉴权的请求选项。
  ///
  /// 为什么必须绕开默认注入：默认拦截器注入的是 `user_token`（Keychain 里的
  /// 用户会话），而 `POST /api/v1/devices/session` 是**反向**的 ——
  /// 它要求 `Bearer <device_token>`，且用户令牌打过去会被判 401
  /// （服务端只认装在 devices 表里的那枚令牌）。
  ///
  /// 实现上复用 [skipAuthKey]：拦截器看到该标记就不再注入用户令牌，
  /// 于是这里手工写进 header 的设备令牌成为**唯一**的 Authorization，
  /// 不会出现两个令牌互相覆盖的竞态。
  static Options deviceAuth(String deviceToken) => Options(
        extra: {skipAuthKey: true},
        headers: {'Authorization': 'Bearer $deviceToken'},
      );

  /// 更换 baseUrl（用户切换服务端地址时调用）。
  void setBaseUrl(String baseUrl) {
    _dio.options.baseUrl = baseUrl;
  }

  /// 获取底层 Dio（供 SSE 等特殊场景使用）。
  Dio get dio => _dio;

  /// 发起请求并把结果归一为「成功值或抛 [AppError]」。
  Future<T> request<T>(
    Future<Response<dynamic>> Function() send, {
    T Function(Object? data)? parse,
  }) async {
    try {
      final resp = await send();
      final status = resp.statusCode ?? 0;

      if (status >= 200 && status < 300) {
        final data = resp.data;
        return parse != null ? parse(data) : data as T;
      }

      throw AppError.fromResponseBody(
        _normalizeBody(resp.data),
        statusCode: status,
      );
    } on AppError {
      rethrow;
    } on DioException catch (e) {
      throw _mapDioException(e);
    }
  }

  /// GET 便捷方法。
  Future<T> get<T>(
    String path, {
    Map<String, dynamic>? query,
    T Function(Object? data)? parse,
    Options? options,
  }) =>
      request(
        () => _dio.get<dynamic>(path, queryParameters: query, options: options),
        parse: parse,
      );

  /// POST 便捷方法。
  Future<T> post<T>(
    String path, {
    Object? body,
    T Function(Object? data)? parse,
    Options? options,
  }) =>
      request(
        () => _dio.post<dynamic>(path, data: body, options: options),
        parse: parse,
      );

  /// DELETE 便捷方法。
  Future<T> delete<T>(
    String path, {
    T Function(Object? data)? parse,
    Options? options,
  }) =>
      request(
        () => _dio.delete<dynamic>(path, options: options),
        parse: parse,
      );

  /// 把 DioException 归一为 AppError（**必须穷举所有枚举值**）。
  AppError _mapDioException(DioException e) {
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.transformTimeout:
        return AppError.network('请求超时，请检查网络后重试');
      case DioExceptionType.connectionError:
        return AppError.network('无法连接服务端，请确认地址与网络');
      case DioExceptionType.badCertificate:
        return AppError.network('服务端证书校验失败');
      case DioExceptionType.cancel:
        return AppError.local('cancelled', '请求已取消');
      case DioExceptionType.badResponse:
        final status = e.response?.statusCode ?? 0;
        return AppError.fromResponseBody(
          _normalizeBody(e.response?.data),
          statusCode: status,
        );
      case DioExceptionType.unknown:
        return AppError.network('网络异常：${e.message ?? '未知原因'}');
    }
  }

  /// Dio 可能把 JSON 解析成 Map 或返回原始字符串，这里统一成 Map。
  Object? _normalizeBody(Object? data) {
    if (data == null) return null;
    if (data is Map<String, dynamic>) return data;
    // 反代返回的 HTML 错误页等无法结构化解析，交由 fromResponseBody 兜底
    return null;
  }
}

/// 便捷：从响应中取出 `items` 数组（服务端列表端点统一形态）。
List<Map<String, dynamic>> itemsOf(Object? data) {
  if (data is Map<String, dynamic>) {
    final items = data['items'];
    if (items is List) {
      return items.whereType<Map<String, dynamic>>().toList();
    }
  }
  return const [];
}

/// 便捷：从响应中取出 Map（非 Map 时返回空 map）。
Map<String, dynamic> mapOf(Object? data) =>
    data is Map<String, dynamic> ? data : const {};
