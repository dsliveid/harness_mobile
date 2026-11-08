/// P6 SSE 解析测试（离线：用 mock `http.Client` 注入字节流）。
///
/// 服务端真实线格式依据：
/// - `internal/api/sse.go:19-34`：`id: <seq>\nevent: <type>\ndata: <json>\n\n`
/// - `internal/api/sse.go:36-39`：保活注释帧 `: ping\n\n`
/// - `internal/api/handler.go:307-385`：`resync` 对齐帧 + `last_event_id` query
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:harness_mobile/data/ws/sse_client.dart';
import 'package:http/http.dart' as http;

/// 只实现 `send`，按预设分片吐字节；同时记录最后一次请求，便于断言 URL/请求头。
class FakeStreamingClient extends http.BaseClient {
  FakeStreamingClient(
    this.chunks, {
    this.statusCode = 200,
    this.neverClose = false,
  });

  final List<String> chunks;
  final int statusCode;

  /// true 时流保持打开（用于测试看门狗 / 主动关闭）。
  final bool neverClose;

  http.BaseRequest? lastRequest;
  int sendCount = 0;
  final StreamController<List<int>> _controller = StreamController();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    lastRequest = request;
    sendCount++;
    final stream = Stream<List<int>>.multi((sink) {
      for (final chunk in chunks) {
        sink.add(utf8.encode(chunk));
      }
      if (!neverClose) sink.close();
    });
    return http.StreamedResponse(
      stream,
      statusCode,
      headers: {'content-type': 'text/event-stream'},
      request: request,
    );
  }

  /// 追加一个分片（neverClose 模式下模拟后续到达的帧）。
  void push(String chunk) {
    if (!_controller.isClosed) _controller.add(utf8.encode(chunk));
  }

  /// 关闭内部控制器。
  Future<void> finish() async {
    if (!_controller.isClosed) await _controller.close();
  }
}

Uri get _base => Uri.parse('http://127.0.0.1:8080');

void main() {
  group('SSE 逐行解析', () {
    test('id / event / data 正确解析，seq 取自 id', () async {
      final client = FakeStreamingClient([
        'id: 7\nevent: message.created\n'
            'data: {"role":"assistant","content":"hi"}\n\n',
      ]);
      final sse = SseClient(baseUrl: _base, client: client);
      final events = <SseEvent>[];

      await sse.subscribe(
        sessionId: 'sess-1',
        runId: 'run-1',
        handlers: SseHandlers(onEvent: events.add),
      );

      expect(events, hasLength(1));
      expect(events.single.id, '7');
      expect(events.single.seq, 7);
      expect(events.single.type, 'message.created');
      expect(events.single.data['role'], 'assistant');
      expect(events.single.data['content'], 'hi');
      expect(events.single.isResync, isFalse);
    });

    test('🔴 `:` 开头的保活注释帧被忽略，不产生事件', () async {
      final client = FakeStreamingClient([
        ': ping\n\n',
        ': ping\n\n',
        'id: 1\nevent: message.created\ndata: {"a":1}\n\n',
        ': ping\n\n',
      ]);
      final sse = SseClient(baseUrl: _base, client: client);
      final events = <SseEvent>[];
      final comments = <String>[];

      await sse.subscribe(
        sessionId: 'sess-1',
        runId: 'run-1',
        handlers: SseHandlers(onEvent: events.add, onComment: comments.add),
      );

      expect(events, hasLength(1),
          reason: '注释帧若被当成事件解析，这里会是 4 条');
      expect(events.single.id, '1');
      expect(comments, ['ping', 'ping', 'ping']);
    });

    test('多行 data 以 \\n 连接（SSE 规范）', () async {
      final client = FakeStreamingClient([
        'id: 2\nevent: tool\n'
            'data: {"x":1,\ndata: "y":2}\n\n',
      ]);
      final sse = SseClient(baseUrl: _base, client: client);
      final events = <SseEvent>[];

      await sse.subscribe(
        sessionId: 's',
        runId: 'r',
        handlers: SseHandlers(onEvent: events.add),
      );

      expect(events.single.rawData, '{"x":1,\n"y":2}');
      expect(events.single.data, {'x': 1, 'y': 2});
    });

    test('无 event 字段时 type 回落为 message', () async {
      final client = FakeStreamingClient(['id: 3\ndata: {"a":1}\n\n']);
      final sse = SseClient(baseUrl: _base, client: client);
      final events = <SseEvent>[];

      await sse.subscribe(
        sessionId: 's',
        runId: 'r',
        handlers: SseHandlers(onEvent: events.add),
      );

      expect(events.single.type, 'message');
      expect(events.single.data, {'a': 1});
    });

    test('分片边界被正确拼接（一个帧被切成多段到达）', () async {
      final client = FakeStreamingClient([
        'id: 4\nev',
        'ent: message.updated\nda',
        'ta: {"n":1}\n',
        '\n',
      ]);
      final sse = SseClient(baseUrl: _base, client: client);
      final events = <SseEvent>[];

      await sse.subscribe(
        sessionId: 's',
        runId: 'r',
        handlers: SseHandlers(onEvent: events.add),
      );

      expect(events, hasLength(1));
      expect(events.single.id, '4');
      expect(events.single.type, 'message.updated');
      expect(events.single.data, {'n': 1});
    });

    test('\\r\\n 行尾也能解析', () async {
      final client = FakeStreamingClient([
        'id: 5\r\nevent: message.created\r\ndata: {"ok":true}\r\n\r\n',
      ]);
      final sse = SseClient(baseUrl: _base, client: client);
      final events = <SseEvent>[];

      await sse.subscribe(
        sessionId: 's',
        runId: 'r',
        handlers: SseHandlers(onEvent: events.add),
      );

      expect(events.single.id, '5');
      expect(events.single.data, {'ok': true});
    });
  });

  group('resync 对齐帧', () {
    test('收到 resync → onResync(lastSeq, runStatus, closeReason) 触发', () async {
      final client = FakeStreamingClient([
        'id: 9\nevent: resync\n'
            'data: {"last_seq":42,"close_reason":"run_closed",'
            '"run_status":"succeeded"}\n\n',
      ]);
      final sse = SseClient(baseUrl: _base, client: client);
      final events = <SseEvent>[];
      int? lastSeq;
      String? runStatus;
      String? closeReason;

      await sse.subscribe(
        sessionId: 's',
        runId: 'r',
        handlers: SseHandlers(
          onEvent: events.add,
          onResync: (seq, status, reason) {
            lastSeq = seq;
            runStatus = status;
            closeReason = reason;
          },
        ),
      );

      expect(events.single.isResync, isTrue);
      expect(lastSeq, 42);
      expect(runStatus, 'succeeded');
      expect(closeReason, 'run_closed');
    });

    test('resync 的 last_seq 缺失时回落到 id 的 seq', () async {
      final client = FakeStreamingClient([
        'id: 12\nevent: resync\ndata: {"close_reason":"slow_consumer"}\n\n',
      ]);
      final sse = SseClient(baseUrl: _base, client: client);
      int? lastSeq;

      await sse.subscribe(
        sessionId: 's',
        runId: 'r',
        handlers: SseHandlers(onResync: (seq, _, __) => lastSeq = seq),
      );

      expect(lastSeq, 12);
    });

    test('普通事件不触发 onResync', () async {
      final client = FakeStreamingClient([
        'id: 1\nevent: message.created\ndata: {"a":1}\n\n',
      ]);
      final sse = SseClient(baseUrl: _base, client: client);
      var resyncCalls = 0;

      await sse.subscribe(
        sessionId: 's',
        runId: 'r',
        handlers: SseHandlers(onResync: (_, __, ___) => resyncCalls++),
      );

      expect(resyncCalls, 0);
    });
  });

  group('续传参数与请求形态', () {
    test('lastEventId 同时进 query 与 Last-Event-ID 请求头', () async {
      final client = FakeStreamingClient(['id: 1\nevent: x\ndata: {}\n\n']);
      final sse = SseClient(baseUrl: _base, userToken: 'tok-123', client: client);

      await sse.subscribe(
        sessionId: 'sess-1',
        runId: 'run-1',
        lastEventId: 88,
        handlers: const SseHandlers(),
      );

      final req = client.lastRequest!;
      expect(req.method, 'GET');
      expect(req.url.path, '/api/v1/sessions/sess-1/runs/run-1/events');
      expect(req.url.queryParameters['last_event_id'], '88');
      expect(req.headers['Last-Event-ID'], '88');
      expect(req.headers['Accept'], 'text/event-stream');
      expect(req.headers['Authorization'], 'tok-123');
    });

    test('eventUri 保留 base 路径前缀', () {
      final sse = SseClient(
        baseUrl: Uri.parse('https://api.example.com/proxy/'),
        client: FakeStreamingClient(const []),
      );
      final uri = sse.eventUri(sessionId: 's', runId: 'r');
      expect(uri.path, '/proxy/api/v1/sessions/s/runs/r/events');
      expect(uri.queryParameters.containsKey('last_event_id'), isFalse);
    });

    test('非 200 响应 → onError 收到 SseHttpException', () async {
      final client = FakeStreamingClient(
        ['{"error":{"code":"not_found"}}'],
        statusCode: 404,
      );
      final sse = SseClient(baseUrl: _base, client: client);
      Object? error;

      await sse.subscribe(
        sessionId: 's',
        runId: 'r',
        handlers: SseHandlers(onError: (e) => error = e),
      );

      expect(error, isA<SseHttpException>());
      expect((error! as SseHttpException).statusCode, 404);
    });

    test('流正常结束 → onDone 触发且 Future 收敛', () async {
      final client = FakeStreamingClient(['id: 1\nevent: x\ndata: {}\n\n']);
      final sse = SseClient(baseUrl: _base, client: client);
      var done = false;

      await sse.subscribe(
        sessionId: 's',
        runId: 'r',
        handlers: SseHandlers(onDone: () => done = true),
      );

      expect(done, isTrue);
    });

    test('看门狗：长时间无字节 → onError(TimeoutException) 并关闭', () async {
      final client = FakeStreamingClient(
        [': ping\n\n'],
        neverClose: true,
      );
      final sse = SseClient(
        baseUrl: _base,
        client: client,
        heartbeatWatchdog: const Duration(milliseconds: 50),
      );
      Object? error;

      await sse.subscribe(
        sessionId: 's',
        runId: 'r',
        handlers: SseHandlers(onError: (e) => error = e),
      );

      expect(error, isA<TimeoutException>());
    });

    test('非 JSON 的 data 不抛异常，包成 raw', () async {
      final client = FakeStreamingClient(['id: 1\nevent: x\ndata: not-json\n\n']);
      final sse = SseClient(baseUrl: _base, client: client);
      final events = <SseEvent>[];

      await sse.subscribe(
        sessionId: 's',
        runId: 'r',
        handlers: SseHandlers(onEvent: events.add),
      );

      expect(events.single.data, {'raw': 'not-json'});
    });
  });
}
