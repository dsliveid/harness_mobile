/// 依赖装配（服务端地址变化时重建 API 客户端）。
///
/// 因为 [ApiClient] 在构造时就固定了 `baseUrl`（dio BaseOptions），
/// 用户改地址必须换一套实例；这里按 baseUrl 做一层极简缓存，
/// 避免每次 rebuild 都新建 Dio 与拦截器。
///
/// 批次 C 精简：审批 / 会话 / 投递三域的 API 与仓储已整体删除
/// （架构文档 §3.2），这里只保留 认证 / 设备 / WebView 透传 三条链路。
library;

import 'package:dio/dio.dart';

import '../../data/local/secure_store.dart';
import '../../data/remote/auth_api.dart';
import '../../data/remote/device_api.dart';
import '../../data/remote/http_client.dart';
import '../../data/remote/webview_ticket_api.dart';

/// 一套绑定某 baseUrl 的 API 客户端集合。
class ApiServices {
  ApiServices({
    required this.baseUrl,
    required TokenProvider tokens,
    required SecureStore store,
    String platform = 'android',
    String appVersion = '0.1.0',
    Dio? dio,
  })  : client = ApiClient(baseUrl: baseUrl, tokens: tokens, dio: dio),
        _store = store,
        _platform = platform,
        _appVersion = appVersion;

  final String baseUrl;
  final ApiClient client;

  final SecureStore _store;
  final String _platform;
  final String _appVersion;

  late final AuthApi auth = AuthApi(client: client, store: _store);

  late final DeviceApi device = DeviceApi(
    client: client,
    store: _store,
    platform: _platform,
    appVersion: _appVersion,
  );

  /// WebView 认证透传（方案 C ticket 签发 + 方案 B Cookie 注入降级）。
  late final WebViewTicketApi webviewTicket = WebViewTicketApi(
    client: client,
    store: _store,
  );

  /// 探测服务端连通性（设置页「测试连接」按钮用）。
  ///
  /// 端点事实：`GET /healthz` 免鉴权、返回
  /// `{status, version, protocol_version, uptime_s}`（`observ.go:119-135`）。
  /// 走 `client.get` 是为了复用统一的错误归一（连不上 → `AppError(unavailable)`）。
  Future<ServerHealth> probeHealth() => client.get<ServerHealth>(
        '/healthz',
        options: ApiClient.skipAuth(),
        parse: (Object? data) {
          final map = mapOf(data);
          final protocol = map['protocol_version'];
          return ServerHealth(
            status: map['status'] is String ? map['status']! as String : '',
            version: map['version'] is String ? map['version']! as String : '',
            protocolVersion: protocol is num ? protocol.toInt() : null,
          );
        },
      );
}

/// 服务端健康信息（`observ.healthBody`）。
class ServerHealth {
  const ServerHealth({
    required this.status,
    required this.version,
    this.protocolVersion,
  });

  final String status;
  final String version;
  final int? protocolVersion;

  bool get isOk => status == 'ok';
}

/// API 服务工厂（同一 baseUrl 复用同一套实例）。
class ApiFactory {
  ApiFactory({
    required SecureStore store,
    String platform = 'android',
    String appVersion = '0.1.0',
    Dio? dio,
  })  : _store = store,
        _platform = platform,
        _appVersion = appVersion,
        _dio = dio;

  final SecureStore _store;
  final String _platform;
  final String _appVersion;

  /// 可选的 dio 注入（**仅供测试**拦截出网；生产为 null，每个 client 自建）。
  final Dio? _dio;

  final Map<String, ApiServices> _cache = <String, ApiServices>{};

  ApiServices forBaseUrl(String baseUrl) => _cache.putIfAbsent(
        baseUrl,
        () => ApiServices(
          baseUrl: baseUrl,
          tokens: TokenProvider(_store),
          store: _store,
          platform: _platform,
          appVersion: _appVersion,
          dio: _dio,
        ),
      );
}