/// P6 设备 WS 状态机测试（**全部离线**：FakeDeviceConnection + fake_async 虚拟时钟）。
///
/// 覆盖交接书要求的 a~f 六组断言：
/// a) 握手：hello 发出 → welcome 到达 → live
/// b) 心跳间隔 = welcome.heartbeat_s * 0.8（防硬编码 15s 的关键测试）
/// c) 8 个帧级错误码各自的最终状态
/// d) 退避序列 1s→2s→4s→8s→30s（±20% 抖动）
/// e) 连续 5 次重连失败后转 dead
/// f) lease.revoked 广播
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_mobile/data/ws/device_connection.dart';
import 'package:harness_mobile/data/ws/device_ws.dart';
import 'package:harness_mobile/protocol/envelope.dart';
import 'package:harness_mobile/protocol/frame_payloads.dart';

/// 可控的假连接：入站帧由测试主动 [push]，出站帧记录在 [sent]。
class FakeDeviceConnection implements DeviceConnection {
  FakeDeviceConnection(this.endpoint, {this.connectError});

  @override
  final Uri endpoint;

  /// 非 null 时 [connect] 直接抛错（模拟网络不可达）。
  final Object? connectError;

  final StreamController<String> _in = StreamController<String>();
  final List<String> sent = [];

  int connectCount = 0;
  int closeCount = 0;

  @override
  Stream<String> get stream => _in.stream;

  @override
  Future<void> connect() async {
    connectCount++;
    final err = connectError;
    if (err != null) throw err;
  }

  @override
  void send(String data) => sent.add(data);

  @override
  Future<void> close([int? code, String? reason]) async {
    closeCount++;
    if (!_in.isClosed) await _in.close();
  }

  /// 推入一条入站行（JSON Lines 的单行）。
  void push(String line) {
    if (!_in.isClosed) _in.add(line);
  }

  /// 推入一个信封对象。
  void pushFrame(Map<String, dynamic> env) => push(jsonEncode(env));

  /// 出站帧（已 JSON 解码）。
  List<Map<String, dynamic>> get sentFrames =>
      sent.map((e) => jsonDecode(e) as Map<String, dynamic>).toList();

  /// 某类型的出站帧。
  List<Map<String, dynamic>> framesOf(String type) =>
      sentFrames.where((f) => f['type'] == type).toList();
}

const String _token = 'hgd_testtoken_abcdef';

Uri get _base => Uri.parse('http://127.0.0.1:8080');

Map<String, dynamic> welcomeFrame({int heartbeatS = 30, int protocol = 1}) => {
      'v': 1,
      'type': MessageType.welcome,
      'payload': {
        'device_id': 'dev-1',
        'server_time': 1700000000000,
        'protocol_version': protocol,
        'heartbeat_s': heartbeatS,
        'offline_after_s': (heartbeatS * 1.5).round(),
        'pending': 0,
      },
    };

Map<String, dynamic> errorFrame(String code, {bool fatal = true}) => {
      'v': 1,
      'type': MessageType.error,
      'payload': {'code': code, 'message': 'test', 'fatal': fatal},
    };

Map<String, dynamic> leaseRevokedFrame() => {
      'v': 1,
      'type': MessageType.leaseRevoked,
      'payload': {'session_id': 'sess-1', 'epoch': 3, 'reason': 'taken_over'},
    };

void main() {
  group('DeviceWsClient 握手（a）', () {
    test('连上后先发 hello，收到 welcome 后进入 live', () {
      fakeAsync((async) {
        final created = <FakeDeviceConnection>[];
        final client = DeviceWsClient(
          connectionFactory: (uri) {
            final c = FakeDeviceConnection(uri);
            created.add(c);
            return c;
          },
          baseUrl: _base,
          deviceToken: _token,
          jitterRatio: 0,
        );
        final states = <DeviceWsState>[];
        client.states.listen(states.add);

        unawaited(client.start());
        async.flushMicrotasks();

        // 已连上并发出 hello，等待 welcome
        expect(client.state, DeviceWsState.handshaking);
        expect(created.single.connectCount, 1);
        final hello = created.single.framesOf(MessageType.hello);
        expect(hello, hasLength(1), reason: '握手必须先发 hello 帧');
        expect(
          (hello.single['payload'] as Map<String, dynamic>)['protocol_version'],
          ProtocolVersion.current,
        );
        // 令牌只出现在 URI，不进 payload
        expect(jsonEncode(hello.single), isNot(contains(_token)));

        created.single.pushFrame(welcomeFrame());
        async.flushMicrotasks();

        expect(client.state, DeviceWsState.live);
        expect(client.welcome?.deviceId, 'dev-1');
        expect(client.retryCount, 0);
        expect(states, containsAllInOrder([
          DeviceWsState.connecting,
          DeviceWsState.handshaking,
          DeviceWsState.live,
        ]));

        unawaited(client.dispose());
        async.flushMicrotasks();
      });
    });

    test('握手超时未收到 welcome → 走退避重连', () {
      fakeAsync((async) {
        final created = <FakeDeviceConnection>[];
        final client = DeviceWsClient(
          connectionFactory: (uri) {
            final c = FakeDeviceConnection(uri);
            created.add(c);
            return c;
          },
          baseUrl: _base,
          deviceToken: _token,
          handshakeTimeout: const Duration(seconds: 20),
          jitterRatio: 0,
        );

        unawaited(client.start());
        async.flushMicrotasks();
        expect(client.state, DeviceWsState.handshaking);

        async.elapse(const Duration(seconds: 20));
        async.flushMicrotasks();
        expect(client.state, DeviceWsState.reconnecting);

        unawaited(client.dispose());
        async.flushMicrotasks();
      });
    });

    test('welcome 协议版本不兼容 → 直接 dead(upgradeRequired)', () {
      fakeAsync((async) {
        final created = <FakeDeviceConnection>[];
        final client = DeviceWsClient(
          connectionFactory: (uri) {
            final c = FakeDeviceConnection(uri);
            created.add(c);
            return c;
          },
          baseUrl: _base,
          deviceToken: _token,
          jitterRatio: 0,
        );

        unawaited(client.start());
        async.flushMicrotasks();
        created.single.pushFrame(welcomeFrame(protocol: 99));
        async.flushMicrotasks();

        expect(client.state, DeviceWsState.dead);
        expect(client.deadReason, DeviceWsDeadReason.upgradeRequired);
        expect(client.lastFrameCode, FrameCode.protocolMismatch);

        unawaited(client.dispose());
        async.flushMicrotasks();
      });
    });
  });

  group('心跳间隔取 welcome.heartbeat_s * 0.8（b）', () {
    test('heartbeat_s=30 → 24s 才发第一帧 ping（绝不是 15s）', () {
      fakeAsync((async) {
        final created = <FakeDeviceConnection>[];
        final client = DeviceWsClient(
          connectionFactory: (uri) {
            final c = FakeDeviceConnection(uri);
            created.add(c);
            return c;
          },
          baseUrl: _base,
          deviceToken: _token,
          jitterRatio: 0,
          loadProvider: () => {'cpu': 0.1},
        );

        unawaited(client.start());
        async.flushMicrotasks();
        created.single.pushFrame(welcomeFrame(heartbeatS: 30));
        async.flushMicrotasks();

        expect(client.state, DeviceWsState.live);
        expect(client.heartbeatInterval, const Duration(seconds: 24));
        expect(
          client.heartbeatInterval,
          const WelcomePayload(
            deviceId: 'x',
            serverTime: 0,
            protocolVersion: 1,
            heartbeatS: 30,
            offlineAfterS: 45,
            pending: 0,
          ).heartbeatInterval,
          reason: '必须直接复用 WelcomePayload.heartbeatInterval',
        );

        // 15s（服务端默认值）时**不应**有任何 ping
        async.elapse(const Duration(seconds: 15));
        async.flushMicrotasks();
        expect(created.single.framesOf(MessageType.ping), isEmpty,
            reason: '心跳间隔若硬编码 15s，这里会错误地发出 ping');

        // 再走到 24s → 恰好一帧 ping
        async.elapse(const Duration(seconds: 9));
        async.flushMicrotasks();
        final pings = created.single.framesOf(MessageType.ping);
        expect(pings, hasLength(1));
        expect(
          (pings.single['payload'] as Map<String, dynamic>)['load'],
          {'cpu': 0.1},
        );
        expect(
          (pings.single['payload'] as Map<String, dynamic>)['protocol_version'],
          ProtocolVersion.current,
        );

        // 48s → 第二帧
        async.elapse(const Duration(seconds: 24));
        async.flushMicrotasks();
        expect(created.single.framesOf(MessageType.ping), hasLength(2));

        unawaited(client.dispose());
        async.flushMicrotasks();
      });
    });

    test('welcome 之前用 15s 兜底心跳', () {
      fakeAsync((async) {
        final created = <FakeDeviceConnection>[];
        final client = DeviceWsClient(
          connectionFactory: (uri) {
            final c = FakeDeviceConnection(uri);
            created.add(c);
            return c;
          },
          baseUrl: _base,
          deviceToken: _token,
          handshakeTimeout: const Duration(minutes: 5),
          jitterRatio: 0,
        );

        unawaited(client.start());
        async.flushMicrotasks();
        expect(client.state, DeviceWsState.handshaking);
        expect(client.heartbeatInterval, const Duration(seconds: 15));

        async.elapse(const Duration(seconds: 15));
        async.flushMicrotasks();
        expect(created.single.framesOf(MessageType.ping), hasLength(1));

        unawaited(client.dispose());
        async.flushMicrotasks();
      });
    });
  });

  group('8 个帧级错误码分派（c）', () {
    /// 建好一个已 live 的 client，返回 (client, fake)。
    (DeviceWsClient, FakeDeviceConnection) liveClient(FakeAsync async) {
      final created = <FakeDeviceConnection>[];
      final client = DeviceWsClient(
        connectionFactory: (uri) {
          final c = FakeDeviceConnection(uri);
          created.add(c);
          return c;
        },
        baseUrl: _base,
        deviceToken: _token,
        jitterRatio: 0,
      );
      unawaited(client.start());
      async.flushMicrotasks();
      created.single.pushFrame(welcomeFrame());
      async.flushMicrotasks();
      expect(client.state, DeviceWsState.live);
      return (client, created.single);
    }

    test('bad_frame → ignore：保持 live，不重连', () {
      fakeAsync((async) {
        final (client, fake) = liveClient(async);
        final frames = <Envelope>[];
        client.frames.listen(frames.add);

        fake.pushFrame(errorFrame(FrameCode.badFrame, fatal: false));
        async.flushMicrotasks();

        expect(client.state, DeviceWsState.live);
        expect(client.deadReason, isNull);
        expect(client.lastFrameCode, FrameCode.badFrame);
        expect(fake.connectCount, 1, reason: 'ignore 分支不得触发重连');
        expect(frames.single.type, MessageType.error);

        unawaited(client.dispose());
        async.flushMicrotasks();
      });
    });

    test('task_unsupported → ignore：保持 live', () {
      fakeAsync((async) {
        final (client, fake) = liveClient(async);
        fake.pushFrame(errorFrame(FrameCode.taskUnsupported, fatal: false));
        async.flushMicrotasks();

        expect(client.state, DeviceWsState.live);
        expect(client.lastFrameCode, FrameCode.taskUnsupported);
        expect(fake.connectCount, 1);

        unawaited(client.dispose());
        async.flushMicrotasks();
      });
    });

    test('protocol_mismatch → dead(upgradeRequired)', () {
      fakeAsync((async) {
        final (client, fake) = liveClient(async);
        fake.pushFrame(errorFrame(FrameCode.protocolMismatch));
        async.flushMicrotasks();

        expect(client.state, DeviceWsState.dead);
        expect(client.deadReason, DeviceWsDeadReason.upgradeRequired);
        expect(fake.closeCount, 1, reason: 'dead 必须关闭连接');

        unawaited(client.dispose());
        async.flushMicrotasks();
      });
    });

    test('replaced → dead(replacedElsewhere)', () {
      fakeAsync((async) {
        final (client, fake) = liveClient(async);
        fake.pushFrame(errorFrame(FrameCode.replaced));
        async.flushMicrotasks();

        expect(client.state, DeviceWsState.dead);
        expect(client.deadReason, DeviceWsDeadReason.replacedElsewhere);

        unawaited(client.dispose());
        async.flushMicrotasks();
      });
    });

    test('revoked → dead(repairPairing)', () {
      fakeAsync((async) {
        final (client, fake) = liveClient(async);
        fake.pushFrame(errorFrame(FrameCode.revoked));
        async.flushMicrotasks();

        expect(client.state, DeviceWsState.dead);
        expect(client.deadReason, DeviceWsDeadReason.repairPairing);

        unawaited(client.dispose());
        async.flushMicrotasks();
      });
    });

    for (final code in [
      FrameCode.offlineTimeout,
      FrameCode.serverClosing,
      FrameCode.writeFailed,
    ]) {
      test('$code → reconnect：进入 reconnecting 并新建连接', () {
        fakeAsync((async) {
          final (client, fake) = liveClient(async);
          fake.pushFrame(errorFrame(code));
          async.flushMicrotasks();

          expect(client.state, DeviceWsState.reconnecting);
          expect(client.retryCount, 1);
          expect(client.lastFrameCode, code);

          // 退避 1s（jitterRatio=0）后重新连接
          async.elapse(const Duration(seconds: 1));
          async.flushMicrotasks();
          expect(client.state, DeviceWsState.handshaking);

          unawaited(client.dispose());
          async.flushMicrotasks();
        });
      });
    }
  });

  group('指数退避（d）与 5 次上限（e）', () {
    test('退避序列 1s→2s→4s→8s→30s，之后封顶 30s', () {
      final client = DeviceWsClient(
        connectionFactory: (uri) => FakeDeviceConnection(uri),
        baseUrl: _base,
        deviceToken: _token,
        jitterRatio: 0,
      );
      expect(client.backoffFor(0), const Duration(seconds: 1));
      expect(client.backoffFor(1), const Duration(seconds: 2));
      expect(client.backoffFor(2), const Duration(seconds: 4));
      expect(client.backoffFor(3), const Duration(seconds: 8));
      expect(client.backoffFor(4), const Duration(seconds: 30));
      expect(client.backoffFor(9), const Duration(seconds: 30),
          reason: '越界必须封顶，不能继续翻倍');
      unawaited(client.dispose());
    });

    test('抖动幅度落在 ±20% 内', () {
      final client = DeviceWsClient(
        connectionFactory: (uri) => FakeDeviceConnection(uri),
        baseUrl: _base,
        deviceToken: _token,
        random: Random(7),
      );
      for (var i = 0; i < 50; i++) {
        final ms = client.backoffFor(2).inMilliseconds; // base 4000ms
        expect(ms, inInclusiveRange(3200, 4800));
      }
      unawaited(client.dispose());
    });

    test('连续 5 次重连失败后转 dead(maxRetriesExceeded)', () {
      fakeAsync((async) {
        final created = <FakeDeviceConnection>[];
        final client = DeviceWsClient(
          connectionFactory: (uri) {
            final c = FakeDeviceConnection(uri, connectError: Exception('boom'));
            created.add(c);
            return c;
          },
          baseUrl: _base,
          deviceToken: _token,
          jitterRatio: 0,
        );

        unawaited(client.start());
        async.flushMicrotasks();
        expect(client.state, DeviceWsState.reconnecting);
        expect(client.retryCount, 1);

        // 依次走过 2s / 4s / 8s / 30s 四轮，每轮都失败
        for (final seconds in [1, 2, 4, 8, 30]) {
          async.elapse(Duration(seconds: seconds));
          async.flushMicrotasks();
        }

        expect(created.length, 6, reason: '初始 1 次 + 5 次重连');
        expect(client.state, DeviceWsState.dead);
        expect(client.deadReason, DeviceWsDeadReason.maxRetriesExceeded);
        expect(client.retryCount, 5);

        // dead 后不再自动重连
        async.elapse(const Duration(minutes: 5));
        async.flushMicrotasks();
        expect(created.length, 6);
        expect(client.state, DeviceWsState.dead);

        // 用户手动重连可恢复（预算重置后立刻发起新尝试；本次仍失败 → 重新计数 1）
        unawaited(client.reconnectNow());
        async.flushMicrotasks();
        expect(created.length, 7);
        expect(client.state, DeviceWsState.reconnecting);
        expect(client.retryCount, 1,
            reason: 'reconnectNow 已把预算清零，本次失败重新计为第 1 次');

        unawaited(client.dispose());
        async.flushMicrotasks();
      });
    });
  });

  group('lease.revoked 广播（f）', () {
    test('收到 lease.revoked → frames 与 leaseRevocations 均广播', () {
      fakeAsync((async) {
        final created = <FakeDeviceConnection>[];
        final client = DeviceWsClient(
          connectionFactory: (uri) {
            final c = FakeDeviceConnection(uri);
            created.add(c);
            return c;
          },
          baseUrl: _base,
          deviceToken: _token,
          jitterRatio: 0,
        );
        final frames = <Envelope>[];
        final leases = <LeaseRevokedPayload>[];
        client.frames.listen(frames.add);
        client.leaseRevocations.listen(leases.add);

        unawaited(client.start());
        async.flushMicrotasks();
        created.single.pushFrame(welcomeFrame());
        async.flushMicrotasks();
        created.single.pushFrame(leaseRevokedFrame());
        async.flushMicrotasks();

        expect(frames.single.type, MessageType.leaseRevoked);
        expect(leases, hasLength(1));
        expect(leases.single.sessionId, 'sess-1');
        expect(leases.single.epoch, 3);
        expect(leases.single.reason, 'taken_over');
        // 租约被抢占不改变连接状态（业务层自行转只读）
        expect(client.state, DeviceWsState.live);

        unawaited(client.dispose());
        async.flushMicrotasks();
      });
    });
  });

  group('端点与令牌安全', () {
    test('默认把设备令牌放进 ?token=，日志形态经 maskToken 打码', () {
      final client = DeviceWsClient(
        connectionFactory: (uri) => FakeDeviceConnection(uri),
        baseUrl: _base,
        deviceToken: _token,
      );
      expect(client.endpoint.scheme, 'ws');
      expect(client.endpoint.path, '/api/v1/devices/ws');
      expect(client.endpoint.queryParameters['token'], _token);
      expect(client.maskedEndpoint, isNot(contains(_token)));
      expect(client.maskedEndpoint, contains('hgd_***ef'));
      unawaited(client.dispose());
    });

    test('header 模式下 URI 不含令牌，https → wss', () {
      final client = DeviceWsClient(
        connectionFactory: (uri) => FakeDeviceConnection(uri),
        baseUrl: Uri.parse('https://api.example.com'),
        deviceToken: _token,
        tokenPlacement: DeviceTokenPlacement.header,
      );
      expect(client.endpoint.scheme, 'wss');
      expect(client.endpoint.queryParameters.containsKey('token'), isFalse);
      expect(client.maskedEndpoint, isNot(contains(_token)));
      unawaited(client.dispose());
    });

    test('base 路径前缀被保留', () {
      final client = DeviceWsClient(
        connectionFactory: (uri) => FakeDeviceConnection(uri),
        baseUrl: Uri.parse('http://127.0.0.1:8080/proxy/'),
        deviceToken: _token,
      );
      expect(client.endpoint.path, '/proxy/api/v1/devices/ws');
      unawaited(client.dispose());
    });

    test('非法 JSON 行被丢弃且不影响连接', () {
      fakeAsync((async) {
        final created = <FakeDeviceConnection>[];
        final client = DeviceWsClient(
          connectionFactory: (uri) {
            final c = FakeDeviceConnection(uri);
            created.add(c);
            return c;
          },
          baseUrl: _base,
          deviceToken: _token,
          jitterRatio: 0,
        );
        unawaited(client.start());
        async.flushMicrotasks();
        created.single.pushFrame(welcomeFrame());
        async.flushMicrotasks();

        created.single.push('not-json');
        created.single.push('');
        created.single.push('{"v":1,"type":"unknown.type"}');
        async.flushMicrotasks();

        expect(client.state, DeviceWsState.live);

        unawaited(client.dispose());
        async.flushMicrotasks();
      });
    });
  });
}
