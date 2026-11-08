/// 会话消息流（`/sessions/<sid>`，P6 只读视图）。
///
/// 行为链（对齐服务端 SSE 契约，`handler.go:307-385` + `sse.go:11-39`）：
/// 1. 先拉消息快照 `GET /messages?after_seq=`（缓存渲染在这里天然等价，
///    因为快照本身就是权威数据源，不做二次猜测）；
/// 2. 有活跃 Run 才订阅 `GET /sessions/{sid}/runs/{rid}/events`（SSE）；
/// 3. 收到 `message.end` / `message.appended` 等事件 → **增量重拉快照**
///    （服务端已落库，重拉比端侧拼装流更不易错位）；
/// 4. 收到 `resync` 帧 → **必须重拉快照，不可续接**（服务端已放弃续传）；
/// 5. 无活跃 Run 时不订阅（`active-run` 返回空 run_id 是 200 而非 404，
///    [SessionApi.activeRun] 已归一成 null）。
///
/// 只读铁律：本页不提供发送消息入口（移动端本期定位是遥控器 + 审批）。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app/providers.dart';
import '../../core/error/app_error.dart';
import '../../data/remote/session_api.dart';
import '../../data/ws/sse_client.dart';
import '../shared/ui_helpers.dart';

class SessionMessagesPage extends ConsumerStatefulWidget {
  const SessionMessagesPage({super.key, required this.sessionId});

  final String sessionId;

  @override
  ConsumerState<SessionMessagesPage> createState() =>
      _SessionMessagesPageState();
}

class _SessionMessagesPageState extends ConsumerState<SessionMessagesPage> {
  final List<Message> _messages = <Message>[];
  bool _loading = false;
  String? _error;
  String? _liveRunId;
  SseClient? _sse;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _reload());
  }

  @override
  void dispose() {
    _disposed = true;
    _stopSse();
    super.dispose();
  }

  void _stopSse() {
    final sse = _sse;
    _sse = null;
    if (sse != null) {
      // 主动关闭：立即释放 http client 与看门狗定时器
      unawaited(sse.close());
      sse.dispose();
    }
  }

  /// 拉快照（增量：只取 afterSeq 之后的消息）。
  Future<void> _loadMessages({bool reset = false}) async {
    final services = servicesOf(ref);
    if (services == null) {
      if (!mounted) return;
      setState(() => _error = '请先配置服务端地址');
      return;
    }
    if (reset) _stopSse();
    final afterSeq = reset || _messages.isEmpty ? 0 : _messages.last.seq;

    setState(() {
      _loading = true;
      _error = null;
      if (reset) _messages.clear();
    });
    try {
      final page = await services.sessions.listMessages(
        widget.sessionId,
        afterSeq: afterSeq,
      );
      if (!mounted) return;
      setState(() {
        if (reset) {
          _messages
            ..clear()
            ..addAll(page);
        } else {
          // 服务端可能重复返回边界 seq，按 id 去重
          final known = _messages.map((Message m) => m.id).toSet();
          _messages.addAll(page.where((Message m) => !known.contains(m.id)));
        }
      });
      await _syncLiveRun();
    } on AppError catch (error) {
      if (!mounted) return;
      setState(() => _error = error.displayMessage);
      if (error.isUnauthorized) {
        await ref.read(appSessionProvider).signOut();
      }
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _error = friendlyError(error));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _reload() => _loadMessages(reset: true);

  /// 检查活跃 Run，若变化则重建 SSE 订阅。
  Future<void> _syncLiveRun() async {
    final services = servicesOf(ref);
    if (services == null || _disposed) return;
    ActiveRun? run;
    try {
      run = await services.sessions.activeRun(widget.sessionId);
    } on Object {
      // 探测失败不该打断消息渲染；保持旧订阅即可
      return;
    }
    if (_disposed) return;
    final runId = run?.runId;
    if (runId == _liveRunId) return; // 无变化
    _liveRunId = runId;
    _stopSse();
    if (runId == null || runId.isEmpty) return;
    _subscribe(runId, lastEventId: _messages.isEmpty ? null : _messages.last.seq);
  }

  void _subscribe(String runId, {int? lastEventId}) {
    unawaited(_startSse(runId, lastEventId: lastEventId));
  }

  Future<void> _startSse(String runId, {int? lastEventId}) async {
    final session = ref.read(appSessionProvider);
    // 令牌只在内存中短暂取出，仅用于 Authorization 请求头（红线 R3：绝不打印）
    final token = await ref.read(secureStoreProvider).getUserToken();
    if (_disposed) return;
    final sse = SseClient(
      baseUrl: Uri.parse(session.baseUrl),
      userToken: token,
    );
    _sse = sse;
    unawaited(
      sse.subscribe(
        sessionId: widget.sessionId,
        runId: runId,
        lastEventId: lastEventId,
        handlers: SseHandlers(
          onEvent: (SseEvent event) {
            switch (event.type) {
              case 'message.end':
              case 'message.appended':
              case 'message.start':
              case 'run.status':
                // 落库型事件 → 增量重拉（端侧不拼装流式片段，避免与快照错位）
                unawaited(_loadMessages());
              default:
                break;
            }
          },
          onResync: (int lastSeq, String? runStatus, String? closeReason) {
            // 服务端已放弃续传 → 必须重拉快照
            unawaited(_reload());
          },
          onError: (Object error) {
            if (!mounted) return;
            setState(() => _error = friendlyError(error));
          },
          onDone: () {
            // 流正常结束（Run 终态）→ 重拉一次拿到终态消息
            unawaited(_loadMessages());
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('消息'),
        actions: <Widget>[
          IconButton(
            tooltip: '刷新',
            onPressed: _loading ? null : _reload,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Column(
        children: <Widget>[
          if (_loading) const LinearProgressIndicator(minHeight: 2),
          if (_liveRunId != null)
            Container(
              width: double.infinity,
              color: theme.colorScheme.primaryContainer,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              child: Row(
                children: <Widget>[
                  Icon(Icons.bolt,
                      size: 14, color: theme.colorScheme.onPrimaryContainer),
                  const SizedBox(width: 6),
                  Text(
                    '运行中 · 实时订阅',
                    style: TextStyle(
                      fontSize: 11,
                      color: theme.colorScheme.onPrimaryContainer,
                    ),
                  ),
                ],
              ),
            ),
          if (_error != null)
            Container(
              width: double.infinity,
              color: theme.colorScheme.errorContainer,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(
                _error!,
                style: TextStyle(
                  color: theme.colorScheme.onErrorContainer,
                  fontSize: 12,
                ),
              ),
            ),
          Expanded(child: _buildList(theme)),
        ],
      ),
    );
  }

  Widget _buildList(ThemeData theme) {
    if (_messages.isEmpty) {
      if (_loading) return const LoadingBody(message: '正在加载消息…');
      if (_error != null) {
        return ErrorBody(message: _error!, onRetry: _reload);
      }
      return const EmptyBody(
        icon: Icons.chat_bubble_outline,
        title: '暂无消息',
        hint: '本次会话还没有产生消息',
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      itemCount: _messages.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (BuildContext context, int index) =>
          _MessageBubble(message: _messages[index]),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({required this.message});

  final Message message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isUser = message.role == 'user';
    final isTool = message.role == 'tool';
    final align = isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start;
    final bg = isUser
        ? theme.colorScheme.primaryContainer
        : isTool
            ? theme.colorScheme.surfaceContainerHighest
            : theme.colorScheme.surfaceContainerHigh;

    return Column(
      crossAxisAlignment: align,
      children: <Widget>[
        Text(
          isUser ? '用户' : (isTool ? '工具' : (message.role.isEmpty ? '助手' : message.role)),
          style: theme.textTheme.labelSmall
              ?.copyWith(color: theme.colorScheme.outline),
        ),
        const SizedBox(height: 3),
        Container(
          constraints: const BoxConstraints(maxWidth: 520),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(10),
          ),
          child: SelectableText(
            message.content.isEmpty ? '（空消息）' : message.content,
            style: theme.textTheme.bodyMedium,
          ),
        ),
        if (message.tokenCount > 0) ...<Widget>[
          const SizedBox(height: 2),
          Text(
            '${message.tokenCount} tokens · #${message.seq}',
            style: theme.textTheme.labelSmall
                ?.copyWith(color: theme.colorScheme.outline, fontSize: 10),
          ),
        ],
      ],
    );
  }
}
