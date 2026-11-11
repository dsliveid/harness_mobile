/// `WebSocketDeviceConnection` 与 `deviceWsUri` 语义测试。
///
/// 为什么必须测：`WebSocketDeviceConnection` 是 `DeviceConnection` 的**唯一生产
/// 实现**，此前文件根本不存在（`device_connection.dart:5` 的注释指向一个空指针），
/// 导致生产代码从未建立过任何设备长连接。
///
/// ## 测试策略（刻意保守）
/// `WebSocketChannel` 是抽象类且成员众多，手写假实现极易因某个成员被隐式调用而
/// 挂死（实测会卡在 `noSuchMethod` 兜底上导致 120s 超时）。因此本文件**不伪造
/// 整个 channel**，只验证两类可确定性断言的行为：
///
/// 1. **URI 构造**（纯函数，令牌放置、scheme 映射、子路径保留）；
/// 2. **未连接/握手失败时的状态语义**（通过可注入的 `channelFactory` 让它直接抛错）。
///
/// 已连接后的 send/stream 行为由 `device_ws_test.dart` 的 `FakeDeviceConnection`
/// 在**状态机层**覆盖（那里不碰真实 transport，更可控）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:harness_mobile/data/ws/device_connection.dart';
import 'package:harness_mobile/data/ws/websocket_device_connection.dart';

void main() {
  group('deviceWsUri（端点构造，令牌经 query）', () {
    test('http → ws，https → wss', () {
      final httpUri = deviceWsUri(baseUrl: Uri.parse('http://h:8080'));
      expect(httpUri.scheme, 'ws');
      expect(httpUri.path, '/api/v1/devices/ws');

      final httpsUri = deviceWsUri(baseUrl: Uri.parse('https://h:8443'));
      expect(httpsUri.scheme, 'wss');
    });

    test('query 放置时令牌进 ?token=（服务端唯一支持方式）', () {
      final uri = deviceWsUri(
        baseUrl: Uri.parse('http://h:8080'),
        deviceToken: 'hgd_secret',
      );
      expect(uri.queryParameters['token'], 'hgd_secret');
    });

    test('header 放置时 URI 不带令牌（仅 io 平台可实现）', () {
      final uri = deviceWsUri(
        baseUrl: Uri.parse('http://h:8080'),
        deviceToken: 'hgd_secret',
        placement: DeviceTokenPlacement.header,
      );
      expect(uri.queryParameters.containsKey('token'), isFalse);
    });

    test('子路径 base 不被丢弃（反代挂载在 /harness 下也能连）', () {
      final uri = deviceWsUri(
        baseUrl: Uri.parse('https://host/harness'),
        deviceToken: 't',
      );
      expect(uri.path, '/harness/api/v1/devices/ws');
      expect(uri.scheme, 'wss');
    });

    test('空令牌不产生 token 参数（避免 ?token= 空串被判 401）', () {
      final uri = deviceWsUri(
        baseUrl: Uri.parse('http://h:8080'),
        deviceToken: '',
      );
      expect(uri.queryParameters.containsKey('token'), isFalse);
    });

    test('joinUrlPath 不产生 // 或丢前缀', () {
      expect(joinUrlPath('', '/api/x'), '/api/x');
      expect(joinUrlPath('/harness', '/api/x'), '/harness/api/x');
      expect(joinUrlPath('/harness/', '/api/x'), '/harness/api/x');
      expect(joinUrlPath('/harness', 'api/x'), '/harness/api/x');
    });
  });

  group('WebSocketDeviceConnection：未连接时的保护语义', () {
    test('未 connect 就 send → 抛 StateError（不静默丢弃）', () {
      final conn = WebSocketDeviceConnection(
        Uri.parse('ws://localhost:8080/api/v1/devices/ws'),
      );
      expect(() => conn.send('{"v":1}'), throwsA(isA<StateError>()));
    });

    test('未 connect 时 stream 为空流（不抛错、不挂起）', () async {
      final conn = WebSocketDeviceConnection(
        Uri.parse('ws://localhost:8080/api/v1/devices/ws'),
      );
      expect(await conn.stream.isEmpty, isTrue);
    });

    test('未 connect 就 close → 幂等无害', () async {
      final conn = WebSocketDeviceConnection(
        Uri.parse('ws://localhost:8080/api/v1/devices/ws'),
      );
      await conn.close();
      await conn.close(); // 第二次不得抛
      expect(await conn.stream.isEmpty, isTrue);
    });

    test('endpoint 原样暴露（供状态机打码日志用）', () {
      final uri = Uri.parse('ws://h:8080/api/v1/devices/ws?token=secret');
      final conn = WebSocketDeviceConnection(uri);
      expect(conn.endpoint, uri);
    });
  });

  group('WebSocketDeviceConnection：握手失败路径', () {
    test('channelFactory 抛错 → connect 必须 rethrow（401 可被状态机看见）', () async {
      final conn = WebSocketDeviceConnection(
        Uri.parse('ws://localhost:8080/api/v1/devices/ws'),
        channelFactory: (Uri _) => throw StateError('401 unauthorized'),
      );
      await expectLater(conn.connect(), throwsA(isA<StateError>()));
      // 失败后仍未连接：send 必须继续抛，不得误以为已连上
      expect(() => conn.send('x'), throwsA(isA<StateError>()));
    });

    test('connect 失败后再次 connect 仍会重试（不被上一个失败卡死）', () async {
      var calls = 0;
      final conn = WebSocketDeviceConnection(
        Uri.parse('ws://localhost:8080/api/v1/devices/ws'),
        channelFactory: (Uri _) {
          calls++;
          throw StateError('network down');
        },
      );
      await expectLater(conn.connect(), throwsA(isA<StateError>()));
      await expectLater(conn.connect(), throwsA(isA<StateError>()));
      expect(calls, 2, reason: '每次 connect 都应重新尝试，而不是被首次失败永久锁死');
    });
  });
}
