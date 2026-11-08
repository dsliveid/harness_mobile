/// 相册/相机 base64 投递 + 投递队列的验收测试。
///
/// 覆盖交接书要求的 7 项：
/// 1. ≤2MB 边界（恰好通过 / 超 1 字节被拒）
/// 2. `buildPayload` 的 sha256 与已知固定值一致
/// 3. `toToolArgs()` 键集合精确为 5 个
/// 4. 入队 → success
/// 5. send 抛错 → failed，`retry` 后 success
/// 6. 连续失败 3 次后不再自动重试
/// 7. 页面注入 Fake picker 选超大图 → 提示超限且**不入队**
///
/// 全程零出网：队列发送器与 picker 均为注入的 Fake。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_mobile/core/error/app_error.dart';
import 'package:harness_mobile/data/remote/delivery_api.dart';
import 'package:harness_mobile/features/delivery/delivery_page.dart';
import 'package:harness_mobile/features/delivery/delivery_queue.dart';

/// 可控的 Fake 图片。
class _FakePickedImage implements PickedImage {
  _FakePickedImage({required this.bytes, this.fileName = 'photo.jpg'});

  final Uint8List bytes;

  @override
  final String fileName;

  @override
  String get mimeType => guessMimeType(fileName);

  @override
  Future<Uint8List> readBytes() async => bytes;
}

/// 可控的 Fake picker：相册返回固定图，相机返回 null。
class _FakePicker implements ImageSourcePicker {
  _FakePicker(this.image);

  final PickedImage? image;
  int galleryCalls = 0;

  @override
  Future<PickedImage?> pickFromGallery() async {
    galleryCalls += 1;
    return image;
  }

  @override
  Future<PickedImage?> pickFromCamera() async => null;
}

/// 记录调用次数的 Fake 发送器。
class _FakeSender {
  _FakeSender({this.failuresBeforeSuccess = 1 << 30});

  /// 前 N 次抛错，之后成功（默认永远失败）。
  final int failuresBeforeSuccess;
  int calls = 0;

  Future<void> call(DeliveryItem item) async {
    calls += 1;
    if (calls <= failuresBeforeSuccess) {
      throw AppError.local('delivery.failed', '发送失败，请稍后重试');
    }
  }
}

DeliveryItem _itemOf(String name, {int size = 8}) => DeliveryItem(
      id: name,
      payload: DeliveryPayload(
        fileName: name,
        mimeType: 'image/jpeg',
        base64Data: base64Encode(List<int>.filled(size, 7)),
        byteSize: size,
        sha256: sha256.convert(List<int>.filled(size, 7)).toString(),
      ),
    );

void main() {
  const DeliveryApi api = DeliveryApi();

  group('DeliveryApi.buildPayload 体积边界', () {
    test('恰好 2MB 通过', () async {
      final List<int> bytes = List<int>.filled(maxInlineBytes, 0);
      final DeliveryPayload payload = await api.buildPayload(
        bytes: bytes,
        fileName: 'edge.png',
        mimeType: 'image/png',
      );
      expect(payload.byteSize, maxInlineBytes);
      expect(payload.fileName, 'edge.png');
      expect(payload.mimeType, 'image/png');
    });

    test('2MB + 1 字节被拒且错误码为 delivery.too_large', () async {
      final List<int> bytes = List<int>.filled(maxInlineBytes + 1, 0);
      await expectLater(
        api.buildPayload(
          bytes: bytes,
          fileName: 'too-big.jpg',
          mimeType: 'image/jpeg',
        ),
        throwsA(
          isA<AppError>().having(
            (AppError e) => e.code,
            'code',
            'delivery.too_large',
          ),
        ),
      );
    });

    test('空内容被拒', () async {
      await expectLater(
        api.buildPayload(
          bytes: const <int>[],
          fileName: 'empty.jpg',
          mimeType: 'image/jpeg',
        ),
        throwsA(
          isA<AppError>()
              .having((AppError e) => e.code, 'code', 'delivery.empty'),
        ),
      );
    });
  });

  group('DeliveryApi.buildPayload 摘要与参数', () {
    test('sha256 与已知固定值一致（hello harness）', () async {
      final List<int> bytes = utf8.encode('hello harness');
      final DeliveryPayload payload = await api.buildPayload(
        bytes: bytes,
        fileName: 'a.txt',
        mimeType: 'text/plain',
      );
      // 已知固定值：sha256("hello harness")，由独立工具预先算出后硬编码，
      // 避免「用被测同一实现自证」的假绿。
      expect(
        payload.sha256,
        'ce2f2801b638e4f4a615043342b4c66862c34f833d09b5ea6b65a4729bec6f5a',
      );
      expect(payload.sha256.length, 64);
      // base64 正确
      expect(payload.base64Data, base64Encode(bytes));
    });

    test('toToolArgs 键集合恰为 5 个约定字段', () async {
      final DeliveryPayload payload = await api.buildPayload(
        bytes: utf8.encode('x'),
        fileName: 'b.png',
        mimeType: 'image/png',
      );
      final Map<String, dynamic> args = payload.toToolArgs();
      expect(
        args.keys.toSet(),
        <String>{'file_name', 'mime_type', 'base64', 'sha256', 'byte_size'},
      );
      expect(args['file_name'], 'b.png');
      expect(args['mime_type'], 'image/png');
      expect(args['byte_size'], 1);
      expect(args['base64'], base64Encode(utf8.encode('x')));
      expect(args['sha256'], sha256.convert(utf8.encode('x')).toString());
    });

    test('guessMimeType 按后缀推断，未知后缀兜底', () {
      expect(guessMimeType('a.JPG'), 'image/jpeg');
      expect(guessMimeType('a.webp'), 'image/webp');
      expect(guessMimeType('a.unknown'), fallbackMimeType);
      expect(guessMimeType('noext'), fallbackMimeType);
    });
  });

  group('DeliveryQueue 状态机', () {
    test('入队后发送成功 → success，attempts=1', () async {
      final _FakeSender sender = _FakeSender(failuresBeforeSuccess: 0);
      final DeliveryQueue queue = DeliveryQueue(sender: sender.call);
      final DeliveryItem item = _itemOf('ok.jpg');
      await queue.enqueue(item);

      expect(item.status, DeliveryStatus.success);
      expect(item.attempts, 1);
      expect(item.error, isNull);
      expect(queue.items.length, 1);
      expect(sender.calls, 1);
    });

    test('发送抛错 → failed，retry 后 success', () async {
      final _FakeSender sender = _FakeSender(failuresBeforeSuccess: 1);
      final DeliveryQueue queue = DeliveryQueue(sender: sender.call);
      final DeliveryItem item = _itemOf('flaky.jpg');
      await queue.enqueue(item);

      expect(item.status, DeliveryStatus.failed);
      expect(item.error, '发送失败，请稍后重试');
      expect(item.attempts, 1);

      await queue.retry(item.id);
      expect(item.status, DeliveryStatus.success);
      expect(item.attempts, 2);
      expect(item.error, isNull);
      expect(sender.calls, 2);
    });

    test('连续失败 3 次后不再自动重试（attempts 达上限即空操作）', () async {
      final _FakeSender sender = _FakeSender(); // 永远失败
      final DeliveryQueue queue = DeliveryQueue(sender: sender.call);
      final DeliveryItem item = _itemOf('bad.jpg');

      await queue.enqueue(item); // 第 1 次
      expect(item.attempts, 1);
      expect(item.status, DeliveryStatus.failed);

      await queue.retry(item.id); // 第 2 次
      expect(item.attempts, 2);

      await queue.retry(item.id); // 第 3 次
      expect(item.attempts, 3);
      expect(item.exhausted, isTrue);

      // 已达上限：再 retry 不发请求、不涨计数
      await queue.retry(item.id);
      await queue.retry(item.id);
      expect(item.attempts, 3);
      expect(sender.calls, 3);
      expect(item.status, DeliveryStatus.failed);
      // 条目仍保留在队列里供手动重发
      expect(queue.items.single.id, 'bad.jpg');
    });

    test('forceRetry 重置预算后可再次发送', () async {
      final _FakeSender sender = _FakeSender(failuresBeforeSuccess: 3);
      final DeliveryQueue queue = DeliveryQueue(sender: sender.call);
      final DeliveryItem item = _itemOf('retry.jpg');

      await queue.enqueue(item);
      await queue.retry(item.id);
      await queue.retry(item.id);
      expect(item.attempts, 3);
      expect(item.exhausted, isTrue);

      await queue.forceRetry(item.id); // 第 4 次调用 → 成功
      expect(item.status, DeliveryStatus.success);
      expect(item.attempts, 1);
      expect(sender.calls, 4);
    });

    test('retry 未知 id 是空操作', () async {
      final _FakeSender sender = _FakeSender();
      final DeliveryQueue queue = DeliveryQueue(sender: sender.call);
      await queue.retry('missing');
      expect(sender.calls, 0);
      expect(queue.items, isEmpty);
    });
  });

  group('DeliveryPage（Fake picker）', () {
    testWidgets('选超大图 → 显示超限提示且不入队', (WidgetTester tester) async {
      final _FakeSender sender = _FakeSender(failuresBeforeSuccess: 0);
      final DeliveryQueue queue = DeliveryQueue(sender: sender.call);
      final _FakePicker picker = _FakePicker(
        _FakePickedImage(
          bytes: Uint8List(maxInlineBytes + 1),
          fileName: 'huge.jpg',
        ),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: DeliveryPage(picker: picker, queue: queue),
        ),
      );

      await tester.tap(find.text('从相册选择'));
      await tester.pumpAndSettle();

      expect(picker.galleryCalls, 1);
      expect(find.textContaining('图片过大'), findsOneWidget);
      // 关键断言：超限图绝不入队、绝不触发发送
      expect(queue.items, isEmpty);
      expect(sender.calls, 0);
      // 也不应出现「发送」按钮（没有待发送载荷）
      expect(find.text('发送'), findsNothing);
    });

    testWidgets('选正常图 → 展示预览，点发送后状态为成功', (WidgetTester tester) async {
      final _FakeSender sender = _FakeSender(failuresBeforeSuccess: 0);
      final DeliveryQueue queue = DeliveryQueue(sender: sender.call);
      final _FakePicker picker = _FakePicker(
        _FakePickedImage(
          bytes: Uint8List.fromList(utf8.encode('fake-image-bytes')),
          fileName: 'ok.png',
        ),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: DeliveryPage(picker: picker, queue: queue),
        ),
      );

      await tester.tap(find.text('从相册选择'));
      await tester.pumpAndSettle();
      expect(find.textContaining('ok.png'), findsWidgets);

      await tester.tap(find.text('发送'));
      await tester.pumpAndSettle();

      expect(queue.items.length, 1);
      expect(queue.items.single.status, DeliveryStatus.success);
      expect(find.textContaining('发送成功'), findsOneWidget);
    });

    testWidgets('发送失败 → 记录为失败并可点重试', (WidgetTester tester) async {
      final _FakeSender sender = _FakeSender(failuresBeforeSuccess: 1);
      final DeliveryQueue queue = DeliveryQueue(sender: sender.call);
      final _FakePicker picker = _FakePicker(
        _FakePickedImage(
          bytes: Uint8List.fromList(utf8.encode('retry-me')),
          fileName: 'fail.jpg',
        ),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: DeliveryPage(picker: picker, queue: queue),
        ),
      );

      await tester.tap(find.text('从相册选择'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('发送'));
      await tester.pumpAndSettle();

      expect(queue.items.single.status, DeliveryStatus.failed);
      expect(find.textContaining('fail.jpg 发送失败'), findsOneWidget);

      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(queue.items.single.status, DeliveryStatus.success);
      expect(find.textContaining('重发成功'), findsOneWidget);
    });
  });
}
