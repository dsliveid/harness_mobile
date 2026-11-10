/// UI 层公共小件（**纯展示**，不含任何业务判定）。
///
/// 抽出来的理由：四个页面都要「加载中 / 空 / 出错重试 / 时间格式化 / 风险标签」，
/// 各写一遍会出现四套文案与四套颜色，且改一处漏三处。
library;

import 'package:flutter/material.dart';

import '../../core/error/app_error.dart';

/// 异常 → 用户可读文案。
///
/// 铁律：服务端 `message` 优先（R7：400 字段错误必须原样透出，否则排查极慢）；
/// 其余情况一律给通用文案，**绝不把堆栈/内部异常串直接糊到界面上**。
String friendlyError(Object error) {
  if (error is AppError) return error.displayMessage;
  if (error is ArgumentError) {
    final message = error.message;
    return message != null && message.toString().isNotEmpty
        ? message.toString()
        : '输入不合法，请检查后重试';
  }
  if (error is StateError) return '数据不完整，请稍后重试';
  return '操作失败，请稍后重试';
}

/// 毫秒时间戳 → `MM-dd HH:mm`；空值/非法值返回 `--`。
String formatTimestamp(int? milliseconds) {
  if (milliseconds == null || milliseconds <= 0) return '--';
  final time = DateTime.fromMillisecondsSinceEpoch(milliseconds).toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${two(time.month)}-${two(time.day)} ${two(time.hour)}:${two(time.minute)}';
}

/// 相对时间（列表副标题用）：`刚刚` / `x 分钟前` / `x 小时前` / 绝对时间。
String formatRelativeTime(int? milliseconds) {
  if (milliseconds == null || milliseconds <= 0) return '--';
  final delta = DateTime.now()
      .difference(DateTime.fromMillisecondsSinceEpoch(milliseconds));
  if (delta.isNegative) return formatTimestamp(milliseconds);
  if (delta.inMinutes < 1) return '刚刚';
  if (delta.inMinutes < 60) return '${delta.inMinutes} 分钟前';
  if (delta.inHours < 24) return '${delta.inHours} 小时前';
  return formatTimestamp(milliseconds);
}

/// 居中的加载态。
class LoadingBody extends StatelessWidget {
  const LoadingBody({super.key, this.message = '加载中…'});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          const SizedBox(
            width: 28,
            height: 28,
            child: CircularProgressIndicator(strokeWidth: 2.5),
          ),
          const SizedBox(height: 14),
          Text(message, style: Theme.of(context).textTheme.bodyMedium),
        ],
      ),
    );
  }
}

/// 错误态（带重试）。
class ErrorBody extends StatelessWidget {
  const ErrorBody({super.key, required this.message, this.onRetry});

  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Icon(
              Icons.cloud_off_outlined,
              size: 48,
              color: theme.colorScheme.error,
            ),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium,
            ),
            if (onRetry != null) ...<Widget>[
              const SizedBox(height: 16),
              OutlinedButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh),
                label: const Text('重试'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 空态。
class EmptyBody extends StatelessWidget {
  const EmptyBody({
    super.key,
    required this.icon,
    required this.title,
    this.hint,
    this.onRefresh,
  });

  final IconData icon;
  final String title;
  final String? hint;
  final VoidCallback? onRefresh;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Icon(icon, size: 52, color: theme.colorScheme.outline),
            const SizedBox(height: 14),
            Text(title, style: theme.textTheme.titleMedium),
            if (hint != null) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                hint!,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.outline),
              ),
            ],
            if (onRefresh != null) ...<Widget>[
              const SizedBox(height: 16),
              OutlinedButton.icon(
                onPressed: onRefresh,
                icon: const Icon(Icons.refresh),
                label: const Text('刷新'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 风险标签（`read / write / command / danger`）。
///
/// ⚠️ `command` / `danger` 为高风险：需生物识别，且服务端可能要求
/// 在指定设备确认（红线 R5）。
class RiskChip extends StatelessWidget {
  const RiskChip({super.key, required this.risk});

  final String risk;

  static const Map<String, String> _labels = <String, String>{
    'read': '读取',
    'write': '写入',
    'command': '命令',
    'danger': '高危',
  };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final Color color;
    switch (risk) {
      case 'danger':
        color = scheme.error;
      case 'command':
        color = Colors.deepOrange;
      case 'write':
        color = Colors.blue;
      default:
        color = scheme.outline;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        // Flutter 3.27+ 已提供 Color.withValues（本项目基线为 3.47.9）；
        // withOpacity 自 3.27 起标记 deprecated，`--fatal-infos` 下算 error。
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Text(
        _labels[risk] ?? (risk.isEmpty ? '未知' : risk),
        style: TextStyle(fontSize: 11, color: color, height: 1.3),
      ),
    );
  }
}
