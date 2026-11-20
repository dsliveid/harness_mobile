/// SSE 状态机的回归用例（可注入假连接，无需网络）。
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:harness_mobile/data/sse/backoff_policy.dart';
import 'package:harness_mobile/data/sse/sse_connection.dart';
import 'package:harness_mobile/data/sse/sse_event.dart';
import 'package:harness_mobile/data/sse/sse_session.dart';

/// 假连接：测试完全掌控「什么时候来数据 / 什么时候断」。
class _FakeConnection implements SseConnection {
  _FakeConnection();

  final StreamController<String> _controller = StreamController<String>();
  bool connected = false;
  bool closed = false;

  @override
  Stream<String> get stream => _controller.stream;

  @override
  Future<void> connect() async => connected = true;

  @override
  Future<void> close() async {
    closed = true;
    if (!_controller.isClosed) await _controller.close();
  }

  /// 模拟服务端推送一段文本。
  void emit(String chunk) {
    if (!_controller.isClosed) _controller.add(chunk);
  }

  /// 模拟服务端断开（慢消费者 / 网络中断）。
  Future<void> drop() async {
    if (!_controller.isClosed) await _controller.close();
  }
}

/// 轮询等待条件成立（确定性替代固定 sleep）。
///
/// 为什么不用 `Future.delayed(60ms)`：`flutter test` 全量跑时数百个用例共享
/// 同一个事件循环，一次 `Timer(5ms)` 的退避可能被拖到几十毫秒才触发 ——
/// 固定 sleep 会**随机**不够，表现为「单独跑绿、全量跑红」的抖动。
Future<void> _waitUntil(
  bool Function() predicate, {
  Duration timeout = const Duration(seconds: 2),
  Duration step = const Duration(milliseconds: 5),
}) async {
  final DateTime deadline = DateTime.now().add(timeout);
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) return;
    await Future<void>.delayed(step);
  }
}

void main() {
  group('🔴 open 的唯一判据是首帧 snapshot 落地（不是 TCP 已连）', () {
    test('连上但无任何帧时停留在 connecting，而不是谎报 open', () async {
      final List<SseConnection> built = <SseConnection>[];
      final SseSession session = SseSession(
        factory: (Uri uri, Map<String, String> headers) async {
          final _FakeConnection c = _FakeConnection();
          built.add(c);
          return c;
        },
        endpoint: Uri.parse('http://127.0.0.1/api/v1/devices/events'),
        jitterRatio: 0,
      );

      await session.start();
      expect((built.single as _FakeConnection).connected, isTrue);
      // 一帧都没有 ⇒ 绝不能是 open。
      expect(session.state, SseState.connecting);
      expect(session.hasSnapshot, isFalse);

      await session.close();
    });

    test('首帧到达后跃迁到 open', () async {
      final _FakeConnection connection = _FakeConnection();
      final SseSession session = SseSession(
        factory: (Uri uri, Map<String, String> headers) async => connection,
        endpoint: Uri.parse('http://127.0.0.1/api/v1/devices/events'),
        jitterRatio: 0,
      );

      await session.start();
      connection.emit('event: snapshot\ndata: {"all":[]}\n\n');
      await Future<void>.delayed(Duration.zero);

      expect(session.state, SseState.open);
      expect(session.hasSnapshot, isTrue);

      await session.close();
    });
  });

  group('🔴 : ping 心跳不得导致断连或退避', () {
    test('只收到心跳时状态不变、连接不被拆', () async {
      final _FakeConnection connection = _FakeConnection();
      final SseSession session = SseSession(
        factory: (Uri uri, Map<String, String> headers) async => connection,
        endpoint: Uri.parse('http://127.0.0.1/api/v1/devices/events'),
        jitterRatio: 0,
      );

      await session.start();
      connection.emit('event: snapshot\ndata: {"all":[]}\n\n');
      await Future<void>.delayed(Duration.zero);
      expect(session.state, SseState.open);

      // 三拍心跳。
      for (int i = 0; i < 3; i++) {
        connection.emit(': ping\n\n');
      }
      await Future<void>.delayed(Duration.zero);

      expect(session.state, SseState.open);
      expect(connection.closed, isFalse);
      expect(session.attempt, 0);

      await session.close();
    });
  });

  group('畸形帧静默跳过，不影响后续帧', () {
    test('坏 JSON 之后的好帧仍能送达', () async {
      final _FakeConnection connection = _FakeConnection();
      final List<SseEvent> received = <SseEvent>[];
      final SseSession session = SseSession(
        factory: (Uri uri, Map<String, String> headers) async => connection,
        endpoint: Uri.parse('http://127.0.0.1/api/v1/devices/events'),
        jitterRatio: 0,
        onEvent: received.add,
      );

      await session.start();
      connection.emit('event: snapshot\ndata: {broken\n\n');
      connection.emit('event: device.online\ndata: {"device":{"device_id":"a"}}\n\n');
      await Future<void>.delayed(Duration.zero);

      expect(received.length, 1);
      expect(received.single.event, 'device.online');

      await session.close();
    });

    test('事件回调抛异常不会打断订阅', () async {
      final _FakeConnection connection = _FakeConnection();
      final List<SseEvent> received = <SseEvent>[];
      final SseSession session = SseSession(
        factory: (Uri uri, Map<String, String> headers) async => connection,
        endpoint: Uri.parse('http://127.0.0.1/api/v1/devices/events'),
        jitterRatio: 0,
        onEvent: (SseEvent event) {
          received.add(event);
          if (received.length == 1) throw StateError('consumer exploded');
        },
      );

      await session.start();
      connection.emit('event: snapshot\ndata: {"all":[]}\n\n');
      connection.emit('event: device.online\ndata: {"device":{"device_id":"a"}}\n\n');
      await Future<void>.delayed(Duration.zero);

      expect(received.length, 2);
      expect(session.state, SseState.open);

      await session.close();
    });
  });

  group('断线走退避重连，且不设 dead 终态', () {
    test('建连失败后进入 backoff 并重试（非终止）', () async {
      int attempts = 0;
      final SseSession session = SseSession(
        factory: (Uri uri, Map<String, String> headers) async {
          attempts++;
          if (attempts == 1) throw StateError('refused');
          return _FakeConnection();
        },
        endpoint: Uri.parse('http://127.0.0.1/api/v1/devices/events'),
        backoffScheduleMs: <int>[10, 10, 10],
        jitterRatio: 0,
      );

      await session.start();
      expect(session.state, SseState.backoff);

      // 等一次退避重连。
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(attempts, greaterThanOrEqualTo(2));
      // 🔴 关键：SSE 没有 dead，重连后必须能回到「可用或重连中」。
      expect(session.state, isNot(SseState.idle));

      await session.close();
    });

    test('退避序列耗尽后落长退避继续自愈（不是放弃）', () async {
      int attempts = 0;
      final SseSession session = SseSession(
        factory: (Uri uri, Map<String, String> headers) async {
          attempts++;
          throw StateError('always refused');
        },
        endpoint: Uri.parse('http://127.0.0.1/api/v1/devices/events'),
        // 只给两档，验证「耗尽后仍继续」。
        backoffScheduleMs: <int>[5, 5],
        jitterRatio: 0,
      );

      await session.start();
      // 不用固定 sleep：全量跑（数百个用例并发）时会话调度会被拉长，
      // 固定的 60ms 会随机不够。改为**轮询直到条件成立或超时**。
      await _waitUntil(
        () => attempts > 2,
        timeout: const Duration(seconds: 2),
      );

      // 重试次数应远超序列长度，证明没有在耗尽时停摆。
      expect(attempts, greaterThan(2));
      expect(session.state, SseState.backoff);

      await session.close();
    });

    test('请求头被完整传给工厂（令牌只进头，不进 URL）', () async {
      Uri? seenUri;
      Map<String, String>? seenHeaders;
      final SseSession session = SseSession(
        factory: (Uri uri, Map<String, String> headers) async {
          seenUri = uri;
          seenHeaders = headers;
          return _FakeConnection();
        },
        endpoint: Uri.parse('http://127.0.0.1/api/v1/devices/events'),
        headers: <String, String>{'Authorization': 'Bearer hgt_x'},
        jitterRatio: 0,
      );

      await session.start();
      expect(seenHeaders?['Authorization'], 'Bearer hgt_x');
      // 红线 R3：令牌不得出现在 URL 上。
      expect(seenUri?.query, isEmpty);

      await session.close();
    });
  });

  group('幂等与关闭语义', () {
    test('连续 start 只建一条连接（防连接风暴）', () async {
      int built = 0;
      final SseSession session = SseSession(
        factory: (Uri uri, Map<String, String> headers) async {
          built++;
          return _FakeConnection();
        },
        endpoint: Uri.parse('http://127.0.0.1/api/v1/devices/events'),
        jitterRatio: 0,
      );

      await session.start();
      await session.start();
      await session.start();
      expect(built, 1);

      await session.close();
    });

    test('close 之后不再重连、状态回到 idle', () async {
      final _FakeConnection connection = _FakeConnection();
      int built = 0;
      final SseSession session = SseSession(
        factory: (Uri uri, Map<String, String> headers) async {
          built++;
          return connection;
        },
        endpoint: Uri.parse('http://127.0.0.1/api/v1/devices/events'),
        backoffScheduleMs: <int>[5],
        jitterRatio: 0,
      );

      await session.start();
      connection.emit('event: snapshot\ndata: {"all":[]}\n\n');
      await Future<void>.delayed(Duration.zero);
      expect(session.state, SseState.open);

      await session.close();
      expect(session.state, SseState.idle);

      // 关闭后即使流结束也不得再建连。
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(built, 1);
    });

    test('suspend 后可被 reconnectNow 重新拉起', () async {
      int built = 0;
      final SseSession session = SseSession(
        factory: (Uri uri, Map<String, String> headers) async {
          built++;
          return _FakeConnection();
        },
        endpoint: Uri.parse('http://127.0.0.1/api/v1/devices/events'),
        jitterRatio: 0,
      );

      await session.start();
      expect(built, 1);
      await session.suspend();
      expect(session.state, SseState.idle);

      await session.reconnectNow();
      expect(built, 2);

      await session.close();
    });

    test('服务端主动断流后进入退避（按普通断线处理）', () async {
      final _FakeConnection connection = _FakeConnection();
      final SseSession session = SseSession(
        factory: (Uri uri, Map<String, String> headers) async => connection,
        endpoint: Uri.parse('http://127.0.0.1/api/v1/devices/events'),
        backoffScheduleMs: <int>[1000],
        jitterRatio: 0,
      );

      await session.start();
      connection.emit('event: snapshot\ndata: {"all":[]}\n\n');
      await Future<void>.delayed(Duration.zero);
      expect(session.state, SseState.open);

      await connection.drop();
      await Future<void>.delayed(Duration.zero);

      expect(session.state, SseState.backoff);
      // 断线后 hasSnapshot 必须复位：重连要重拿快照。
      expect(session.hasSnapshot, isFalse);

      await session.close();
    });
  });

  group('退避内核与 device_ws 口径一致', () {
    test('序列为 1→2→4→8→30 秒（jitter=0 时精确）', () {
      expect(
        <int>[
          for (int i = 0; i < 5; i++) backoffDelayMs(i, jitterRatio: 0),
        ],
        <int>[1000, 2000, 4000, 8000, 30000],
      );
    });

    test('超出序列长度时封顶保持（不是归零、不是无限增长）', () {
      expect(backoffDelayMs(99, jitterRatio: 0), 30000);
    });

    test('抖动落在 ±20% 内且绝不为 0', () {
      for (int i = 0; i < 200; i++) {
        final int delay = backoffDelayMs(4); // base 30000
        expect(delay, greaterThanOrEqualTo(24000));
        expect(delay, lessThanOrEqualTo(36000));
        expect(delay, greaterThan(0));
      }
    });

    test('isBeyondFastRetries 阈值为 5（与 device_ws maxRetries 对齐）', () {
      expect(isBeyondFastRetries(4), isFalse);
      expect(isBeyondFastRetries(5), isTrue);
    });
  });
}
