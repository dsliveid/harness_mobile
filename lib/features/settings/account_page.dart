/// 账号页（`/account`，由主会话整合进路由表）。
///
/// 契约事实（已核实服务端 `router.go:40-44`）：**没有账号注销端点**，
/// 只有 login / sso / me / logout / password。但 App Store 审核要求 App 内
/// 必须提供账号删除入口，因此这里做**诚实的降级方案**：
///
/// - 「解除本机绑定」→ 清设备身份 + 全部本地凭据，回到配对页（端侧能做，直接做）
/// - 「退出登录」→ 清用户令牌（端侧能做，直接做）
/// - 「注销账号」→ 明确告知「账号数据的删除需在 Web 端完成」，并给出 Web 端地址
///   与一键复制，绝不假装已经删号（诱导用户误以为数据已被清除是更严重的问题）。
///
/// 三个危险操作全部走二次确认对话框。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/app/app_session.dart';
import '../../core/app/device_unbind.dart';
import '../../core/app/providers.dart';
import '../../data/remote/auth_api.dart';
import '../shared/ui_helpers.dart';
import '../shared/web_entry.dart';

class AccountPage extends ConsumerStatefulWidget {
  const AccountPage({super.key});

  @override
  ConsumerState<AccountPage> createState() => _AccountPageState();
}

class _AccountPageState extends ConsumerState<AccountPage> {
  bool _loading = true;
  bool _busy = false;
  AuthUser? _user;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadUser());
  }

  /// 拉取当前账号信息。失败不算致命（弱网时展示占位即可，不影响下面的操作）。
  Future<void> _loadUser() async {
    final services = servicesOf(ref);
    if (services == null) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '尚未配置服务端地址';
      });
      return;
    }
    try {
      final user = await services.auth.me();
      if (!mounted) return;
      setState(() {
        _user = user;
        _loading = false;
        _error = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '账号信息暂时获取不到：${friendlyError(error)}';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final session = ref.watch(appSessionProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('账号')),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 12),
        children: <Widget>[
          _header(theme, session),
          const Divider(height: 28),
          _sectionTitle(theme, '本机身份'),
          _row('服务端地址', session.baseUrl.isEmpty ? '未配置' : session.baseUrl),
          _row(
            '本机设备',
            session.deviceName.isEmpty
                ? (session.deviceId.isEmpty ? '未配对' : session.deviceId)
                : session.deviceName,
          ),
          _row('设备 ID', session.deviceId.isEmpty ? '未配对' : session.deviceId),
          _row('登录状态', session.signedIn ? '已登录' : '未登录'),
          const Divider(height: 28),
          _sectionTitle(theme, '账号操作'),
          ListTile(
            leading: const Icon(Icons.phonelink_erase_outlined),
            title: const Text('解除本机绑定'),
            subtitle: const Text('清除设备身份与全部本地凭据，解绑会同时退出登录'),
            trailing: const Icon(Icons.chevron_right),
            enabled: !_busy,
            onTap: _confirmResetPairing,
          ),
          ListTile(
            leading: const Icon(Icons.logout),
            title: const Text('退出登录'),
            subtitle: const Text('保留设备绑定，返回登录页'),
            trailing: const Icon(Icons.chevron_right),
            enabled: !_busy,
            onTap: _confirmSignOut,
          ),
          ListTile(
            leading: Icon(
              Icons.delete_forever_outlined,
              color: theme.colorScheme.error,
            ),
            title: Text(
              '注销账号',
              style: TextStyle(color: theme.colorScheme.error),
            ),
            subtitle: const Text('账号数据的删除需在 Web 端完成'),
            trailing: const Icon(Icons.chevron_right),
            enabled: !_busy,
            onTap: _showDeleteAccountGuide,
          ),
          const SizedBox(height: 20),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              '本 App 不缓存账号数据副本；退出登录或解除绑定后，本机不再保留任何令牌。',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.outline),
            ),
          ),
          const SizedBox(height: 28),
        ],
      ),
    );
  }

  Widget _header(ThemeData theme, AppSession session) {
    final user = _user;
    final name = (user?.displayName.isNotEmpty ?? false)
        ? user!.displayName
        : (user != null && user.username.isNotEmpty ? user.username : '未获取到账号信息');
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: <Widget>[
          CircleAvatar(
            radius: 26,
            backgroundColor: theme.colorScheme.primaryContainer,
            child: Icon(
              Icons.person_outline,
              color: theme.colorScheme.onPrimaryContainer,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(name, style: theme.textTheme.titleMedium),
                const SizedBox(height: 4),
                Text(
                  _loading
                      ? '正在加载账号信息…'
                      : (user != null && user.username.isNotEmpty
                          ? '@${user.username}'
                              '${user.role.isEmpty ? '' : ' · ${user.role}'}'
                          : (_error ?? '账号信息不可用')),
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.outline),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: '刷新',
            onPressed: _loading ? null : _loadUser,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
    );
  }

  Widget _sectionTitle(ThemeData theme, String text) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
        child: Text(
          text,
          style: theme.textTheme.labelLarge
              ?.copyWith(color: theme.colorScheme.primary),
        ),
      );

  Widget _row(String label, String value) => ListTile(
        dense: true,
        title: Text(label),
        trailing: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 220),
          child: Text(
            value,
            textAlign: TextAlign.right,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      );

  /// 注销账号降级指引（**不是**删除接口，文案必须诚实）。
  Future<void> _showDeleteAccountGuide() async {
    final baseUrl = ref.read(appSessionProvider).baseUrl;
    final webUrl = webEntryUrl(baseUrl);
    await showDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('注销账号'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text('账号数据的删除需在 Web 端完成。'),
            const SizedBox(height: 10),
            const Text(
              '为保障数据安全，服务端只在经过身份校验的 Web 会话里执行账号删除；'
              '本 App 仅提供入口指引，不会在此处伪造删除结果。',
            ),
            const SizedBox(height: 14),
            SelectableText(
              webUrl.isEmpty ? '尚未配置服务端地址，请先在设置页填写。' : webUrl,
              style: Theme.of(dialogContext).textTheme.bodyMedium,
            ),
            if (webUrl.isNotEmpty) ...<Widget>[
              const SizedBox(height: 8),
              const Text('步骤：在浏览器打开上面的地址 → 登录同一账号 → 进入账号设置 → 删除账号。'),
            ],
          ],
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('知道了'),
          ),
          if (webUrl.isNotEmpty)
            FilledButton.icon(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: webUrl));
                if (!dialogContext.mounted) return;
                Navigator.of(dialogContext).pop();
                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Web 端地址已复制')),
                );
              },
              icon: const Icon(Icons.copy_all_outlined),
              label: const Text('复制地址'),
            ),
        ],
      ),
    );
  }

  Future<void> _confirmResetPairing() async {
    final ok = await _confirm(
      title: '解除本机绑定？',
      // 断言的实现事实：resetPairing() 内部调 clearAll()，设备令牌与用户
      // 令牌一起被抹掉 → 解绑**必然**同时退出登录。文案必须诚实告知，
      // 否则用户会以为解绑后还能保持登录态。
      message: '将清除设备身份与全部本地凭据（包括登录令牌，解绑会同时退出登录），'
          '之后需要重新配对才能继续使用。',
      confirmText: '解除绑定',
    );
    if (!ok) return;

    bool notified = true;
    await _runBusy(() async {
      // 🔴 顺序：**先通知服务端**（unpair 的凭据就是 device_token，一旦
      // 清本地就再也拿不到），再按既有顺序停 WS → 清 Cookie → 清令牌。
      // unpair 失败不阻断本地解绑（本地凭据一清，用户意图即达成），
      // 只把提示文案降级为「未能通知服务端」。
      notified = await unbindThisDevice(ref);
    }, successText: () => notified
        ? '已解除本机绑定'
        : '已解除本机绑定，但未能通知服务端');
  }

  Future<void> _confirmSignOut() async {
    final ok = await _confirm(
      title: '退出登录？',
      message: '将清除本机保存的登录令牌，设备绑定保留。',
      confirmText: '退出登录',
    );
    if (!ok) return;

    await _runBusy(() async {
      final services = servicesOf(ref);
      if (services != null) {
        // 服务端登出失败不阻塞本地登出（用户意图是「我下线了」）。
        try {
          await services.auth.logout();
        } catch (_) {
          // 忽略：本地令牌由 session.signOut 统一清除
        }
      }
      // 登出同样要清 WebView Cookie：否则 Web UI 仍带着上一个账号的会话，
      // 而原生侧已显示「未登录」，两侧状态不一致。
      await ref.read(webViewCookieSinkProvider).clearSessionCookies();
      // signOut 只清 user_token，保留 device_token（设备绑定与长连接不受影响）。
      await ref.read(appSessionProvider).signOut();
    }, successText: () => '已退出登录');
  }

  Future<bool> _confirm({
    required String title,
    required String message,
    required String confirmText,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(confirmText),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  /// 统一执行一次危险操作。
  ///
  /// [successText] 刻意支持**回调**而不只是字符串：解绑的提示文案取决于
  /// 「有没有成功通知服务端」（成功 → 「已解除本机绑定」；失败 → 追加
  /// 「但未能通知服务端」）。文案必须诚实，绝不能两种情况都报同一句。
  Future<void> _runBusy(
    Future<void> Function() action, {
    required String Function() successText,
  }) async {
    setState(() => _busy = true);
    try {
      await action();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(successText())),
      );
      final router = GoRouter.maybeOf(context);
      // 身份已变 → 由 app.dart 的 redirect 重新裁决落点；无路由上下文时不强跳。
      if (router != null) {
        router.go(AppRoutes.splash);
      }
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(friendlyError(error))),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}
