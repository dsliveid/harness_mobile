/// 投递队列（内存实现，后续可换 sqlite）。
///
/// 设计要点：
/// - **发送动作可注入**（`sender`），测试注入 Fake，绝不发真网络；
/// - 单条**最多尝试 [DeliveryQueue.maxAttempts] 次**（含入队那一次）；
/// - 达上限后 `retry` 变空操作（不发请求、不涨计数），条目仍留在列表里
///   供用户手动重发（`forceRetry` 显式重置预算）；
/// - 每次尝试都是独立 `await`，所以状态会真实经历
///   `pending → sending → success / failed`。
library;

import '../../core/error/app_error.dart';
import '../../data/remote/delivery_api.dart';

/// 投递条目状态。
enum DeliveryStatus {
  /// 已入队，等待发送。
  pending,

  /// 正在发送。
  sending,

  /// 发送成功。
  success,

  /// 发送失败（可能还有重试预算，也可能已达上限）。
  failed,
}

/// 一条投递记录。
class DeliveryItem {
  DeliveryItem({
    required this.id,
    required this.payload,
    this.status = DeliveryStatus.pending,
    this.attempts = 0,
    this.error,
  });

  /// 客户端生成的唯一 id（用于重试定位）。
  final String id;

  /// 图片载荷。
  final DeliveryPayload payload;

  /// 当前状态。
  DeliveryStatus status;

  /// 已尝试次数（含入队那次）。
  int attempts;

  /// 最近一次失败原因（成功时清空）。
  String? error;

  /// 是否已用尽自动重试预算（此后 `retry` 不再发请求）。
  bool get exhausted => attempts >= DeliveryQueue.maxAttempts;

  /// 是否正在发送。
  bool get isBusy => status == DeliveryStatus.sending;

  @override
  String toString() =>
      'DeliveryItem($id, ${payload.fileName}, $status, attempts=$attempts)';
}

/// 单条发送器签名（正常返回即成功，抛异常即失败）。
typedef DeliverySender = Future<void> Function(DeliveryItem item);

/// 投递队列。
class DeliveryQueue {
  DeliveryQueue({required DeliverySender sender}) : _sender = sender;

  /// 单条最多尝试次数（含入队那一次）。达上限后**不再自动重试**。
  static const int maxAttempts = 3;

  final DeliverySender _sender;
  final List<DeliveryItem> _items = <DeliveryItem>[];

  /// 队列快照（不可变视图，供 UI 渲染）。
  List<DeliveryItem> get items => List<DeliveryItem>.unmodifiable(_items);

  /// 入队并**尝试一次**发送。
  ///
  /// 失败只标记 [DeliveryStatus.failed] 而不在这里把重试预算烧光 ——
  /// 后续每次 `retry` 才继续消耗预算，这样「失败 → 用户看到 → 点重试」
  /// 的链路才成立。
  Future<void> enqueue(DeliveryItem item) async {
    _items.add(item);
    if (item.status == DeliveryStatus.success) return;
    item.status = DeliveryStatus.pending;
    await _attempt(item);
  }

  /// 重试（用户点「重试」或后续自动重试调用）。
  ///
  /// 已用尽预算（`attempts >= maxAttempts`）时**直接返回**：不发请求、
  /// 不涨计数，条目保持 failed 留在列表里。
  Future<void> retry(String id) async {
    final DeliveryItem? item = findById(id);
    if (item == null) return;
    if (item.exhausted) return;
    item.error = null;
    await _attempt(item);
  }

  /// 手动重发：**重置**预算后再试一次。
  ///
  /// 与 [retry] 的区别：用户显式点「重新发送」时给一份新的三次预算，
  /// 否则上限一到条目就永远救不回来。
  Future<void> forceRetry(String id) async {
    final DeliveryItem? item = findById(id);
    if (item == null) return;
    item
      ..attempts = 0
      ..error = null
      ..status = DeliveryStatus.pending;
    await _attempt(item);
  }

  /// 按 id 查找（找不到返回 null）。
  DeliveryItem? findById(String id) {
    for (final DeliveryItem item in _items) {
      if (item.id == id) return item;
    }
    return null;
  }

  /// 执行一次发送尝试。
  Future<void> _attempt(DeliveryItem item) async {
    if (item.attempts >= maxAttempts) return;
    item
      ..attempts += 1
      ..status = DeliveryStatus.sending;
    try {
      await _sender(item);
      item
        ..status = DeliveryStatus.success
        ..error = null;
    } on Object catch (error) {
      item
        ..status = DeliveryStatus.failed
        ..error = describeDeliveryError(error);
    }
  }
}

/// 异常 → 用户可读文案（绝不把堆栈糊到界面上）。
String describeDeliveryError(Object error) {
  if (error is AppError) return error.displayMessage;
  final String text = error.toString();
  return text.isEmpty ? '发送失败，请稍后重试' : text;
}
