/// 「我的设备」实时区块（账号页内的**唯一** SSE 消费点）。
///
/// # 为什么单独成一个 widget 而不是塞进账号页
/// 关注点分离：账号页负责「身份 + 危险操作」，本文件只负责「设备在线状态」。
/// 两者数据来源、刷新节奏、失败影响都完全不同（账号信息 5 分钟不变，
/// 设备在线态 15 秒就可能变），混在一个 State 里必然出现
/// 「设备上下线导致整页重建 / 账号信息跟着闪」。
///
/// # 门控（`docs/protocols.md` §4.4 第 1 条，铁律）
/// **必须先拉首屏 `GET /api/v1/devices`，落地后才允许建 SSE 连接。**
/// 反过来的话，首屏结果与 `snapshot` 帧会交错覆盖（谁后到谁赢），
/// 表现为「列表随机少一台设备 / 闪一下」。
///
/// 因此本 widget 的顺序被写死为：
/// ```
/// initState → GET /devices → markFirstListReady(items)（内部开闸并建连）
/// ```
/// 绝不允许「先建连、后补首屏」。
///
/// # 实时性如何体现（用户可见）
/// - 其他端的设备上线 / 离线 → 本页行项状态**无需刷新**即变化；
/// - 设备被解绑（`device.revoked`）→ 该行**立即消失**（不是变灰）；
/// - 连接状态诚实显示：`open` 才说「实时更新中」，退避中说「正在重连」，
///   未连上说「未连接」—— 绝不谎报（同 `connection_state_ui.dart` 的红线）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app/providers.dart';
import '../../data/model/device_state.dart';
import '../../data/sse/sse_session.dart';
import '../shared/ui_helpers.dart';

/// 「我的设备」区块。
class MyDevicesSection extends ConsumerStatefulWidget {
  const MyDevicesSection({super.key});

  @override
  ConsumerState<MyDevicesSection> createState() => _MyDevicesSectionState();
}

class _MyDevicesSectionState extends ConsumerState<MyDevicesSection> {
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadFirstPage());
  }

  /// 拉首屏并开闸（门控的一半：数据；另一半「建连」由控制器负责）。
  Future<void> _loadFirstPage() async {
    final services = servicesOf(ref);
    if (services == null) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '尚未配置服务端地址';
      });
      return;
    }
    final controller = ref.read(deviceEventsControllerProvider);
    try {
      final List<DeviceState> devices = await services.device.listDevices();
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = null;
      });
      // 🔴 必须先落地再开闸（见文件头）。
      await controller.markFirstListReady(devices);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        // 首屏失败**不**开闸：拿不到基线就建连只会让快照与空列表互相覆盖。
        // 用户可点重试，成功后才建连。
        _error = '设备列表暂时获取不到：${friendlyError(error)}';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final controller = ref.watch(deviceEventsControllerProvider);
    final List<DeviceState> devices = controller.devices;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Row(
            children: <Widget>[
              Text('我的设备', style: theme.textTheme.titleSmall),
              const SizedBox(width: 8),
              _LiveBadge(
                state: controller.state,
                onlineCount: controller.onlineCount,
                total: devices.length,
              ),
              const Spacer(),
              IconButton(
                tooltip: '刷新',
                visualDensity: VisualDensity.compact,
                onPressed: _loading ? null : _loadFirstPage,
                icon: const Icon(Icons.refresh, size: 18),
              ),
            ],
          ),
        ),
        if (_loading)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: LinearProgressIndicator(minHeight: 2),
          )
        else if (_error != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              _error!,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.error),
            ),
          )
        else if (devices.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: Text(
              '还没有其他设备绑定此账号',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.outline),
            ),
          )
        else
          for (final DeviceState device in devices)
            _DeviceRow(device: device, theme: theme),
      ],
    );
  }
}

/// 单台设备行（在线 → 绿点 + 「在线」；离线 → 灰点 + 「最后在线 …」）。
///
/// 🔴 离线设备**必须保留**（它不是解绑，只是暂时连不上）。
/// 真正的解绑由归约层直接从列表移除，无需本 widget 判断。
class _DeviceRow extends StatelessWidget {
  const _DeviceRow({required this.device, required this.theme});

  final DeviceState device;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    final bool online = device.online;
    final Color tone = online
        ? theme.colorScheme.primary
        : theme.colorScheme.outline;
    return ListTile(
      dense: true,
      leading: Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(color: tone, shape: BoxShape.circle),
      ),
      title: Text(device.name.isEmpty ? device.deviceId : device.name),
      subtitle: Text(
        <String>[
          online ? '在线' : _lastSeenText(device.lastSeenAt),
          if (device.kind.isNotEmpty) device.kind,
          // 服务端要求如实展示「未绑定账号」而不是隐藏该设备
          // （`state_bus.go:44-46`）：它仍在正常工作，只是缺归属。
          if (!device.hasOwner) '未绑定账号',
        ].join(' · '),
        style: theme.textTheme.bodySmall?.copyWith(color: tone),
      ),
      trailing: Text(
        online ? '实时' : '离线',
        style: theme.textTheme.labelSmall?.copyWith(color: tone),
      ),
    );
  }

  /// 离线时展示「最后在线」相对时间（服务端离线后仍保留 `last_seen_at`）。
  static String _lastSeenText(int? lastSeenAt) {
    if (lastSeenAt == null || lastSeenAt <= 0) return '离线';
    final DateTime at = DateTime.fromMillisecondsSinceEpoch(lastSeenAt);
    final Duration gap = DateTime.now().difference(at);
    if (gap.inSeconds < 60) return '最后在线：刚刚';
    if (gap.inMinutes < 60) return '最后在线：${gap.inMinutes} 分钟前';
    if (gap.inHours < 24) return '最后在线：${gap.inHours} 小时前';
    return '最后在线：${gap.inDays} 天前';
  }
}

/// 连接状态角标（**诚实映射**，绝不谎报「实时更新中」）。
///
/// 与 `connection_state_ui.dart` 的 `visualForConnectionState` 同一红线：
/// 只有 [SseState.open] 才能出现「实时」，其余都必须如实显示不可用态。
class _LiveBadge extends StatelessWidget {
  const _LiveBadge({
    required this.state,
    required this.onlineCount,
    required this.total,
  });

  final SseState state;
  final int onlineCount;
  final int total;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final (String label, Color tone) = switch (state) {
      SseState.open => ('实时 $onlineCount/$total', theme.colorScheme.primary),
      SseState.connecting => ('连接中', theme.colorScheme.outline),
      SseState.backoff => ('重连中', theme.colorScheme.tertiary),
      // idle：可能是尚未开闸（首屏未落地）或已停止。无论哪种都**不是**实时。
      SseState.idle => ('未连接', theme.colorScheme.outline),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: tone.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(color: tone),
      ),
    );
  }
}
