/// 会话列表（`/sessions`，P6 只读视图）。
///
/// 数据源：`SessionApi.listSessions`（服务端默认排序，移动端取最近 50 条）。
/// 只读铁律：移动端**不做**会话管理（新建/归档/删除均无入口），
/// 避免弱网下产生「以为删掉了其实没删」的错觉。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/app/app_session.dart';
import '../../core/app/providers.dart';
import '../../core/error/app_error.dart';
import '../../data/remote/session_api.dart';
import '../shared/ui_helpers.dart';

/// 上次成功拉取的会话列表（缓存优先渲染）。
final StateProvider<List<Session>> sessionListCacheProvider =
    StateProvider<List<Session>>((Ref ref) => const <Session>[]);

class SessionListPage extends ConsumerStatefulWidget {
  const SessionListPage({super.key});

  @override
  ConsumerState<SessionListPage> createState() => _SessionListPageState();
}

class _SessionListPageState extends ConsumerState<SessionListPage> {
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
  }

  Future<void> _refresh() async {
    final services = servicesOf(ref);
    if (services == null) {
      setState(() => _error = '请先配置服务端地址');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final items = await services.sessions.listSessions();
      if (!mounted) return;
      ref.read(sessionListCacheProvider.notifier).state = items;
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

  @override
  Widget build(BuildContext context) {
    final List<Session> cached = ref.watch(sessionListCacheProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('会话'),
        actions: <Widget>[
          IconButton(
            tooltip: '刷新',
            onPressed: _loading ? null : _refresh,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: RefreshIndicator(onRefresh: _refresh, child: _buildBody(cached)),
    );
  }

  Widget _buildBody(List<Session> cached) {
    if (cached.isEmpty) {
      if (_loading) return const LoadingBody(message: '正在加载会话…');
      if (_error != null) return ErrorBody(message: _error!, onRetry: _refresh);
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: const <Widget>[
          SizedBox(height: 90),
          EmptyBody(
            icon: Icons.forum_outlined,
            title: '暂无会话',
            hint: '在桌面端发起对话后，这里会出现会话记录',
          ),
        ],
      );
    }

    final theme = Theme.of(context);
    return Column(
      children: <Widget>[
        if (_loading) const LinearProgressIndicator(minHeight: 2),
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
        Expanded(
          child: ListView.separated(
            physics: const AlwaysScrollableScrollPhysics(),
            itemCount: cached.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (BuildContext context, int index) {
              final session = cached[index];
              return ListTile(
                title: Text(
                  session.title.isEmpty ? '（无标题会话）' : session.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  '${session.messageCount} 条消息 · '
                  '${formatRelativeTime(session.lastMessageAt ?? session.updatedAt)}'
                  '${session.lastRunStatus == null ? '' : ' · ${session.lastRunStatus}'}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: session.mayNeedApproval
                    ? Icon(Icons.gavel_outlined,
                        size: 18, color: theme.colorScheme.error)
                    : const Icon(Icons.chevron_right, size: 18),
                onTap: () => context.push(AppRoutes.sessionMessages(session.id)),
              );
            },
          ),
        ),
      ],
    );
  }
}
