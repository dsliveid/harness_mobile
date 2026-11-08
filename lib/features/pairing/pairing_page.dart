/// 设备配对页（`/pairing`，身份链路第二环）。
///
/// 契约铁律（已核实服务端源码）：
/// - `POST /api/v1/devices/pair` **免鉴权**，请求体键集合**必须恰为**
///   `{code,name,kind,platform,app_version,capabilities}`
///   （`device_handler.go:51-58`，`DisallowUnknownFields` 多一键即 400）；
/// - `capabilities` 每项**只允许** `{name,version}`（`device_handler.go:46-49`）；
/// - 本期上报能力集合**有且仅有** `network` + `device`
///   （[MobileCapabilities.declared]，不申报其它能力）；
/// - 成功后 `device_token` 由 [DeviceApi.pair] 直接落 Keychain（红线 R3），
///   本页只把 `device_id` / `device_name` 记进 [AppSession]（非机密）。
///
/// 配对码由服务端管理端/桌面端生成，移动端只**消费**，不自行生成。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/app/app_session.dart';
import '../../core/app/providers.dart';
import '../../data/remote/device_api.dart';
import '../../protocol/frame_payloads.dart' show MobileCapabilities;
import '../shared/ui_helpers.dart';

class PairingPage extends ConsumerStatefulWidget {
  const PairingPage({super.key});

  @override
  ConsumerState<PairingPage> createState() => _PairingPageState();
}

class _PairingPageState extends ConsumerState<PairingPage> {
  final TextEditingController _codeController = TextEditingController();
  final TextEditingController _nameController =
      TextEditingController(text: '我的手机');
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  bool _submitting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final session = ref.read(appSessionProvider);
    if (session.deviceName.isNotEmpty) {
      _nameController.text = session.deviceName;
    }
  }

  @override
  void dispose() {
    _codeController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _pair() async {
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
    final name = _nameController.text.trim();
    try {
      final paired = await services.device.pair(
        code: _codeController.text.trim().toUpperCase(),
        name: name,
        kind: DeviceKinds.mobile,
        // 能力集合恒为 network + device（不申报 workspace.list，本期定案）
        capabilities: MobileCapabilities.declared,
      );
      await ref.read(appSessionProvider).markPaired(
            deviceId: paired.deviceId,
            deviceName: name,
          );
      if (!mounted) return;
      _codeController.clear();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('配对成功，请登录账号')),
      );
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
        title: const Text('配对设备'),
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
              Icons.phonelink_lock_outlined,
              size: 56,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(height: 16),
            Text('输入配对码', style: theme.textTheme.titleMedium),
            const SizedBox(height: 6),
            Text(
              '配对码由服务端桌面端生成（一段时间内有效）。'
              '配对成功后本机会获得设备令牌，令牌只保存于系统安全存储。',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.outline),
            ),
            const SizedBox(height: 20),
            TextFormField(
              controller: _codeController,
              autocorrect: false,
              textCapitalization: TextCapitalization.characters,
              decoration: const InputDecoration(
                labelText: '配对码',
                hintText: '例如 AB12-CD34',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.qr_code_2),
              ),
              validator: (String? value) =>
                  (value ?? '').trim().isEmpty ? '请输入配对码' : null,
              onFieldSubmitted: (_) => _pair(),
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: _nameController,
              decoration: const InputDecoration(
                labelText: '设备名称',
                hintText: '例如 我的手机',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.badge_outlined),
              ),
              validator: (String? value) =>
                  (value ?? '').trim().isEmpty ? '请输入设备名称' : null,
            ),
            const SizedBox(height: 8),
            Text(
              '申报能力：${MobileCapabilities.declared.map((c) => c.name).join(' + ')}'
              '（不含本机命令执行能力）',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.outline),
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
              onPressed: _submitting ? null : _pair,
              icon: _submitting
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.link),
              label: Text(_submitting ? '配对中…' : '完成配对'),
            ),
            const SizedBox(height: 24),
            if (session.paired)
              Card(
                elevation: 0,
                color: theme.colorScheme.surfaceContainerHighest,
                child: ListTile(
                  leading: const Icon(Icons.verified_outlined),
                  title: const Text('本机已配对'),
                  subtitle: Text(
                    '${session.deviceName}（${session.deviceId}）\n'
                    '如需换机请先在设置页解绑',
                  ),
                  isThreeLine: true,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
