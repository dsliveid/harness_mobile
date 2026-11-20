/// 设备状态归约的回归用例。
///
/// 全部断言都是「服务端契约 → 本地列表」的纯函数行为，
/// 因此每条用例都直接对应 `docs/protocols.md` §4 与
/// `internal/device/state_bus.go` 的一句话。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:harness_mobile/data/model/device_state.dart';
import 'package:harness_mobile/data/sse/device_state_state.dart';
import 'package:harness_mobile/data/sse/sse_event.dart';

SseEvent _event(String type, Object? data) =>
    SseEvent(event: type, data: data);

Map<String, dynamic> _device(
  String id, {
  bool online = false,
  String name = 'd',
  String kind = 'desktop',
  String? userId,
  int? lastSeenAt,
}) =>
    <String, dynamic>{
      'device_id': id,
      'name': name,
      'kind': kind,
      'online': online,
      if (userId != null) 'user_id': userId,
      if (lastSeenAt != null) 'last_seen_at': lastSeenAt,
    };

void main() {
  group('snapshot：整表替换（重连后的权威视图）', () {
    test('覆盖已有列表，并清掉断线期间消失的幽灵条目', () {
      final List<DeviceState> current = <DeviceState>[
        DeviceState.fromJson(_device('a')),
        DeviceState.fromJson(_device('ghost')),
      ];
      final DeviceListChange change = reduceDeviceState(
        current,
        _event(DeviceEventTypes.snapshot, <String, dynamic>{
          'type': 'snapshot',
          'all': <Object>[_device('a'), _device('b')],
        }),
      );
      expect(change.changed, isTrue);
      expect(change.devices.map((DeviceState d) => d.deviceId), <String>['a', 'b']);
    });

    test('空数组是合法的「零设备」，不是解析失败', () {
      final DeviceListChange change = reduceDeviceState(
        <DeviceState>[DeviceState.fromJson(_device('a'))],
        _event(DeviceEventTypes.snapshot, <String, dynamic>{'all': <Object>[]}),
      );
      expect(change.changed, isTrue);
      expect(change.devices, isEmpty);
    });

    test('内容完全相同的快照不算变化（避免重连时整页重建）', () {
      final List<DeviceState> current = <DeviceState>[
        DeviceState.fromJson(_device('a')),
      ];
      final DeviceListChange change = reduceDeviceState(
        current,
        _event(DeviceEventTypes.snapshot, <String, dynamic>{
          'all': <Object>[_device('a')],
        }),
      );
      expect(change.changed, isFalse);
      expect(change.devices, same(current));
    });
  });

  group('device.online / device.offline 按 device_id upsert', () {
    test('online 让既有设备变为在线', () {
      final DeviceListChange change = reduceDeviceState(
        <DeviceState>[DeviceState.fromJson(_device('a'))],
        _event(DeviceEventTypes.online, <String, dynamic>{
          'device': _device('a', online: true),
        }),
      );
      expect(change.changed, isTrue);
      expect(change.devices.single.online, isTrue);
    });

    test('🔴 offline 只标灰，绝不从列表移除（仍在绑定关系中）', () {
      final DeviceListChange change = reduceDeviceState(
        <DeviceState>[DeviceState.fromJson(_device('a', online: true))],
        _event(DeviceEventTypes.offline, <String, dynamic>{
          'device': _device('a', online: false),
        }),
      );
      expect(change.devices.length, 1);
      expect(change.devices.single.deviceId, 'a');
      expect(change.devices.single.online, isFalse);
    });

    test('离线后仍保留 lastSeenAt（UI 可展示「最后在线时间」）', () {
      final DeviceListChange change = reduceDeviceState(
        <DeviceState>[
          DeviceState.fromJson(_device('a', online: true, lastSeenAt: 111)),
        ],
        _event(DeviceEventTypes.offline, <String, dynamic>{
          // 服务端 omitempty 裁剪后可能不带 last_seen_at。
          'device': <String, dynamic>{'device_id': 'a', 'online': false},
        }),
      );
      expect(change.devices.single.lastSeenAt, 111);
      expect(change.devices.single.online, isFalse);
    });

    test('未知设备直接插入（增量帧先于快照到达时不丢数据）', () {
      final DeviceListChange change = reduceDeviceState(
        const <DeviceState>[],
        _event(DeviceEventTypes.online, <String, dynamic>{
          'device': _device('new', online: true),
        }),
      );
      expect(change.devices.single.deviceId, 'new');
      expect(change.devices.single.online, isTrue);
    });

    test('重复帧幂等：同一帧投两次结果与投一次一致', () {
      final SseEvent online = _event(DeviceEventTypes.online,
          <String, dynamic>{'device': _device('a', online: true)});
      final DeviceListChange once = reduceDeviceState(
        const <DeviceState>[],
        online,
      );
      final DeviceListChange twice = reduceDeviceState(once.devices, online);
      expect(twice.devices, once.devices);
      // 第二次不应再判为变化（否则每次重连都闪一下）。
      expect(twice.changed, isFalse);
    });
  });

  group('🔴 device.revoked 与 device.offline 语义必须分开', () {
    test('revoked 从列表移除（解绑后不得只变灰仍留卡片）', () {
      final DeviceListChange change = reduceDeviceState(
        <DeviceState>[
          DeviceState.fromJson(_device('a')),
          DeviceState.fromJson(_device('b')),
        ],
        _event(DeviceEventTypes.revoked, <String, dynamic>{
          'device': <String, dynamic>{'device_id': 'b'},
        }),
      );
      expect(change.changed, isTrue);
      expect(change.devices.map((DeviceState d) => d.deviceId), <String>['a']);
    });

    test('revoked 找不到该 id 时不算变化（重复帧）', () {
      final DeviceListChange change = reduceDeviceState(
        <DeviceState>[DeviceState.fromJson(_device('a'))],
        _event(DeviceEventTypes.revoked, <String, dynamic>{
          'device': <String, dynamic>{'device_id': 'ghost'},
        }),
      );
      expect(change.changed, isFalse);
    });
  });

  group('未知事件 / 畸形载荷一律静默忽略', () {
    test('未知事件名不改变列表', () {
      final List<DeviceState> current = <DeviceState>[
        DeviceState.fromJson(_device('a')),
      ];
      final DeviceListChange change = reduceDeviceState(
        current,
        _event('future.event', <String, dynamic>{'x': 1}),
      );
      expect(change.changed, isFalse);
      expect(change.devices, same(current));
    });

    test('载荷非对象时不改变列表', () {
      final DeviceListChange change =
          reduceDeviceState(const <DeviceState>[], _event('device.online', 42));
      expect(change.changed, isFalse);
    });

    test('device 字段缺 id 时不改变列表', () {
      final DeviceListChange change = reduceDeviceState(
        const <DeviceState>[],
        _event(DeviceEventTypes.online, <String, dynamic>{
          'device': <String, dynamic>{'name': 'x'},
        }),
      );
      expect(change.changed, isFalse);
    });
  });

  group('🔴 两种字段口径归一（首屏 model.Device vs 快照 device.DeviceState）', () {
    test('首屏口径：id + status="online"', () {
      final DeviceState device = DeviceState.fromJson(<String, dynamic>{
        'id': 'dev-1',
        'name': '笔记本',
        'kind': 'desktop',
        'status': 'online',
        'last_seen_at': 1700000000000,
      });
      expect(device.deviceId, 'dev-1');
      expect(device.online, isTrue);
      expect(device.lastSeenAt, 1700000000000);
    });

    test('快照口径：device_id + online 布尔', () {
      final DeviceState device = DeviceState.fromJson(_device('dev-2', online: true));
      expect(device.deviceId, 'dev-2');
      expect(device.online, isTrue);
    });

    test('status=offline 不算在线', () {
      final DeviceState device = DeviceState.fromJson(<String, dynamic>{
        'id': 'dev-3',
        'status': 'offline',
      });
      expect(device.online, isFalse);
    });

    test('user_id 缺失时 hasOwner 为 false（展示「未绑定账号」而非隐藏）', () {
      final DeviceState device = DeviceState.fromJson(_device('dev-4'));
      expect(device.hasOwner, isFalse);
      expect(device.userId, isNull);
    });
  });

  group('devicesFromJsonList：首屏 items 解析', () {
    test('丢弃无 id 的条目，保留其余', () {
      final List<DeviceState> devices = devicesFromJsonList(<Object>[
        <String, dynamic>{'id': 'a', 'status': 'online'},
        <String, dynamic>{'name': '无id'},
        <String, dynamic>{'device_id': 'b', 'online': true},
      ]);
      expect(devices.map((DeviceState d) => d.deviceId), <String>['a', 'b']);
    });

    test('非数组入参返回空列表（不抛）', () {
      expect(devicesFromJsonList(null), isEmpty);
      expect(devicesFromJsonList('x'), isEmpty);
    });
  });
}
