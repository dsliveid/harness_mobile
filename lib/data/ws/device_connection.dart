/// 设备长连接（`GET /api/v1/devices/ws`）抽象层。
///
/// 为什么先抽接口：状态机的全部行为（握手 / 心跳 / 退避 / 错误码分派）
/// 必须能在**无网络**环境下被单测覆盖，因此 [DeviceWsClient] 只依赖本文件；
/// 真实 `web_socket_channel` 实现见 `websocket_device_connection.dart`。
///
/// 端点事实（`harness_go/internal/api/router.go:16`）：`/api/v1/devices/ws`
/// 列在免鉴权白名单中，注释为「设备令牌在升级前独立鉴权」，
/// 即设备令牌**不经用户 Bearer 中间件**，由 WS 端点自行校验。
library;

import 'dart:async';

/// 设备令牌的放置位置（服务端 query 与 header 双通道均支持）。
enum DeviceTokenPlacement {
  /// `?token=<device_token>`（默认；跨平台最稳，Web 端唯一可选）。
  query,

  /// `Authorization: Bearer <device_token>` 请求头（仅 io 平台可实现）。
  header,
}

/// 单条 WS 连接。一条连接一个实例，**重连由上层新建实例**。
///
/// 之所以不做「内部自愈」，是因为重连策略（退避 / 次数上限 / 错误码分派）
/// 属于状态机职责，塞进传输层会让两者都不可测。
abstract class DeviceConnection {
  /// 连接目标（含 query，不含鉴权头）。
  Uri get endpoint;

  /// 建立连接；失败必须抛异常（由状态机转成退避重连）。
  Future<void> connect();

  /// 发送一帧文本（JSON Lines 的单行）。
  void send(String data);

  /// 关闭连接（幂等）。
  Future<void> close([int? code, String? reason]);

  /// 入站文本帧流，每条消息为一行 JSON。
  Stream<String> get stream;
}

/// 连接工厂：每次重连都新建一条连接。
typedef DeviceConnectionFactory = DeviceConnection Function(Uri endpoint);

/// 设备 WS 端点路径（`router.go:16`）。
const String deviceWsPath = '/api/v1/devices/ws';

/// 构造设备 WS 端点 URI。
///
/// - `http` → `ws`，`https` → `wss`
/// - [DeviceTokenPlacement.query] 时把令牌塞进 `?token=`（默认）
/// - [DeviceTokenPlacement.header] 时 URI **不带令牌**，改由连接实现的请求头承载
///
/// 注意：令牌只出现在 URI / 请求头里，绝不进入日志（见 `maskToken`）。
Uri deviceWsUri({
  required Uri baseUrl,
  String? deviceToken,
  DeviceTokenPlacement placement = DeviceTokenPlacement.query,
  String path = deviceWsPath,
}) {
  final scheme = baseUrl.scheme == 'https' ? 'wss' : 'ws';
  final query = Map<String, String>.from(baseUrl.queryParameters);
  if (placement == DeviceTokenPlacement.query &&
      deviceToken != null &&
      deviceToken.isNotEmpty) {
    query['token'] = deviceToken;
  }
  return baseUrl.replace(
    scheme: scheme,
    path: joinUrlPath(baseUrl.path, path),
    queryParameters: query.isEmpty ? null : query,
  );
}

/// 拼接 URL 路径（避免出现 `//api` 或丢掉 base 前缀）。
String joinUrlPath(String base, String path) {
  final b = base.endsWith('/') ? base.substring(0, base.length - 1) : base;
  final p = path.startsWith('/') ? path : '/$path';
  return '$b$p';
}
