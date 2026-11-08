import 'package:flutter_test/flutter_test.dart';
import 'package:harness_mobile/protocol/frame_payloads.dart';

/// 能力申报策略测试（架构文档 §6.3.1 / 实施计划 §0.3）。
///
/// 为什么被禁标签只在这里出现、不在 `lib/` 里出现：
/// CI 的 grep 门禁扫描 `lib/`，若把禁用词写进源码会自己触雷。
/// 断言放在 `test/` 下，既受测试保护，又不触发门禁。
void main() {
  /// 服务端 `pkg/toolapi/spec.go:92-113` 的全部合法标签（共 7 个）。
  const allLegalTags = <String>{
    'workspace.read',
    'workspace.write',
    'workspace.list',
    'process',
    'network',
    'llm',
    'device',
  };

  /// 移动端本期允许申报的标签（有且仅有 2 个）。
  const allowedForMobile = <String>{'network', 'device'};

  group('能力申报白名单', () {
    test('本期申报项恰为 network + device 两项', () {
      final names = MobileCapabilities.declared.map((c) => c.name).toSet();
      expect(names, equals(allowedForMobile));
      expect(MobileCapabilities.declared.length, 2);
    });

    test('申报项不得包含任何越界标签', () {
      final forbidden = allLegalTags.difference(allowedForMobile);
      final declared = MobileCapabilities.declared.map((c) => c.name).toSet();
      for (final tag in forbidden) {
        expect(declared.contains(tag), isFalse,
            reason: '移动端不得申报 $tag（越界，会让服务端派发无法执行的任务）');
      }
    });

    test('严禁申报的子集必须被排除', () {
      final declared = MobileCapabilities.declared.map((c) => c.name).toSet();
      // process：iOS 无法实现，申报即让 Dispatcher 把 shell 任务派到手机
      expect(declared.contains('process'), isFalse);
      // workspace.*：移动端无宿主能力（本期已定案不申报）
      expect(declared.contains('workspace.list'), isFalse);
      expect(declared.contains('workspace.read'), isFalse);
      expect(declared.contains('workspace.write'), isFalse);
      // llm：移动端不承担模型调用
      expect(declared.contains('llm'), isFalse);
    });

    test('每个申报项都带非空 version', () {
      for (final c in MobileCapabilities.declared) {
        expect(c.version, isNotEmpty, reason: '${c.name} 缺少 version');
      }
    });
  });

  group('上行请求体字段精确性（R7：DisallowUnknownFields）', () {
    test('能力项上行只含 name/version 两个键', () {
      for (final c in MobileCapabilities.declared) {
        final json = c.toRequestJson();
        expect(json.keys.toSet(), equals({'name', 'version'}),
            reason: '服务端 capabilityInput 只接受 name/version，'
                '多一个字段会被 DisallowUnknownFields 拒为 400');
      }
    });

    test('能力项即使携带下行字段，上行也不会带出去', () {
      const c = Capability(
        name: 'network',
        version: '1',
        deviceId: 'dev_123', // 下行才有
        updatedAt: 1704067200000, // 下行才有
      );
      final json = c.toRequestJson();
      expect(json.containsKey('device_id'), isFalse);
      expect(json.containsKey('updated_at'), isFalse);
      expect(json, equals({'name': 'network', 'version': '1'}));
    });

    test('HelloPayload 上行时能力项同样只含 name/version', () {
      const hello = HelloPayload(
        name: '我的 iPhone',
        platform: 'ios-arm64',
        appVersion: '0.1.0',
        protocolVersion: 1,
        capabilities: MobileCapabilities.declared,
      );
      final json = hello.toJson();
      final caps = json['capabilities'] as List<dynamic>;
      for (final item in caps) {
        expect((item as Map<String, dynamic>).keys.toSet(),
            equals({'name', 'version'}));
      }
    });
  });

  group('下行能力项解析', () {
    test('能解析 fixture 中的 updated_at（服务端无 omitempty）', () {
      final c = Capability.fromJson(const {
        'name': 'workspace.read',
        'version': '1',
        'updated_at': 0,
      });
      expect(c.name, 'workspace.read');
      expect(c.version, '1');
      expect(c.updatedAt, 0);
    });

    test('updated_at 缺失时不抛异常', () {
      final c = Capability.fromJson(const {'name': 'network', 'version': '1'});
      expect(c.updatedAt, isNull);
    });
  });
}
