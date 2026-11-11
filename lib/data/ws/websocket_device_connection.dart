/// 设备长连接的真实传输层实现（`web_socket_channel`）。
///
/// 定位：[DeviceConnection] 的**唯一**生产实现。本文件此前缺失
/// （`device_connection.dart:5` 的注释指向它，但仓内并无该文件），
/// 导致 `DeviceWsClient` 只能被测试里的假实现构造，生产代码从未建立过连接。
///
/// ## 契约事实（已核实服务端源码，勿按想象改）
/// - 端点 `/api/v1/devices/ws`，令牌经 **query `?token=`** 传入 —— WS 无法自定义
///   请求头（`device_handler.go:204`）。URI 由 `deviceWsUri()` 构造好。
/// - 令牌用完即弃，**绝不进日志**：本文件不打印 endpoint，也不在异常文案里拼令牌。
/// - 鉴权在升级前完成：令牌无效 → HTTP 401（**不是** 101），
///   由 `WebSocketChannel.connect` 的 `ready` 抛异常体现 —— 调用方据此判定
///   「被拒」而非「连不上」。
///
/// ## 为什么 `connect()` 要 `await ready`
/// `WebSocketChannel.connect` 是**惰性**的：它立刻返回一个 channel，真正的
/// 握手在后台进行。若不 await `ready`，握手失败（401 / DNS / 拒绝）会变成
/// 一个**未捕获的异步异常**，而状态机会误以为连上了，白等一轮握手超时才失败。
/// await 之后失败即是同步可见的异常，状态机能立刻转退避重连。
library;

import 'package:web_socket_channel/web_socket_channel.dart';

import 'device_connection.dart';

/// 基于 `web_socket_channel` 的连接实现。
///
/// 一条连接一个实例，**重连由上层新建实例**（见 [DeviceConnection] 的约定：
/// 重连策略属于状态机职责，塞进传输层会让两者都不可测）。
class WebSocketDeviceConnection implements DeviceConnection {
  WebSocketDeviceConnection(
    this.endpoint, {
    WebSocketChannel Function(Uri endpoint)? channelFactory,
  }) : _channelFactory = channelFactory ?? WebSocketChannel.connect;

  @override
  final Uri endpoint;

  /// 可注入的 channel 工厂（**仅供测试**：真实网络在 `flutter test` 里不可用）。
  /// 生产为 `WebSocketChannel.connect`。
  final WebSocketChannel Function(Uri endpoint) _channelFactory;

  WebSocketChannel? _channel;
  bool _closed = false;

  @override
  Future<void> connect() async {
    if (_channel != null) return; // 幂等：重复 connect 不重建
    final channel = _channelFactory(endpoint);
    try {
      // 关键：必须等握手完成。401（令牌无效/设备被吊销）会在这里抛出。
      await channel.ready;
    } on Object {
      // 握手失败必须关闭 channel，否则底层 socket 可能泄漏。
      try {
        await channel.sink.close();
      } on Object {
        // 关闭失败无所谓：握手都没成，没有可用连接可清理。
      }
      rethrow;
    }
    _channel = channel;
  }

  @override
  void send(String data) {
    final channel = _channel;
    if (channel == null || _closed) {
      // 不静默丢弃：状态机若在未连接时发送，属于调用顺序错误，必须暴露。
      throw StateError('连接尚未建立，无法发送帧');
    }
    channel.sink.add(data);
  }

  @override
  Future<void> close([int? code, String? reason]) async {
    if (_closed) return; // 幂等
    _closed = true;
    final channel = _channel;
    _channel = null;
    if (channel == null) return;
    try {
      await channel.sink.close(code, reason);
    } on Object {
      // 关闭时的异常不该冒到调用方（我们已经在关闭了）。
    }
  }

  @override
  Stream<String> get stream {
    final channel = _channel;
    if (channel == null) return const Stream<String>.empty();
    // 服务端是 JSON Lines 文本协议，只取文本帧；二进制帧直接忽略。
    return channel.stream.where((Object? frame) => frame is String).cast<String>();
  }
}
