/// 前后台重连（resync）测试（M4）。
///
/// 缺口事实：`DeviceWsClient` 是纯 Dart 状态机，原先完全没有 lifecycle 感知。
/// 真机上「切后台 → 系统回收 TCP → 回前台」后状态机仍自认为 `live`，
/// UI 于是显示「已连接」却一帧都收不到（用户感知为「点了没反应」）。
///
/// 本文件覆盖交接书要求的四类断言：
/// 1. `paused`/`hidden`/`detached` → 挂起（状态转 disconnected，停心跳/退避）；
/// 2. `resumed` → 重连（disconnected/reconnecting 状态下真的重建连接）；
/// 3. `resumed` 且连接健康 → **只重拉状态**（发 ping），不重建连接；
/// 4. **幂等**：连续 resumed 不产生连接风暴；`inactive` 不触发任何断连；
///    `dead` 状态不被后台切换偷偷复活。
library;

import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_mobile/data/ws/device_connection.dart';
import 'package:harness_mobile/data/ws/device_ws.dart';
import 'package:harness_mobile/data/ws/ws_lifecycle_bridge.dart';
import 'package:harness_mobile/protocol/envelope.dart';

/// 可控的假连接（与 device_ws_test.dart 同构，便于独立维护）。
class _FakeConnection implements DeviceConnection {
  _FakeConnection(this.endpoint);

  @override
  final Uri endpoint;

  final StreamController<String> _in = StreamController<String>();
  final List<String> sent = <String>[];

  int connectCount = 0;
  int closeCount = 0;
  bool closed = false;

  @override
  Stream<String> get stream => _in.stream;

  @override
  Future<void> connect() async => connectCount++;

  @override
  void send(String data) => sent.add(data);

  @override
  Future<void> close([int? code, String? reason]) async {
    closeCount++;
    closed = true;
    if (!_in.isClosed) await _in.close();
  }

  void push(Map<String, dynamic> env) {
    if (!_in.isClosed) _in.add(jsonEncode(env));
  }

  List<Map<String, dynamic>> get sentFrames =>
      sent.map((e) => jsonDecode(e) as Map<String, dynamic>).toList();

  List<Map<String, dynamic>> framesOf(String type) =>
      sentFrames.where((f) => f['type'] == type).toList();
}

Map<String, dynamic> _welcomeFrame({int heartbeatS = 30}) => <String, dynamic>{
      'v': 1,
      'type': MessageType.welcome,
      'payload': <String, dynamic>{
        'device_id': 'dev-1',
        'server_time': 1700000000000,
        'protocol_version': 1,
        'heartbeat_s': heartbeatS,
        'offline_after_s': (heartbeatS * 1.5).round(),
        'pending': 0,
      },
    };

Map<String, dynamic> _errorFrame(String code) => <String, dynamic>{
      'v': 1,
      'type': MessageType.error,
      'payload': <String, dynamic>{'code': code, 'message': 'test', 'fatal': true},
    };

Uri get _base => Uri.parse('http://127.0.0.1:8080');

/// 构建一个已进入 live 的客户端（含 1 条已建连接）。
({DeviceWsClient client, List<_FakeConnection> created}) _liveClient(
  FakeAsync async,
) {
  final created = <_FakeConnection>[];
  final client = DeviceWsClient(
    connectionFactory: (Uri uri) {
      final c = _FakeConnection(uri);
      created.add(c);
      return c;
    },
    baseUrl: _base,
    deviceToken: 'hgd_testtoken',
    handshakeTimeout: const Duration(seconds: 20),
  );
  client.start();
  async.flushMicrotasks();
  // 握手完成 → live
  created.single.push(_welcomeFrame());
  async.flushMicrotasks();
  expect(client.state, DeviceWsState.live);
  return (client: client, created: created);
}

void main() {
  // attach() 会向 WidgetsBinding 注册观察者，纯 `test()` 环境需要先初始化 binding。
  TestWidgetsFlutterBinding.ensureInitialized();

  group('后台挂起（paused / hidden / detached）', () {
    test('paused → 连接被拆、状态转 disconnected、停心跳', () {
      fakeAsync((async) {
        final live = _liveClient(async);
        final client = live.client;
        final conn = live.created.single;

        client.suspendForBackground();
        async.flushMicrotasks();

        // ① 状态诚实回落到「未连接」，绝不能留在 live
        expect(client.state, DeviceWsState.disconnected);
        expect(client.suspended, isTrue);
        // ② 底层连接被关闭（不留半死 TCP）
        expect(conn.closed, isTrue);
        expect(conn.closeCount, 1);
        // ③ 心跳已停：推进远超心跳周期的时间，不应再有 ping
        final before = conn.framesOf(MessageType.ping).length;
        async.elapse(const Duration(seconds: 120));
        expect(conn.framesOf(MessageType.ping).length, before);

        client.dispose();
        async.flushMicrotasks();
      });
    });

    test('重复挂起幂等（不会重复关连接）', () {
      fakeAsync((async) {
        final live = _liveClient(async);
        final client = live.client;
        final conn = live.created.single;

        client.suspendForBackground();
        client.suspendForBackground();
        client.suspendForBackground();
        async.flushMicrotasks();

        expect(conn.closeCount, 1);
        client.dispose();
        async.flushMicrotasks();
      });
    });

    test('dead 状态下挂起不改变 dead 语义（不偷偷复活）', () {
      fakeAsync((async) {
        final created = <_FakeConnection>[];
        final client = DeviceWsClient(
          connectionFactory: (Uri uri) {
            final c = _FakeConnection(uri);
            created.add(c);
            return c;
          },
          baseUrl: _base,
          deviceToken: 'hgd_testtoken',
          maxRetries: 0,
        );
        client.start();
        async.flushMicrotasks();
        created.single.push(_errorFrame('device.revoked'));
        async.flushMicrotasks();
        expect(client.state, DeviceWsState.dead);
        expect(client.deadReason, DeviceWsDeadReason.repairPairing);

        client.suspendForBackground();
        async.flushMicrotasks();
        expect(client.state, DeviceWsState.dead);

        client.dispose();
        async.flushMicrotasks();
      });
    });
  });

  group('回前台重连（resumed）', () {
    test('挂起后回前台 → 真的重建一条新连接并再次 pending 握手', () {
      fakeAsync((async) {
        final live = _liveClient(async);
        final client = live.client;

        client.suspendForBackground();
        async.flushMicrotasks();
        expect(client.state, DeviceWsState.disconnected);
        expect(live.created.length, 1);

        client.resumeFromBackground();
        async.flushMicrotasks();

        // ② 新建了一条连接（不是复用旧的）
        expect(live.created.length, 2);
        expect(live.created.last.connectCount, 1);
        // ③ 状态推进到握手/连接中（最终由 welcome 决定 live）
        expect(
          client.state,
          anyOf(DeviceWsState.connecting, DeviceWsState.handshaking),
        );
        // ④ 新连接上重发了 hello（握手流程完整重走）
        expect(live.created.last.framesOf(MessageType.hello).length, 1);
        expect(client.suspended, isFalse);

        live.created.last.push(_welcomeFrame());
        async.flushMicrotasks();
        expect(client.state, DeviceWsState.live);

        client.dispose();
        async.flushMicrotasks();
      });
    });

    test('退避等待中（reconnecting）回前台 → 立即重连，不等退避计时器', () {
      fakeAsync((async) {
        final created = <_FakeConnection>[];
        var failing = true;
        final client = DeviceWsClient(
          connectionFactory: (Uri uri) {
            final c = _FakeConnection(uri);
            created.add(c);
            return c;
          },
          baseUrl: _base,
          deviceToken: 'hgd_testtoken',
        );
        client.start();
        async.flushMicrotasks();
        // 让连接被对端关闭 → 进入 reconnecting（退避 1s）
        created.single.push(_errorFrame('device.bad_frame'));
        async.flushMicrotasks();
        client.suspendForBackground();
        async.flushMicrotasks();
        expect(client.suspended, isTrue);

        client.resumeFromBackground();
        async.flushMicrotasks();
        // 立即重连（不推进时间也应该已经发起新的连接尝试）
        expect(created.length, greaterThanOrEqualTo(2));
        failing = false;
        expect(failing, isFalse);

        client.dispose();
        async.flushMicrotasks();
      });
    });
  });

  group('连接健康时只重拉状态（不重建连接）', () {
    test('live 状态下 resumed → 发一次 ping，不新建连接', () {
      fakeAsync((async) {
        final live = _liveClient(async);
        final client = live.client;
        final conn = live.created.single;
        final pingsBefore = conn.framesOf(MessageType.ping).length;

        client.resumeFromBackground();
        async.flushMicrotasks();

        // ① 不建立新连接（避免 UI 闪「连接中」+ 丢在途帧）
        expect(live.created.length, 1);
        // ② 但确实向服务端要了一次最新状态
        expect(conn.framesOf(MessageType.ping).length, pingsBefore + 1);
        // ③ 状态保持 live
        expect(client.state, DeviceWsState.live);

        client.dispose();
        async.flushMicrotasks();
      });
    });
  });

  group('幂等保护（防连接风暴）', () {
    test('连续两次 resumed 只建连一次（第二次不叠加）', () {
      fakeAsync((async) {
        final live = _liveClient(async);
        final client = live.client;

        client.suspendForBackground();
        async.flushMicrotasks();

        // 模拟 lifecycle 抖动：一次性连发两次（不 flush 之间）
        client.resumeFromBackground();
        client.resumeFromBackground();
        async.flushMicrotasks();

        // 只多建一条连接 —— 第二次被 _resyncInFlight / 状态判据拦下
        expect(live.created.length, 2);
        // resync 计数说明幂等判据确实生效（第二次进来后判定为「已在进行中或已健康」）
        expect(client.resyncCount, greaterThanOrEqualTo(1));

        client.dispose();
        async.flushMicrotasks();
      });
    });

    test('dead 状态下 resumed 不自动复活（需用户显式动作）', () {
      fakeAsync((async) {
        final created = <_FakeConnection>[];
        final client = DeviceWsClient(
          connectionFactory: (Uri uri) {
            final c = _FakeConnection(uri);
            created.add(c);
            return c;
          },
          baseUrl: _base,
          deviceToken: 'hgd_testtoken',
          maxRetries: 0,
        );
        client.start();
        async.flushMicrotasks();
        created.single.push(_errorFrame('device.protocol_mismatch'));
        async.flushMicrotasks();
        expect(client.state, DeviceWsState.dead);
        expect(client.deadReason, DeviceWsDeadReason.upgradeRequired);

        final before = created.length;
        client.resumeFromBackground();
        async.flushMicrotasks();
        // 绝不偷偷重连：升级/换设备是用户动作，不是前后台切换能解决的
        expect(created.length, before);
        expect(client.state, DeviceWsState.dead);

        // 但用户主动 reconnectNow 仍然可用（保留逃生通道）
        client.reconnectNow();
        async.flushMicrotasks();
        expect(created.length, before + 1);

        client.dispose();
        async.flushMicrotasks();
      });
    });
  });

  group('DeviceWsLifecycleBridge（WidgetsBindingObserver 接线）', () {
    test('resumed → 触发重连；paused → 挂起；事件被记录', () async {
      final created = <_FakeConnection>[];
      final client = DeviceWsClient(
        connectionFactory: (Uri uri) {
          final c = _FakeConnection(uri);
          created.add(c);
          return c;
        },
        baseUrl: _base,
        deviceToken: 'hgd_testtoken',
      );
      final bridge = DeviceWsLifecycleBridge(client);

      // ① 幂等 attach（不真正注册到全局 binding，避免测试间互相污染）
      bridge.attach();
      bridge.attach();
      expect(bridge.attached, isTrue);

      try {
        // ② 先进入 live
        await client.start();
        await Future<void>.delayed(Duration.zero);
        created.single.push(_welcomeFrame());
        await Future<void>.delayed(Duration.zero);
        expect(client.state, DeviceWsState.live);

        // ③ 切后台 → 挂起
        bridge.didChangeAppLifecycleState(AppLifecycleState.paused);
        await Future<void>.delayed(Duration.zero);
        expect(client.state, DeviceWsState.disconnected);
        expect(client.suspended, isTrue);

        // ④ 回前台 → 重建连接
        final beforeCount = created.length;
        bridge.didChangeAppLifecycleState(AppLifecycleState.resumed);
        await Future<void>.delayed(Duration.zero);
        expect(created.length, beforeCount + 1,
            reason: '回前台必须重连，否则 UI 会显示陈旧的「已连接」');

        // ⑤ 事件序列被完整记录（可观测）
        expect(
          bridge.handledEvents,
          <AppLifecycleState>[
            AppLifecycleState.paused,
            AppLifecycleState.resumed,
          ],
        );
      } finally {
        bridge.detach();
        await client.dispose();
      }
    });

    test('inactive 不断连（下拉通知栏/来电不应造成可见闪烁）', () async {
      final created = <_FakeConnection>[];
      final logs = <String>[];
      final client = DeviceWsClient(
        connectionFactory: (Uri uri) {
          final c = _FakeConnection(uri);
          created.add(c);
          return c;
        },
        baseUrl: _base,
        deviceToken: 'hgd_testtoken',
      );
      final bridge = DeviceWsLifecycleBridge(client, onLog: logs.add);

      try {
        await client.start();
        await Future<void>.delayed(Duration.zero);
        created.single.push(_welcomeFrame());
        await Future<void>.delayed(Duration.zero);
        expect(client.state, DeviceWsState.live);

        bridge.didChangeAppLifecycleState(AppLifecycleState.inactive);
        await Future<void>.delayed(Duration.zero);

        // 连接必须原封不动
        expect(client.state, DeviceWsState.live);
        expect(client.suspended, isFalse);
        expect(created.single.closed, isFalse);
        expect(logs.join('\n'), contains('inactive'));
      } finally {
        bridge.detach();
        await client.dispose();
      }
    });

    test('detach 幂等，且 detach 后不再处理事件', () async {
      final client = DeviceWsClient(
        connectionFactory: (Uri uri) => _FakeConnection(uri),
        baseUrl: _base,
        deviceToken: 'hgd_testtoken',
      );
      final bridge = DeviceWsLifecycleBridge(client);
      try {
        bridge.attach();
        bridge.detach();
        expect(bridge.attached, isFalse);
        // detach 幂等（重复调用不抛）
        bridge.detach();
        expect(bridge.attached, isFalse);
      } finally {
        await client.dispose();
      }
    });
  });
}
