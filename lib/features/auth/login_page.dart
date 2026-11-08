/// 账号登录页（`/login`，身份链路第三环）。
///
/// 契约铁律（已核实 `auth_handler.go:65-84`）：
/// - `POST /api/v1/auth/login` **免鉴权**，请求体键集合**恰为**
///   `{username, password}`（`DisallowUnknownFields` 多一键即 400）；
/// - 响应 `{user:{...}, token:"..."}` —— **单令牌模型，无 refresh 端点**，
///   故这里不存在「记住登录/自动续期」语义，401 一律回本页；
/// - 令牌由 [AuthApi.login] 直接落 Keychain（红线 R3），本页不持有明文。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/app/app_session.dart';
import '../../core/app/providers.dart';
import '../../core/error/app_error.dart';
import '../shared/ui_helpers.dart';

class LoginPage extends ConsumerStatefulWidget {
  const LoginPage({super.key});

  @override
  ConsumerState<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends ConsumerState<LoginPage> {
  final TextEditingController _username = TextEditingController();
  final TextEditingController _password = TextEditingController();
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  bool _submitting = false;
  bool _obscure = true;
  String? _error;

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final services = servicesOf(ref);
    if (services == null) {
      setState(() => _error = '请先配置服务端地址');
      return;
    }

    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final user = await services.auth.login(
        username: _username.text.trim(),
        password: _password.text,
      );
      await ref.read(appSessionProvider).markSignedIn();
      if (!mounted) return;
      _password.clear();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '已登录 ${user.displayName.isEmpty ? user.username : user.displayName}',
          ),
        ),
      );
    } on AppError catch (error) {
      if (!mounted) return;
      // R7：服务端 message 原样透出（invalid_credentials / rate_limited 等可区分）
      setState(() => _error = error.displayMessage);
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _error = friendlyError(error));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final session = ref.watch(appSessionProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('登录账号'),
        actions: <Widget>[
          IconButton(
            tooltip: '服务端设置',
            onPressed: () => context.push(AppRoutes.setup),
            icon: const Icon(Icons.settings_outlined),
          ),
        ],
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: <Widget>[
            Icon(
              Icons.account_circle_outlined,
              size: 56,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(height: 16),
            Text('登录 harness 账号', style: theme.textTheme.titleMedium),
            const SizedBox(height: 6),
            Text(
              '设备已配对（${session.deviceName.isEmpty ? '未命名设备' : session.deviceName}），'
              '登录后可查看并审批待办。',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.outline),
            ),
            const SizedBox(height: 20),
            TextFormField(
              controller: _username,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: '用户名',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.person_outline),
              ),
              validator: (String? value) =>
                  (value ?? '').trim().isEmpty ? '请输入用户名' : null,
              onFieldSubmitted: (_) => _login(),
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: _password,
              obscureText: _obscure,
              decoration: InputDecoration(
                labelText: '密码',
                border: const OutlineInputBorder(),
                prefixIcon: const Icon(Icons.lock_outline),
                suffixIcon: IconButton(
                  tooltip: _obscure ? '显示密码' : '隐藏密码',
                  onPressed: () => setState(() => _obscure = !_obscure),
                  icon: Icon(
                    _obscure ? Icons.visibility_outlined : Icons.visibility_off,
                  ),
                ),
              ),
              validator: (String? value) =>
                  (value ?? '').isEmpty ? '请输入密码' : null,
              onFieldSubmitted: (_) => _login(),
            ),
            if (_error != null) ...<Widget>[
              const SizedBox(height: 14),
              Text(
                _error!,
                style: TextStyle(color: theme.colorScheme.error, fontSize: 13),
              ),
            ],
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: _submitting ? null : _login,
              icon: _submitting
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.login),
              label: Text(_submitting ? '登录中…' : '登录'),
            ),
            const SizedBox(height: 20),
            OutlinedButton.icon(
              onPressed: () async {
                final messenger = ScaffoldMessenger.of(context);
                await ref.read(appSessionProvider).resetPairing();
                messenger.showSnackBar(
                  const SnackBar(content: Text('已解绑设备，请重新配对')),
                );
              },
              icon: const Icon(Icons.link_off),
              label: const Text('换一台设备 / 重新配对'),
            ),
          ],
        ),
      ),
    );
  }
}
