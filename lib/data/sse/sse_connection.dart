/// SSE 传输层抽象（`GET /api/v1/devices/events` 等 `text/event-stream` 端点）。
///
/// # 为什么 SSE **不**复用 `ApiClient`（Dio）
/// `lib/data/remote/http_client.dart:44-54` 的 `BaseOptions` 是为**短请求**设计的：
///
/// | 选项 | 值 | 对 SSE 的后果 |
/// | --- | --- | --- |
/// | `receiveTimeout` | 30s | 服务端每 15s 一拍心跳，一旦网络抖动 / 1s 合并窗口叠加，
/// 30s 静默就会**假性断连**，且表现为「每半分钟重连一次」的幽灵抖动 |
/// | `validateStatus` | `< 500` | 把 4xx 当成功体交给解析层，SSE 需要的是明确的连接失败 |
/// | `responseType` | `json` | SSE 是**流**，不是一次性 body |
///
/// 靠调用点逐处传 `Options(receiveTimeout: null)` 是在全局配置上凿洞：
/// 每个未来的 SSE 调用点都得记得传，漏一处就复活上述幽灵断连。
/// 因此 SSE 走**独立传输层**，形态与 `lib/data/ws/device_connection.dart`
/// （`DeviceConnection` + `DeviceConnectionFactory`）**逐字同构** ——
/// 同一个项目里两种长连接用同一套可注入范式，读代码的人不需要切换心智模型。
///
/// # 为什么是 `Stream<String>` 而不是 `Stream<List<int>>`
/// 编码分帧必须在**字符**层完成：`\n\n` 分帧、UTF-8 多字节边界都不能在字节层做。
/// 若把 `List<int>` 交给状态机，每个使用方都得自己写一遍 `utf8.decoder`
/// 并在块边界处理半个汉字。故生产实现用 `utf8.decoder`（其内部已正确处理
/// 跨块的多字节序列）完成解码，向上只暴露**文本增量**。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 单条 SSE 连接。一条连接一个实例，**重连由上层新建实例**
/// （同 `DeviceConnection`：传输层不做自愈，否则退避策略不可测）。
abstract class SseConnection {
  /// 建立连接；失败必须抛异常（由状态机转成退避重连）。
  Future<void> connect();

  /// 入站**已解码文本**增量流（未按帧切分，帧切分由 `SseFrameSplitter` 负责）。
  ///
  /// 流结束（`done`）表示连接被对端关闭 / 被服务端慢消费者策略断开；
  /// 流抛错表示网络层失败。两者在状态机里**同等对待**（都走退避重连）。
  Stream<String> get stream;

  /// 关闭连接（幂等）。
  Future<void> close();
}

/// 连接工厂：每次重连都新建一条连接（测试注入假实现的关键接缝）。
///
/// 与 `DeviceConnectionFactory`（只吃 `Uri`）的差异：设备 WS 的令牌可以走
/// `?token=`，而 SSE **必须**走 `Authorization` 请求头（红线 R3：
/// 三条 SSE 流都不接受 URL 携带凭据）。故把请求头显式作为工厂入参，
/// 使「谁提供令牌」与「谁建连接」解耦。
typedef SseConnectionFactory = Future<SseConnection> Function(
  Uri endpoint,
  Map<String, String> headers,
);

/// 设备状态流端点路径（`internal/api/router.go` 的 `GET /api/v1/devices/events`）。
const String deviceEventsPath = '/api/v1/devices/events';

/// 构造 SSE 端点 URI。
///
/// # 鉴权口径（已源码核准，勿改）
/// `internal/api/middleware.go:257 extractToken`：**优先 `Authorization: Bearer`**，
/// 其次会话 Cookie。故原生 Dart 侧直接走 Bearer 头即可建连，
/// **不需要**借道 WebView 的 Cookie jar（`webview_cookie_sink.dart` 是给
/// WebView 内 React 用的，与原生 SSE 无关）。
///
/// 同时遵守红线 R3：令牌**只**进请求头，绝不进 query、绝不进日志。
Uri deviceEventsUri({required Uri baseUrl, String path = deviceEventsPath}) =>
    baseUrl.replace(
      scheme: baseUrl.scheme == 'https' ? 'https' : 'http',
      path: joinSsePath(baseUrl.path, path),
      queryParameters: baseUrl.queryParameters.isEmpty
          ? null
          : Map<String, String>.from(baseUrl.queryParameters),
    );

/// 拼接 URL 路径（避免 `//api` 或丢掉 base 前缀）。
///
/// 与 `device_connection.dart:joinUrlPath` 同一实现：SSE 与 WS 都要拼基址前缀，
/// 各自抄一份必然某天只改一边。
String joinSsePath(String base, String path) {
  final String b = base.endsWith('/') ? base.substring(0, base.length - 1) : base;
  final String p = path.startsWith('/') ? path : '/$path';
  if (b.isEmpty) return p;
  return '$b$p';
}

/// 基于 `dart:io` 的生产实现。
///
/// 只在 io 平台可用（Android / iOS / Windows / macOS / Linux）——
/// 移动端正是 io 平台，Web 端不跑 Dart 代码，故无需 `dart:html` 分支。
class IoHttpSseConnection implements SseConnection {
  IoHttpSseConnection(
    this.endpoint, {
    Map<String, String>? headers,
    Duration connectTimeout = const Duration(seconds: 10),
    HttpClient? client,
  })  : _headers = headers ?? const <String, String>{},
        _connectTimeout = connectTimeout,
        // 每次重连新建 HttpClient：沿用旧实例会复用 OS 层可能已半死的连接池，
        // 表现为「退避重连成功了但一个字节都不来」。
        _client = client ?? HttpClient();

  final Uri endpoint;
  final Map<String, String> _headers;
  final Duration _connectTimeout;
  final HttpClient _client;

  HttpClientRequest? _request;
  HttpClientResponse? _response;
  bool _closed = false;

  /// HTTP 响应码（未连上时 null，供排查 401/503 时区分「鉴权失败」与「总线未装配」）。
  int? get statusCode => _response?.statusCode;

  @override
  Stream<String> get stream {
    final HttpClientResponse? response = _response;
    if (response == null) {
      return Stream<String>.error(
        StateError('尚未 connect()，SSE 流不可用'),
      );
    }
    // 🔴 `utf8.decoder` 必须按**流**方式绑定：它会跨块保留半个多字节字符，
    // 若改用 `utf8.decode(bytes)` 逐块解码，中文/emoji 会在块边界变成乱码。
    return response
        .transform(utf8.decoder)
        .handleError((Object error) {
          // 网络层错误统一归一为流内错误，交给状态机退避重连；
          // 这里不重抛，避免 Dart 的 Zone 未捕获异常。
        });
  }

  @override
  Future<void> connect() async {
    if (_closed) throw StateError('连接已关闭');
    _client.connectionTimeout = _connectTimeout;
    final HttpClientRequest request = await _client
        .getUrl(endpoint)
        .timeout(_connectTimeout);
    // 逐字带上契约要求的请求头：
    // - Accept：声明期望事件流（部分网关据此分流）
    // - Cache-Control：绕过中间代理缓存
    // - Authorization：Bearer 用户令牌（红线 R3：只进头，不进 URL）
    request.headers
      ..set(HttpHeaders.acceptHeader, 'text/event-stream')
      ..set(HttpHeaders.cacheControlHeader, 'no-cache');
    _headers.forEach(request.headers.set);
    _request = request;

    final HttpClientResponse response =
        await request.close().timeout(_connectTimeout);
    if (response.statusCode != HttpStatus.ok) {
      // 明确失败优于「连上了但永远没数据」：
      // 401 = 令牌失效，503 = 服务端未装配总线（`deviceEvents` 的既定口径）。
      _response = response;
      throw HttpException(
        'SSE 连接失败：HTTP ${response.statusCode}',
        uri: endpoint,
      );
    }
    _response = response;
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      // abort 会立即中断正在等待的响应流（仅 close 不够：已建立的 SSE
      // 连接处于 body 读取中，关闭 request 不会解除 recv 阻塞）。
      _request?.abort();
    } catch (_) {
      // 关闭路径绝不外抛：dispose 阶段抛异常会冒到 framework。
    }
    _client.close(force: true);
  }
}
