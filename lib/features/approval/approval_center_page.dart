/// 审批中心首屏（`/approvals`，架构 §0.1 首屏铁律）。
///
/// 数据来源：`ApprovalRepository.loadPendingApprovals`（N+1 拼装，内部已做
/// 本地标记过滤 + 并发上限），本页只负责「渲染 / 交互 / 错误分派」。
///
/// 三条交互铁律：
/// 1. **缓存优先**：进页立刻用上次成功列表渲染，再后台刷新；弱网下不会白屏。
/// 2. **高风险需生物识别**：`command` / `danger` 必须先过 [BiometricGate]，
///    fail-closed（拿不到结果即拒绝），绝不默认放行。
/// 3. **RequiredDeviceID 拦截（红线 R5）**：服务端把审批绑定到执行端设备，
///    非该设备决策返回 403 `approval.device_mismatch`。端侧**不得就地把该审批
///    标记为已批准**，而是锁定该行并提示「需在指定设备确认」。
///    ⚠️ 该字段只出现在 `approval.request` 事件 payload 里，`tool-events` 响应
///    （`model.ToolEvent`）**不落此字段**，故端侧唯一可靠判定就是决策响应本身。
/// 4. **幂等**：多人同时审批时首个决策胜出，后来者收到
///    `approval.already_decided`；此时不报错弹窗，静默刷新列表即可。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/app/app_session.dart';
import '../../core/app/providers.dart';
import '../../core/error/app_error.dart';
import '../../data/remote/approval_api.dart';
import '../../domain/repositories/approval_repository.dart';
import '../shared/ui_helpers.dart';

/// 上次成功拉取的待审批列表（缓存优先渲染的唯一来源）。
///
/// 刻意用 [StateProvider] 而非 AsyncNotifier：本页生命周期就是全部状态，
/// 没有跨页共享需求，缓存只需要「进程内存里留一份上次快照」。
final StateProvider<List<PendingApproval>> pendingApprovalsCacheProvider =
    StateProvider<List<PendingApproval>>(
  (Ref ref) => const <PendingApproval>[],
);

class ApprovalCenterPage extends ConsumerStatefulWidget {
  const ApprovalCenterPage({super.key});

  @override
  ConsumerState<ApprovalCenterPage> createState() => _ApprovalCenterPageState();
}

class _ApprovalCenterPageState extends ConsumerState<ApprovalCenterPage> {
  bool _loading = false;
  String? _error;

  /// 正在提交决策的审批 ID（按钮置灰，防连点造成重复请求）。
  final Set<String> _deciding = <String>{};

  /// 被服务端拒绝「需在指定设备确认」的审批（红线 R5，锁定该行）。
  final Set<String> _lockedToOtherDevice = <String>{};

  @override
  void initState() {
    super.initState();
    // 首帧后再拉：避免 initState 里直接读 ref 造成生命周期告警。
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
      final items = await services.repository.loadPendingApprovals();
      if (!mounted) return;
      // 已被其他人处理掉的审批不要在本地缓存里滞留
      _lockedToOtherDevice.removeWhere(
        (String id) => !items.any((PendingApproval item) => item.approvalId == id),
      );
      ref.read(pendingApprovalsCacheProvider.notifier).state = items;
    } on AppError catch (error) {
      if (!mounted) return;
      setState(() => _error = error.displayMessage);
      // 未登录/令牌失效：直接踢回登录页，不留在审批中心空转
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

  /// 提交决策（含生物识别前置与错误分派）。
  Future<void> _decide(
    PendingApproval item,
    String decision,
  ) async {
    final services = servicesOf(ref);
    if (services == null) {
      _toast('请先配置服务端地址');
      return;
    }
    final session = ref.read(appSessionProvider);
    if (session.deviceId.isEmpty) {
      _toast('本机尚未配对，无法作为决策设备');
      return;
    }

    // ① 高风险 → 生物识别（fail-closed）
    if (item.isHighRisk) {
      final passed = await ref.read(biometricGateProvider).authenticate(
            reason: '确认${decision == ApprovalDecisions.deny ? '拒绝' : '放行'}'
                '高风险操作：${item.toolName}',
          );
      if (!passed) {
        if (!mounted) return;
        _toast('未通过生物识别，操作已取消');
        return;
      }
      if (!mounted) return;
    }

    setState(() => _deciding.add(item.approvalId));
    try {
      await services.approvals.decide(
        sessionId: item.sessionId,
        runId: item.runId,
        approvalId: item.approvalId,
        decision: decision,
        deviceId: session.deviceId,
      );
      if (!mounted) return;
      _toast(decision == ApprovalDecisions.deny ? '已拒绝' : '已放行');
      await _refresh();
    } on AppError catch (error) {
      if (!mounted) return;
      if (error.isApprovalDeviceMismatch) {
        // 红线 R5：绝不就地放行，锁定该行并要求在指定设备确认
        setState(() => _lockedToOtherDevice.add(item.approvalId));
        _toast('该审批需在指定设备上确认，本机无权决策');
      } else if (error.isApprovalAlreadyDecided) {
        // 幂等：他人已决策 → 静默刷新，不弹错误
        _toast('该审批已被处理，列表已刷新');
        await _refresh();
      } else if (error.isDeviceRevoked) {
        _toast('本设备已被解绑，请重新配对');
        await ref.read(appSessionProvider).resetPairing();
      } else if (error.isUnauthorized) {
        _toast('登录已失效，请重新登录');
        await ref.read(appSessionProvider).signOut();
      } else {
        _toast(error.displayMessage);
      }
    } on Object catch (error) {
      if (!mounted) return;
      _toast(friendlyError(error));
    } finally {
      if (mounted) setState(() => _deciding.remove(item.approvalId));
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final List<PendingApproval> cached = ref.watch(pendingApprovalsCacheProvider);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('审批中心'),
        actions: <Widget>[
          IconButton(
            tooltip: '刷新',
            onPressed: _loading ? null : _refresh,
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: '会话',
            onPressed: () => context.push(AppRoutes.sessions),
            icon: const Icon(Icons.forum_outlined),
          ),
          PopupMenuButton<String>(
            onSelected: (String value) async {
              if (value == 'settings') {
                if (!mounted) return;
                await context.push(AppRoutes.setup);
              } else if (value == 'logout') {
                final services = servicesOf(ref);
                if (services != null) {
                  await services.auth.logout();
                }
                await ref.read(appSessionProvider).signOut();
              }
            },
            itemBuilder: (BuildContext context) => const <PopupMenuEntry<String>>[
              PopupMenuItem<String>(value: 'settings', child: Text('服务端设置')),
              PopupMenuItem<String>(value: 'logout', child: Text('退出登录')),
            ],
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: _buildBody(theme, cached),
      ),
    );
  }

  Widget _buildBody(ThemeData theme, List<PendingApproval> cached) {
    // 缓存优先：有缓存就直接渲染列表（刷新时用顶部细进度条提示，不遮挡内容）
    if (cached.isEmpty) {
      if (_loading) return const LoadingBody(message: '正在加载待审批项…');
      if (_error != null) {
        return ErrorBody(message: _error!, onRetry: _refresh);
      }
      return ListView(
        // 必须可滚动，否则 RefreshIndicator 拉不动
        physics: const AlwaysScrollableScrollPhysics(),
        children: const <Widget>[
          SizedBox(height: 90),
          EmptyBody(
            icon: Icons.task_alt,
            title: '暂无待审批项',
            hint: '有工具调用需要确认时会出现在这里，下拉可刷新',
          ),
        ],
      );
    }

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
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            itemCount: cached.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (BuildContext context, int index) {
              final item = cached[index];
              return _ApprovalCard(
                item: item,
                deciding: _deciding.contains(item.approvalId),
                lockedToOtherDevice:
                    _lockedToOtherDevice.contains(item.approvalId),
                onAllowOnce: () => _decide(item, ApprovalDecisions.allowOnce),
                onAllowSession: () =>
                    _decide(item, ApprovalDecisions.allowSession),
                onDeny: () => _decide(item, ApprovalDecisions.deny),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _ApprovalCard extends StatelessWidget {
  const _ApprovalCard({
    required this.item,
    required this.deciding,
    required this.lockedToOtherDevice,
    required this.onAllowOnce,
    required this.onAllowSession,
    required this.onDeny,
  });

  final PendingApproval item;
  final bool deciding;
  final bool lockedToOtherDevice;
  final VoidCallback onAllowOnce;
  final VoidCallback onAllowSession;
  final VoidCallback onDeny;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bool blocked = deciding || lockedToOtherDevice;

    return Card(
      elevation: 0,
      clipBehavior: Clip.antiAlias,
      color: theme.colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    '${item.namespace.isEmpty ? '' : '${item.namespace}.'}'
                    '${item.toolName}',
                    style: theme.textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.w600),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                RiskChip(risk: item.risk),
              ],
            ),
            if (item.sessionTitle.isNotEmpty) ...<Widget>[
              const SizedBox(height: 4),
              Text(
                '会话：${item.sessionTitle}',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.outline),
                overflow: TextOverflow.ellipsis,
              ),
            ],
            if (item.argsDigest.isNotEmpty) ...<Widget>[
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surface,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  item.argsDigest,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(fontFamily: 'monospace', fontSize: 11.5),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
            const SizedBox(height: 8),
            Row(
              children: <Widget>[
                Text(
                  formatRelativeTime(item.createdAt),
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.outline),
                ),
                if (item.isHighRisk) ...<Widget>[
                  const SizedBox(width: 10),
                  Icon(Icons.fingerprint,
                      size: 14, color: theme.colorScheme.outline),
                  const SizedBox(width: 2),
                  Text(
                    '需生物识别',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.outline),
                  ),
                ],
                const Spacer(),
                if (deciding)
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
            if (lockedToOtherDevice) ...<Widget>[
              const SizedBox(height: 8),
              Row(
                children: <Widget>[
                  Icon(Icons.lock_outline,
                      size: 14, color: theme.colorScheme.error),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '该审批需在指定设备上确认',
                      style: TextStyle(
                        fontSize: 12,
                        color: theme.colorScheme.error,
                      ),
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 4),
            OverflowBar(
              alignment: MainAxisAlignment.end,
              spacing: 8,
              children: <Widget>[
                TextButton(
                  onPressed: blocked ? null : onDeny,
                  child: const Text('拒绝'),
                ),
                TextButton(
                  onPressed: blocked ? null : onAllowSession,
                  child: const Text('本会话允许'),
                ),
                FilledButton(
                  onPressed: blocked ? null : onAllowOnce,
                  child: const Text('本次允许'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
