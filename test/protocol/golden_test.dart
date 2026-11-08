import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:harness_mobile/protocol/envelope.dart';
import 'package:harness_mobile/protocol/frame_payloads.dart';

/// 黄金 fixture 门禁（防 Go/Dart 双写漂移）。
///
/// 样本由 `harness_go/scripts/gen-fixtures.go` **真实序列化**产出，
/// 禁止手写（手写只能验证「我以为的协议」）。
///
/// 重新生成：
/// ```
/// cd ../harness_go && go run scripts/gen-fixtures.go -out ../harness_mobile/fixtures
/// ```
void main() {
  const fixturesDir = 'fixtures';

  /// 9 个帧样本，必须与 gen-fixtures.go:47-57 一比一，不允许少文件。
  const fixtures = <String>[
    'hello',
    'welcome',
    'ping',
    'pong',
    'error',
    'task_dispatch',
    'task_progress',
    'task_result',
    'lease_revoked',
  ];

  /// 读取并解析 fixture 信封。
  Envelope loadEnvelope(String name) {
    final file = File('$fixturesDir/$name.json');
    expect(file.existsSync(), isTrue,
        reason: '缺少 fixture：$name.json（请运行 gen-fixtures.go 生成）');
    final raw = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    return Envelope.fromJson(raw);
  }

  group('fixture 完整性', () {
    test('9 个样本文件全部存在', () {
      for (final name in fixtures) {
        final file = File('$fixturesDir/$name.json');
        expect(file.existsSync(), isTrue, reason: '缺少 $name.json');
      }
    });

    test('每个样本都能通过信封校验', () {
      for (final name in fixtures) {
        final env = loadEnvelope(name);
        expect(env.validate(), isNull, reason: '$name 帧校验失败');
        expect(env.v, ProtocolVersion.current, reason: '$name 协议版本不符');
      }
    });

    test('帧类型覆盖全部 9 种 MessageType', () {
      final seen = fixtures.map((n) => loadEnvelope(n).type).toSet();
      expect(seen, equals(MessageType.all),
          reason: 'fixture 未覆盖全部帧类型，漏守的帧等于没守');
    });
  });

  group('welcome：驱动心跳节奏（禁硬编码 15s）', () {
    test('heartbeat_s / offline_after_s 正确解析', () {
      final env = loadEnvelope('welcome');
      final w = WelcomePayload.fromJson(env.payload!);

      expect(env.type, MessageType.welcome);
      expect(w.deviceId, 'dev_0123456789abcdef');
      expect(w.heartbeatS, 15);
      expect(w.offlineAfterS, 45);
      expect(w.pending, 2);
      expect(w.leaseEpoch, 7);
      // offline 必须大于 heartbeat，否则端侧永远来不及心跳
      expect(w.offlineAfterS, greaterThan(w.heartbeatS));
    });

    test('heartbeatInterval 取 0.8 倍留裕度', () {
      final w = WelcomePayload.fromJson(loadEnvelope('welcome').payload!);
      expect(w.heartbeatInterval, const Duration(milliseconds: 12000));
    });

    test('服务端调大心跳周期后端侧随之变化（不硬编码）', () {
      final w = WelcomePayload.fromJson(const {
        'device_id': 'd',
        'server_time': 1,
        'protocol_version': 1,
        'heartbeat_s': 30,
        'offline_after_s': 90,
        'pending': 0,
      });
      // 若硬编码 15s，此断言会失败
      expect(w.heartbeatInterval, const Duration(milliseconds: 24000));
    });
  });

  group('int64 毫秒精度（Dart num 陷阱）', () {
    test('ts 为 double 时仍能解析（jsonDecode 可能产出 double）', () {
      final env = Envelope.fromJson(const {
        'v': 1,
        'type': 'ping',
        'ts': 1704067200000.0,
      });
      expect(env.ts, 1704067200000);
      expect(env.ts, isA<int>());
    });

    test('deadline 为 double 时解析为 int', () {
      final p = TaskDispatchPayload.fromJson(const {
        'task_id': 't',
        'run_id': 'r',
        'tool_event_id': 't',
        'tool_name': 'fs.list',
        'deadline': 1704067230000.0,
        'attempt': 1,
      });
      expect(p.deadline, 1704067230000);
      expect(p.deadline, isA<int>());
    });

    test('ts 为字符串时也能解析（宽容）', () {
      final env = Envelope.fromJson(const {
        'v': 1,
        'type': 'ping',
        'ts': '1704067200000',
      });
      expect(env.ts, 1704067200000);
    });
  });

  group('task.dispatch：幂等键与 deadline', () {
    test('task_id 恒等于 tool_event_id（端侧据此幂等）', () {
      final d = TaskDispatchPayload.fromJson(loadEnvelope('task_dispatch').payload!);
      expect(d.taskId, 'te_abc123');
      expect(d.toolEventId, 'te_abc123');
      expect(d.taskId, equals(d.toolEventId),
          reason: 'task_id 必须等于 tool_event_id，否则幂等失效');
      expect(d.runId, 'run_xyz789');
      expect(d.deadline, 1704067230000);
      expect(d.attempt, 1);
    });
  });

  group('task.result：红线 R2 恒 untrusted', () {
    test('fixture 中 source_trust 为 untrusted', () {
      final r = TaskResultPayload.fromJson(loadEnvelope('task_result').payload!);
      expect(r.status, TaskResultPayload.statusSuccess);
      expect(r.sourceTrust, 'untrusted');
    });

    test('默认构造即 untrusted，不会误发 trusted', () {
      const r = TaskResultPayload(
        taskId: 't',
        runId: 'r',
        toolEventId: 't',
        status: 'success',
      );
      expect(r.sourceTrust, 'untrusted');
      expect(r.toJson()['source_trust'], 'untrusted');
    });
  });

  group('error 帧：按 code 分派正确动作（§4.3 决策表）', () {
    test('protocol_mismatch → 不重连，提示升级', () {
      final e = ErrorPayload.fromJson(loadEnvelope('error').payload!);
      expect(e.code, FrameCode.protocolMismatch);
      expect(e.fatal, isTrue);
      expect(e.action, WsFatalAction.upgradeRequired);
    });

    test('revoked → 清令牌回配对', () {
      const e = ErrorPayload(code: FrameCode.revoked, fatal: true);
      expect(e.action, WsFatalAction.repairPairing);
    });

    test('replaced → 提示已在别处上线', () {
      const e = ErrorPayload(code: FrameCode.replaced, fatal: true);
      expect(e.action, WsFatalAction.replacedElsewhere);
    });

    test('bad_frame → 忽略并保持连接（不重连）', () {
      const e = ErrorPayload(code: FrameCode.badFrame);
      expect(e.action, WsFatalAction.ignore);
    });

    test('offline_timeout / server_closing / write_failed → 重连', () {
      for (final code in const [
        FrameCode.offlineTimeout,
        FrameCode.serverClosing,
        FrameCode.writeFailed,
      ]) {
        final e = ErrorPayload(code: code, fatal: true);
        expect(e.action, WsFatalAction.reconnect, reason: '$code 应重连');
      }
    });
  });

  group('lease.revoked：抢占后转只读', () {
    test('解析 session_id 与 epoch', () {
      final l = LeaseRevokedPayload.fromJson(loadEnvelope('lease_revoked').payload!);
      expect(l.sessionId, 'sess_001');
      expect(l.epoch, 8);
    });
  });

  group('信封编解码往返', () {
    test('omitempty 语义：null 字段不出现在 JSON 中', () {
      const env = Envelope(v: 1, type: MessageType.ping);
      final json = env.toJson();
      expect(json.containsKey('id'), isFalse);
      expect(json.containsKey('run_id'), isFalse);
      expect(json.containsKey('ts'), isFalse);
      expect(json.containsKey('payload'), isFalse);
    });

    test('往返一致', () {
      final env = loadEnvelope('welcome');
      final round = Envelope.fromJson(env.toJson());
      expect(round.v, env.v);
      expect(round.type, env.type);
      expect(round.id, env.id);
      expect(round.ts, env.ts);
    });

    test('未知帧类型被 validate 拦下（不静默通过）', () {
      final env = Envelope.fromJson(const {'v': 1, 'type': 'brand.new.frame'});
      expect(env.validate(), contains('未知帧类型'));
    });
  });

  group('协议版本协商（宽进严出）', () {
    test('v=0 视为未声明，接受', () {
      expect(ProtocolVersion.isCompatible(0), isTrue);
    });

    test('min~current 之间接受', () {
      for (var v = ProtocolVersion.min; v <= ProtocolVersion.current; v++) {
        expect(ProtocolVersion.isCompatible(v), isTrue);
      }
    });

    test('超出范围拒绝（不得静默降级）', () {
      expect(ProtocolVersion.isCompatible(ProtocolVersion.current + 1), isFalse);
      // 过旧版本取 -1 而不是 min - 1：min == 1 时 min - 1 恰为 0，而 0 是「端侧未声明」
      // 的豁免值（对齐 Go 侧 CompatibleVersion 的 v == 0 分支），用它会误判成「被接受」。
      expect(ProtocolVersion.isCompatible(-1), isFalse);
    });
  });
}
