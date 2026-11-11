/// 服务端地址配置页（`/setup`，身份链路第一环）。
///
/// 设计要点：
/// - 地址**先本地归一化再保存**（[normalizeBaseUrl] 纯函数，已单测覆盖），
///   非法输入不发请求，直接就地报错；
/// - 「保存」与「测试连接」分离：弱网下先存后测才不会丢配置；
/// - 测试连接打的是免鉴权 `/healthz`，未登录也能验证地址正确性。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/app/app_session.dart';
import '../../core/app/device_unbind.dart';
import '../../core/app/providers.dart';
import '../../core/config/base_url.dart';
import '../shared/ui_helpers.dart';

class SetupPage extends ConsumerStatefulWidget {
  const SetupPage({super.key});

  @override
  ConsumerState<SetupPage> createState() => _SetupPageState();
}

class _SetupPageState extends ConsumerState<SetupPage> {
  late final TextEditingController _controller;
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  bool _testing = false;
  String? _probeMessage;
  bool _probeOk = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(
      text: ref.read(appSessionProvider).baseUrl,
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final normalized = normalizeBaseUrl(_controller.text);
    try {
      await ref.read(appSessionProvider).saveBaseUrl(normalized);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已保存服务端地址：$normalized')),
      );
      _continueAfterSave();
    } on ArgumentError {
      // saveBaseUrl 的非法地址兜底（validate 已拦一层，这里防手动绕过）
      _showError('服务端地址不合法');
    }
  }

  /// 保存成功后推进到「当前阶段」对应的页面（**必须显式导航**，不能只靠 redirect）。
  ///
  /// 为什么不能依赖 go_router 的 redirect 自动跳转：
  /// `app.dart` 里有一条 `location == /setup && target != /setup → return null`
  /// 的白名单，它的职责是「已配对用户从 WebView/配对页 push 进来改地址时，
  /// 不要被立刻弹回」——但它同时也会让「保存成功应当前进」失效，
  /// 用户点完「保存并继续」就停在原页（真机实测踩中）。
  ///
  /// 为什么统一用 `go(target)` 而不用「canPop 就 pop」：
  /// 实测在 `await` 之后再 `context.pop()` 存在「栈没变、页面没动」的失败场景
  /// （refreshListenable 已因 baseUrl 变化重建过一次导航栈），
  /// 而 `go(target)` 的目标由阶段唯一决定，对两种入口都正确：
  /// - 启动即落在 /setup（入口态）→ 前进到 /pairing；
  /// - 从 /webview 或 /pairing push 进来 → 回到那两页本身，效果与 pop 相同。
  void _continueAfterSave() {
    final target = pathOfStage(ref.read(appSessionProvider).stage);
    if (target == AppRoutes.setup) return; // 理论上不可达：已保存地址必不为 setup
    context.go(target);
  }

  Future<void> _testConnection() async {
    final normalized = normalizeBaseUrl(_controller.text);
    if (normalized.isEmpty) {
      _showError('请先填写合法的服务端地址');
      return;
    }
    setState(() {
      _testing = true;
      _probeMessage = null;
    });
    try {
      final factory = ref.read(apiFactoryProvider);
      final health = await factory.forBaseUrl(normalized).probeHealth();
      if (!mounted) return;
      setState(() {
        _probeOk = health.isOk;
        _probeMessage = health.isOk
            ? '连接成功 · 服务端 v${health.version}'
                '${health.protocolVersion != null ? ' · 协议 v${health.protocolVersion}' : ''}'
            : '连通但服务端状态异常：${health.status}';
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _probeOk = false;
        _probeMessage = friendlyError(error);
      });
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final session = ref.watch(appSessionProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('连接服务端')),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: <Widget>[
            Icon(
              Icons.dns_outlined,
              size: 56,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(height: 16),
            Text('填写 harness 服务端地址', style: theme.textTheme.titleMedium),
            const SizedBox(height: 6),
            Text(
              '例如 http://192.168.1.10:8080 。不写协议时默认 http；'
              '服务端挂在子路径也可以（如 https://host/harness）。',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.outline),
            ),
            const SizedBox(height: 14),
            // —— 本地调试地址指引（自用场景最高频的困惑点）——
            Card(
              margin: EdgeInsets.zero,
              color: theme.colorScheme.surfaceContainerHighest,
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Icon(Icons.lightbulb_outline,
                            size: 18, color: theme.colorScheme.primary),
                        const SizedBox(width: 6),
                        Text('手机连本机服务端怎么填？',
                            style: theme.textTheme.labelLarge),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      // 关键：手机上的 localhost 指手机自己，不是你的电脑
                      '· 真机 + 同一 WiFi：填电脑的局域网 IP，如 http://192.168.1.10:8080\n'
                      '· 真机 + USB 线：先在电脑执行 adb reverse tcp:8080 tcp:8080，再填 http://localhost:8080\n'
                      '· Android 模拟器：填 http://10.0.2.2:8080（模拟器访问电脑的专用别名）\n'
                      '· 手机自己跑服务端：填 http://127.0.0.1:8080',
                      style: theme.textTheme.bodySmall?.copyWith(height: 1.6),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '注意：手机上的 localhost 指手机本身，不是你的电脑。'
                      '另外服务端需监听 0.0.0.0（而非仅 127.0.0.1），否则真机连不上。',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.error,
                        height: 1.5,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),
            TextFormField(
              controller: _controller,
              autocorrect: false,
              keyboardType: TextInputType.url,
              textInputAction: TextInputAction.done,
              decoration: const InputDecoration(
                labelText: '服务端地址',
                hintText: 'http://192.168.1.10:8080',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.link),
              ),
              validator: (String? value) {
                final normalized = normalizeBaseUrl(value ?? '');
                if (normalized.isEmpty) return '请输入合法的 http/https 地址';
                return null;
              },
              onFieldSubmitted: (_) => _save(),
            ),
            const SizedBox(height: 16),
            Row(
              children: <Widget>[
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _save,
                    icon: const Icon(Icons.check),
                    label: const Text('保存并继续'),
                  ),
                ),
                const SizedBox(width: 12),
                OutlinedButton.icon(
                  onPressed: _testing ? null : _testConnection,
                  icon: _testing
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.wifi_tethering),
                  label: const Text('测试连接'),
                ),
              ],
            ),
            if (_probeMessage != null) ...<Widget>[
              const SizedBox(height: 16),
              _ProbeBanner(ok: _probeOk, message: _probeMessage!),
            ],
            if (session.paired) ...<Widget>[
              const SizedBox(height: 28),
              const Divider(),
              const SizedBox(height: 12),
              Text('已绑定的设备', style: theme.textTheme.titleSmall),
              const SizedBox(height: 6),
              Text(
                '${session.deviceName.isEmpty ? '未命名设备' : session.deviceName}'
                '（${session.deviceId}）',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: () async {
                  // 与账号页 / 登录页共用同一套解绑流程：先通知服务端
                  // （凭 device_token），再停 WS → 清 Cookie → 清令牌。
                  final notified = await unbindThisDevice(ref);
                  if (!mounted) return;
                  _showError(
                    notified
                        ? '已解绑本机设备，请重新配对'
                        : '已解绑本机设备，但未能通知服务端，请重新配对',
                  );
                },
                icon: const Icon(Icons.link_off),
                label: const Text('解绑本机设备'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ProbeBanner extends StatelessWidget {
  const _ProbeBanner({required this.ok, required this.message});

  final bool ok;
  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = ok ? Colors.green.shade700 : scheme.error;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(ok ? Icons.check_circle_outline : Icons.error_outline,
              size: 18, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(message, style: TextStyle(color: color, fontSize: 13)),
          ),
        ],
      ),
    );
  }
}
