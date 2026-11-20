/// SSE 帧解析与分帧的回归用例。
///
/// 每条用例都对应一个**真实踩过的坑**（见 `sse_event.dart` 文件头的四条形态），
/// 而不是为了覆盖率而写。任何一条红都意味着真机上会出现「连上了但界面不动」。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:harness_mobile/data/sse/sse_event.dart';

void main() {
  group('parseSseFrame 基本形态', () {
    test('标准 event + data 帧', () {
      final SseEvent? event = parseSseFrame(
        'event: snapshot\ndata: {"type":"snapshot","all":[],"at":1}',
      );
      expect(event, isNotNull);
      expect(event!.event, 'snapshot');
      expect(event.id, isNull);
      expect(event.mapOrNull?['at'], 1);
    });

    test('带 id 行时保留（仅 ① Run 事件流会带）', () {
      final SseEvent? event =
          parseSseFrame('id: 42\nevent: delta\ndata: {"text":"hi"}');
      expect(event?.id, '42');
      expect(event?.event, 'delta');
    });

    test('缺 event 行时回落为 message（SSE 规范缺省）', () {
      final SseEvent? event = parseSseFrame('data: {"a":1}');
      expect(event?.event, 'message');
    });

    test('空帧 / 纯空白帧返回 null', () {
      expect(parseSseFrame(''), isNull);
      expect(parseSseFrame('   \n  '), isNull);
    });
  });

  group('🔴 心跳注释行绝不能被当成畸形帧', () {
    test(': ping 单独成帧返回 null（不是断连信号）', () {
      // 服务端每 15s 写一帧 `: ping\n\n`（session_events_handler.go:132）。
      // 若这里抛异常或返回「坏事件」，健康连接会每 15s 自杀一次。
      expect(parseSseFrame(': ping'), isNull);
      expect(parseSseFrame(':'), isNull);
      expect(parseSseFrame(': keep-alive'), isNull);
    });

    test('注释行与真实字段混排时只取字段', () {
      final SseEvent? event = parseSseFrame(
        ': ping\nevent: device.online\ndata: {"type":"device.online"}',
      );
      expect(event?.event, 'device.online');
    });
  });

  group('🔴 换行形态兼容（\\r\\n 与 \\n）', () {
    test('\\r\\n 换行的帧事件名不得带残留 \\r', () {
      final SseEvent? event = parseSseFrame(
        'event: snapshot\r\ndata: {"all":[]}',
      );
      // 若未剥离 \r，event 会变成 "snapshot\r" → 归类为未知事件被丢弃，
      // 表现为「连上了但界面永远不更新」。
      expect(event?.event, 'snapshot');
    });
  });

  group('🔴 多行 data 必须拼接而不是只取最后一行', () {
    test('两条 data 行按规范以换行连接后解析', () {
      final SseEvent? event = parseSseFrame(
        'event: x\ndata: {"a":\ndata: 1}',
      );
      // 拼接后为 `{"a":\n1}`，是合法 JSON。
      expect(event?.mapOrNull?['a'], 1);
    });
  });

  group('🔴 坏 JSON 必须返回 null 而不是抛异常', () {
    test('非法 JSON 静默跳过', () {
      // docs/protocols.md §4.4 第 3 条：畸形帧必须静默跳过，
      // 绝不能让一条坏帧使整个订阅崩溃。
      expect(
        () => parseSseFrame('event: snapshot\ndata: {not json'),
        returnsNormally,
      );
      expect(parseSseFrame('event: snapshot\ndata: {not json'), isNull);
    });

    test('载荷是合法 JSON 但不是对象时仍可解析', () {
      final SseEvent? event = parseSseFrame('event: n\ndata: 123');
      expect(event?.data, 123);
      expect(event?.mapOrNull, isNull); // 守卫：非对象取字段应得 null
      expect(event?.isMap, isFalse);
    });
  });

  group('retry 与未知字段被忽略', () {
    test('retry 字段不影响事件解析', () {
      final SseEvent? event =
          parseSseFrame('retry: 5000\nevent: snapshot\ndata: {"all":[]}');
      expect(event?.event, 'snapshot');
    });
  });

  group('SseFrameSplitter 跨块分帧', () {
    test('一次投递多帧全部切出', () {
      final SseFrameSplitter splitter = SseFrameSplitter();
      final List<String> frames = splitter.add(
        'event: a\ndata: {}\n\nevent: b\ndata: {}\n\n',
      );
      expect(frames.length, 2);
      expect(splitter.hasPending, isFalse);
    });

    test('帧被拆成两块时保留半帧并正确拼接', () {
      final SseFrameSplitter splitter = SseFrameSplitter();
      // 第一块只到一半（没有 \n\n 分隔符）。
      expect(splitter.add('event: snapshot\ndata: {"al'), isEmpty);
      expect(splitter.hasPending, isTrue);
      final List<String> frames = splitter.add('l":[]}\n\n');
      expect(frames.length, 1);
      final SseEvent? event = parseSseFrame(frames.single);
      expect(event?.event, 'snapshot');
      expect(event?.mapOrNull?['all'], isEmpty);
    });

    test('分隔符恰被切在两块之间时也能正确分帧', () {
      final SseFrameSplitter splitter = SseFrameSplitter();
      expect(splitter.add('event: a\ndata: {}\n'), isEmpty);
      final List<String> frames = splitter.add('\n');
      expect(frames.length, 1);
    });

    test('reset 清空残留半帧（连接重建时防串帧）', () {
      final SseFrameSplitter splitter = SseFrameSplitter();
      splitter.add('event: a\ndata: {"hal');
      expect(splitter.hasPending, isTrue);
      splitter.reset();
      expect(splitter.hasPending, isFalse);
      // 复位后新连接的第一帧不得与旧半帧拼接。
      final List<String> frames = splitter.add('event: b\ndata: {}\n\n');
      expect(parseSseFrame(frames.single)?.event, 'b');
    });
  });
}
