/// 相册/相机媒体投递页（base64 内联投递）。
///
/// 为什么把 picker 抽成接口：`image_picker` 依赖平台通道，在 `flutter test`
/// 里根本调不起系统相册/相机。抽成 [ImageSourcePicker] 后，widget test 注入
/// Fake 即可稳定覆盖「选图 → 体积校验 → 入队 → 结果展示」全链路。
///
/// 投递口径见 `data/remote/delivery_api.dart`：服务端没有通用分片上传端点，
/// 本期把图片读成 base64 随工具参数交给 Agent，单图上限 2MB。
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/error/app_error.dart';
import '../../data/remote/delivery_api.dart';
import 'delivery_queue.dart';

/// 已选中的图片（脱离 image_picker 的最小抽象，便于测试构造）。
abstract class PickedImage {
  /// 原始文件名（含后缀）。
  String get fileName;

  /// MIME 类型。
  String get mimeType;

  /// 读取全部字节。
  Future<Uint8List> readBytes();
}

/// 图片选择器抽象（相册 / 相机）。
abstract class ImageSourcePicker {
  /// 从相册选一张。
  Future<PickedImage?> pickFromGallery();

  /// 调相机拍一张。
  Future<PickedImage?> pickFromCamera();
}

/// 基于 `image_picker` 的真实实现（仅在真机/模拟器上可用）。
class ImagePickerAdapter implements ImageSourcePicker {
  ImagePickerAdapter({ImagePicker? picker}) : _picker = picker ?? ImagePicker();

  final ImagePicker _picker;

  @override
  Future<PickedImage?> pickFromGallery() =>
      _pick(ImageSource.gallery);

  @override
  Future<PickedImage?> pickFromCamera() => _pick(ImageSource.camera);

  Future<PickedImage?> _pick(ImageSource source) async {
    final XFile? file = await _picker.pickImage(source: source);
    if (file == null) return null;
    return _PickedFileImage(file);
  }
}

/// `XFile` 的适配实现。
class _PickedFileImage implements PickedImage {
  _PickedFileImage(this._file);

  final XFile _file;

  @override
  String get fileName {
    final String name = _file.name;
    return name.isEmpty ? 'image.jpg' : name;
  }

  @override
  String get mimeType => guessMimeType(fileName);

  @override
  Future<Uint8List> readBytes() => _file.readAsBytes();
}

/// 字节数 → 人类可读体积。
String formatByteSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
}

/// 投递页。
class DeliveryPage extends StatefulWidget {
  const DeliveryPage({
    super.key,
    this.picker,
    this.queue,
    this.sender,
  });

  /// 图片选择器（缺省用真实 `image_picker`）。
  final ImageSourcePicker? picker;

  /// 外部注入的队列（测试可读其 items 断言是否入队）。
  final DeliveryQueue? queue;

  /// 队列发送器（缺省为「通道未接入」的显式失败，绝不谎报成功）。
  final DeliverySender? sender;

  @override
  State<DeliveryPage> createState() => _DeliveryPageState();
}

class _DeliveryPageState extends State<DeliveryPage> {
  static const DeliveryApi _api = DeliveryApi();

  late final ImageSourcePicker _picker =
      widget.picker ?? ImagePickerAdapter();
  late final DeliveryQueue _queue = widget.queue ??
      DeliveryQueue(sender: widget.sender ?? _unwiredSender);

  /// 当前已选中的图片（待发送）。
  DeliveryPayload? _payload;
  Uint8List? _previewBytes;

  /// 提示信息（体积超限、选择失败等）。
  String? _notice;
  bool _noticeIsError = false;

  /// 正在构建载荷（大图编码 base64 时避免卡顿观感）。
  bool _picking = false;

  /// 未接入真实通道时的发送器：明确告知失败，不谎报成功。
  static Future<void> _unwiredSender(DeliveryItem item) async {
    throw AppError.local(
      'delivery.unavailable',
      '投递通道尚未接入，请联系管理员',
    );
  }

  Future<void> _pick(Future<PickedImage?> Function() pick) async {
    if (_picking) return;
    setState(() {
      _picking = true;
      _notice = null;
      _noticeIsError = false;
    });
    try {
      final PickedImage? picked = await pick();
      if (picked == null) {
        if (mounted) setState(() => _picking = false);
        return;
      }
      final Uint8List bytes = await picked.readBytes();
      // 先按体积拦截：超限图**不做** hash/base64，也**不入队**
      final DeliveryPayload payload = await _api.buildPayload(
        bytes: bytes,
        fileName: picked.fileName,
        mimeType: picked.mimeType,
      );
      if (!mounted) return;
      setState(() {
        _payload = payload;
        _previewBytes = bytes;
        _notice = '已选择 ${payload.fileName}（${formatByteSize(payload.byteSize)}）';
        _noticeIsError = false;
        _picking = false;
      });
    } on AppError catch (error) {
      if (!mounted) return;
      setState(() {
        _payload = null;
        _previewBytes = null;
        _notice = error.displayMessage;
        _noticeIsError = true;
        _picking = false;
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _payload = null;
        _previewBytes = null;
        _notice = describeDeliveryError(error);
        _noticeIsError = true;
        _picking = false;
      });
    }
  }

  Future<void> _send() async {
    final DeliveryPayload? payload = _payload;
    if (payload == null) return;
    final DeliveryItem item = DeliveryItem(
      id: 'delivery-${DateTime.now().microsecondsSinceEpoch}',
      payload: payload,
    );
    setState(() {
      _payload = null;
      _previewBytes = null;
      _notice = '正在发送 ${payload.fileName}…';
      _noticeIsError = false;
    });
    await _queue.enqueue(item);
    if (!mounted) return;
    setState(() {
      _notice = item.status == DeliveryStatus.success
          ? '${payload.fileName} 发送成功'
          : '${payload.fileName} 发送失败：${item.error ?? '未知原因'}';
      _noticeIsError = item.status == DeliveryStatus.failed;
    });
  }

  Future<void> _retry(DeliveryItem item) async {
    await _queue.retry(item.id);
    if (!mounted) return;
    setState(() {
      _notice = item.status == DeliveryStatus.success
          ? '${item.payload.fileName} 重发成功'
          : '${item.payload.fileName} 仍失败：${item.error ?? '未知原因'}';
      _noticeIsError = item.status == DeliveryStatus.failed;
    });
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final List<DeliveryItem> items = _queue.items;

    return Scaffold(
      appBar: AppBar(title: const Text('投递')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          Text(
            '把手机里的图片投递给 Agent：单张最大 ${formatByteSize(maxInlineBytes)}，'
            '超出请先压缩。',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.outline),
          ),
          const SizedBox(height: 16),
          Row(
            children: <Widget>[
              Expanded(
                child: FilledButton.icon(
                  onPressed: _picking ? null : () => _pick(_picker.pickFromGallery),
                  icon: const Icon(Icons.photo_library_outlined),
                  label: const Text('从相册选择'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _picking ? null : () => _pick(_picker.pickFromCamera),
                  icon: const Icon(Icons.photo_camera_outlined),
                  label: const Text('拍照'),
                ),
              ),
            ],
          ),
          if (_notice != null) ...<Widget>[
            const SizedBox(height: 16),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: _noticeIsError
                    ? theme.colorScheme.errorContainer
                    : theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                _notice!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: _noticeIsError
                      ? theme.colorScheme.onErrorContainer
                      : theme.colorScheme.onSurface,
                ),
              ),
            ),
          ],
          if (_payload != null) ...<Widget>[
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    _thumb(_previewBytes),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            _payload!.fileName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleSmall,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '${formatByteSize(_payload!.byteSize)} · '
                            '${_payload!.mimeType}',
                            style: theme.textTheme.bodySmall,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'sha256 ${_payload!.sha256.substring(0, 12)}…',
                            style: theme.textTheme.bodySmall
                                ?.copyWith(color: theme.colorScheme.outline),
                          ),
                          const SizedBox(height: 10),
                          FilledButton.icon(
                            onPressed: _send,
                            icon: const Icon(Icons.send, size: 18),
                            label: const Text('发送'),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(height: 24),
          Text('投递记录', style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          if (items.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 20),
              child: Text(
                '暂无投递记录',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.outline),
              ),
            )
          else
            ...items.map((DeliveryItem item) => _tile(item)),
        ],
      ),
    );
  }

  Widget _thumb(Uint8List? bytes) {
    final BoxDecoration decoration = BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(8),
    );
    if (bytes == null) {
      return Container(
        width: 64,
        height: 64,
        decoration: decoration,
        child: const Icon(Icons.image_outlined, size: 24),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Image.memory(
        bytes,
        width: 64,
        height: 64,
        fit: BoxFit.cover,
        // 测试环境常传非图片字节，解码失败必须兜底而非崩溃
        errorBuilder: (BuildContext context, Object error, StackTrace? stack) {
          return Container(
            width: 64,
            height: 64,
            decoration: decoration,
            child: const Icon(Icons.image_outlined, size: 24),
          );
        },
      ),
    );
  }

  Widget _tile(DeliveryItem item) {
    final ThemeData theme = Theme.of(context);
    final (String label, Color color) = switch (item.status) {
      DeliveryStatus.pending => ('等待发送', theme.colorScheme.outline),
      DeliveryStatus.sending => ('发送中', theme.colorScheme.primary),
      DeliveryStatus.success => ('成功', Colors.green),
      DeliveryStatus.failed => ('失败', theme.colorScheme.error),
    };

    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        item.status == DeliveryStatus.success
            ? Icons.check_circle_outline
            : item.status == DeliveryStatus.failed
                ? Icons.error_outline
                : Icons.schedule,
        color: color,
      ),
      title: Text(
        item.payload.fileName,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        '${formatByteSize(item.payload.byteSize)} · $label'
        ' · 第 ${item.attempts} 次尝试'
        '${item.error == null ? '' : ' · ${item.error}'}'
        '${item.status == DeliveryStatus.failed && item.exhausted ? '（已达重试上限）' : ''}',
        maxLines: 2,
      ),
      trailing: item.status == DeliveryStatus.failed
          ? TextButton(
              onPressed: () => _retry(item),
              child: const Text('重试'),
            )
          : null,
    );
  }
}
