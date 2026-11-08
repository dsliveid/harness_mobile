/// 手写 SSE 客户端（`GET /api/v1/sessions/{sid}/runs/{rid}/events`）。
///
/// 为什么不用 EventSource：它是**浏览器 API**，移动端没有；`web` 平台之外
/// 必须自己解析 `text/event-stream`。本文件因此基于 `package:http` 的流式
/// `send()` 手写逐行解析。
///
/// 服务端契约（`harness_go/internal/api/handler.go:307-385` + `sse.go:11-39`）：
/// - 帧格式：`id: <seq>\nevent: <type>\ndata: <json>\n\n`
/// - 每 15s 一条保活注释帧 `: ping\n\n` —— **必须以 `:` 开头的行整体丢弃**，
///   否则会被误当成事件（`sse.go:36-39`）
/// - 续传双通道：`Last-Event-ID` 请求头 **和** `last_event_id` query
///   （`handler.go:318-326`，后者为 EventSource 准备）。本实现两者都发。
/// - Run 终态 / 慢消费者时下发 `event: resync`，payload
///   `{last_seq, close_reason, run_status}`，随后关闭连接
///   （`handler.go:346-385`）→ **收到必须重拉消息快照，不可续接**
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// 一条 SSE 事件（`data:` 已解析为 JSON Map）。
class SseEvent {
  const SseEvent({
    required this.id,
    required this.type,
    required this.data,
    required this.rawData,
  });

  /// `id:` 字段（Run 内单调递增 seq 的字符串形式），缺失为 null。
  final String? id;

  /// `event:` 字段；服务端未写时按 SSE 规范回落到 `message`。
  final String? type;

  /// `data:` 解析后的 JSON 对象（非对象 JSON 时为 `{'value': <原始值>}`）。
  final Map<String, dynamic> data;

  /// `data:` 原始文本（多行 data 以 `\n` 连接）。
  final String rawData;

  /// seq 数值（无法解析时为 null）。
  int? get seq {
    final raw = id;
    if (raw == null || raw.isEmpty) return null;
    return int.tryParse(raw);
  }

  /// 是否为 `resync` 对齐帧。
  bool get isResync => type == SseClient.resyncEventType;

  @override
  String toString() => 'SseEvent(id=$id, type=$type)';
}

/// SSE 解析结果回调集合。
class SseHandlers {
  const SseHandlers({
    this.onEvent,
    this.onResync,
    this.onComment,
    this.onError,
    this.onDone,
  });

  /// 普通事件（含 `resync`，便于上层统一记录）。
  final void Function(SseEvent event)? onEvent;

  /// `resync` 帧：上层据此**重拉消息快照**（不要续接）。
  final void Function(int lastSeq, String? runStatus, String? closeReason)?
      onResync;

  /// 保活注释帧（`:` 开头），仅用于观测，业务层一般忽略。
  final void Function(String text)? onComment;

  /// 传输/解析异常。
  final void Function(Object error)? onError;

  /// 流正常结束（服务端关闭连接）。
  final void Function()? onDone;
}

/// 手写 SSE 客户端。
class SseClient {
  SseClient({
    required Uri baseUrl,
    String? userToken,
    http.Client? client,
    this.connectTimeout = const Duration(seconds: 15),
    this.heartbeatWatchdog = const Duration(seconds: 45),
  })  : _baseUrl = baseUrl,
        _userToken = userToken,
        _client = client ?? http.Client(),
        _ownsClient = client == null;

  /// 服务端对齐帧事件类型（`internal/events/bus.go:49`）。
  static const String resyncEventType = 'resync';

  final Uri _baseUrl;
  final String? _userToken;
  final http.Client _client;
  final bool _ownsClient;

  /// 建立连接的超时。
  final Duration connectTimeout;

  /// 保活看门狗：超过该时长无任何字节则视为死连接并报错。
  ///
  /// 服务端每 15s 发一次 `: ping`，故 45s 无字节即可判定链路已死
  /// （`handler.go:343-363`）。
  final Duration heartbeatWatchdog;

  StreamSubscription<String>? _sub;
  Timer? _watchdog;
  Completer<void>? _done;
  bool _closed = false;

  /// 事件流 URL（含 `last_event_id` query）。
  Uri eventUri({
    required String sessionId,
    required String runId,
    int? lastEventId,
  }) {
    final query = <String, String>{
      ..._baseUrl.queryParameters,
      if (lastEventId != null) 'last_event_id': '$lastEventId',
    };
    return _baseUrl.replace(
      path: _joinPath(
        _baseUrl.path,
        '/api/v1/sessions/$sessionId/runs/$runId/events',
      ),
      queryParameters: query.isEmpty ? null : query,
    );
  }

  /// 发起流式订阅。
  ///
  /// 返回的 [Future] 在**流结束或出错时**完成；调用 [close] 可主动中断。
  Future<void> subscribe({
    required String sessionId,
    required String runId,
    int? lastEventId,
    required SseHandlers handlers,
  }) async {
    final uri = eventUri(
      sessionId: sessionId,
      runId: runId,
      lastEventId: lastEventId,
    );

    final request = http.Request('GET', uri)
      ..headers['Accept'] = 'text/event-stream'
      ..headers['Cache-Control'] = 'no-cache';
    final token = _userToken;
    if (token != null && token.isNotEmpty) {
      // 服务端鉴权头形态为裸 token（与 `http_client.dart` 注入方式一致）
      request.headers['Authorization'] = token;
    }
    if (lastEventId != null) {
      // 双通道：EventSource 无法设头，服务端两种都认（handler.go:318-326）
      request.headers['Last-Event-ID'] = '$lastEventId';
    }

    final http.StreamedResponse response;
    try {
      response = await _client.send(request).timeout(connectTimeout);
    } catch (e) {
      handlers.onError?.call(e);
      return;
    }

    if (response.statusCode != 200) {
      final body = await _readAll(response.stream);
      handlers.onError?.call(SseHttpException(response.statusCode, body));
      return;
    }

    final completer = Completer<void>();
    _done = completer;
    _resetWatchdog(handlers);

    _sub = response.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
      (line) => _onLine(line, handlers),
      onError: (Object e) {
        _cancelWatchdog();
        handlers.onError?.call(e);
        _completeDone();
      },
      onDone: () {
        _cancelWatchdog();
        handlers.onDone?.call();
        _completeDone();
      },
      cancelOnError: false,
    );

    try {
      await completer.future;
    } finally {
      _cancelWatchdog();
      _done = null;
    }
  }

  /// 主动关闭连接。
  Future<void> close() async {
    _closed = true;
    _cancelWatchdog();
    await _sub?.cancel();
    _sub = null;
    _completeDone();
  }

  /// 释放底层 http client（仅当本实例自己创建时）。
  void dispose() {
    _cancelWatchdog();
    _completeDone();
    if (_ownsClient) _client.close();
  }

  /// 让 [subscribe] 的 Future 收敛（流结束 / 出错 / 主动关闭三条路径共用）。
  void _completeDone() {
    final done = _done;
    if (done != null && !done.isCompleted) done.complete();
  }

  // ============ 内部：逐行解析 ============

  String? _pendingId;
  String? _pendingType;
  final List<String> _pendingData = [];

  void _onLine(String rawLine, SseHandlers handlers) {
    if (_closed) return;
    _resetWatchdog(handlers);

    // 行尾可能带 \r（部分代理会改写），逐行剥离
    final line = rawLine.endsWith('\r')
        ? rawLine.substring(0, rawLine.length - 1)
        : rawLine;

    // 空行 = 一帧结束（SSE 规范）
    if (line.isEmpty) {
      _dispatch(handlers);
      return;
    }

    // 🔴 关键：注释帧（保活 `: ping`）必须以 ':' 开头整体忽略
    if (line.startsWith(':')) {
      handlers.onComment?.call(line.substring(1).trim());
      return;
    }

    final colon = line.indexOf(':');
    if (colon < 0) {
      // 无冒号字段按规范以空值处理，服务端不会出现，忽略即可
      return;
    }
    final field = line.substring(0, colon);
    var value = line.substring(colon + 1);
    if (value.startsWith(' ')) value = value.substring(1);

    switch (field) {
      case 'id':
        _pendingId = value;
      case 'event':
        _pendingType = value;
      case 'data':
        _pendingData.add(value);
      default:
        // retry / 未知字段：忽略
        break;
    }
  }

  void _dispatch(SseHandlers handlers) {
    if (_pendingData.isEmpty && _pendingId == null && _pendingType == null) {
      return; // 纯空行（连续换行）
    }

    final rawData = _pendingData.join('\n');
    final event = SseEvent(
      id: _pendingId,
      type: _pendingType ?? 'message',
      data: _parseData(rawData),
      rawData: rawData,
    );
    _pendingId = null;
    _pendingType = null;
    _pendingData.clear();

    handlers.onEvent?.call(event);

    if (event.isResync) {
      final lastSeq = _intOf(event.data['last_seq']) ?? event.seq ?? 0;
      handlers.onResync?.call(
        lastSeq,
        event.data['run_status'] as String?,
        event.data['close_reason'] as String?,
      );
    }
  }

  Map<String, dynamic> _parseData(String raw) {
    if (raw.isEmpty) return const {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) return decoded;
      return {'value': decoded};
    } catch (_) {
      return {'raw': raw};
    }
  }

  static int? _intOf(Object? value) {
    if (value == null) return null;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }

  void _resetWatchdog(SseHandlers handlers) {
    _watchdog?.cancel();
    if (heartbeatWatchdog <= Duration.zero) return;
    _watchdog = Timer(heartbeatWatchdog, () {
      if (_closed) return;
      handlers.onError?.call(
        TimeoutException('SSE 保活超时（${heartbeatWatchdog.inSeconds}s 无字节）'),
      );
      unawaited(close());
    });
  }

  void _cancelWatchdog() {
    _watchdog?.cancel();
    _watchdog = null;
  }

  static Future<String> _readAll(Stream<List<int>> stream) async {
    try {
      return await stream.transform(utf8.decoder).join();
    } catch (_) {
      return '';
    }
  }

  static String _joinPath(String base, String path) {
    final b = base.endsWith('/') ? base.substring(0, base.length - 1) : base;
    final p = path.startsWith('/') ? path : '/$path';
    return '$b$p';
  }
}

/// 非 200 响应。
class SseHttpException implements Exception {
  const SseHttpException(this.statusCode, this.body);

  final int statusCode;
  final String body;

  @override
  String toString() => 'SseHttpException($statusCode): $body';
}
