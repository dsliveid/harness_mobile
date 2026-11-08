/// 相册/相机媒体投递（base64 内联投递）。
///
/// 背景：服务端**没有**通用分片上传端点（只有下行
/// `GET /api/v1/artifacts/{id}`），因此本期采用 base64 内联投递：
/// 把图片字节读成 base64 字符串，随工具调用参数交给 Agent。
///
/// 上限 [maxInlineBytes]（2MB 原始字节，base64 后约 2.7MB 字符）。
/// 本文件**纯逻辑、无网络、无平台通道**，便于在 `flutter test` 中直接断言。
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../core/error/app_error.dart';

/// 单张图片内联投递的体积上限：2MB（按**原始字节**计，不是 base64 后长度）。
const int maxInlineBytes = 2 * 1024 * 1024;

/// 「图片超过内联上限」的稳定错误码（端侧本地错误）。
const String deliveryTooLargeCode = 'delivery.too_large';

/// 「图片内容为空」的稳定错误码（端侧本地错误）。
const String deliveryEmptyCode = 'delivery.empty';

/// 未识别后缀时的兜底 MIME。
const String fallbackMimeType = 'application/octet-stream';

/// 后缀 → MIME 映射（仅覆盖移动端常见图片格式）。
const Map<String, String> _mimeByExtension = <String, String>{
  'jpg': 'image/jpeg',
  'jpeg': 'image/jpeg',
  'png': 'image/png',
  'gif': 'image/gif',
  'webp': 'image/webp',
  'heic': 'image/heic',
  'heif': 'image/heif',
  'bmp': 'image/bmp',
};

/// 按文件名后缀推断 MIME（识别不了时退回 [fallbackMimeType]，不抛错）。
String guessMimeType(String fileName) {
  final int dot = fileName.lastIndexOf('.');
  if (dot < 0 || dot == fileName.length - 1) return fallbackMimeType;
  final String ext = fileName.substring(dot + 1).toLowerCase();
  return _mimeByExtension[ext] ?? fallbackMimeType;
}

/// 一张已校验、已算摘要、可内联投递的图片载荷。
class DeliveryPayload {
  const DeliveryPayload({
    required this.fileName,
    required this.mimeType,
    required this.base64Data,
    required this.byteSize,
    required this.sha256,
  });

  /// 工具参数键：文件名。
  static const String keyFileName = 'file_name';

  /// 工具参数键：MIME 类型。
  static const String keyMimeType = 'mime_type';

  /// 工具参数键：base64 内容。
  static const String keyBase64 = 'base64';

  /// 工具参数键：sha256（hex 小写）。
  static const String keySha256 = 'sha256';

  /// 工具参数键：原始字节数。
  static const String keyByteSize = 'byte_size';

  /// 原始文件名（含后缀）。
  final String fileName;

  /// MIME 类型（如 `image/jpeg`）。
  final String mimeType;

  /// 图片内容的 base64 字符串（**不含** `data:` 前缀）。
  final String base64Data;

  /// 原始字节数。
  final int byteSize;

  /// 原始字节的 sha256 十六进制摘要（小写）。
  final String sha256;

  /// 转为可塞进工具调用参数的 Map（键集合固定为 5 个，见 [keyFileName] 等）。
  Map<String, dynamic> toToolArgs() => <String, dynamic>{
        keyFileName: fileName,
        keyMimeType: mimeType,
        keyBase64: base64Data,
        keySha256: sha256,
        keyByteSize: byteSize,
      };

  @override
  String toString() => 'DeliveryPayload($fileName, $byteSize bytes, $mimeType)';
}

/// 投递载荷构造器（**无状态**，可安全 `const` 复用）。
class DeliveryApi {
  const DeliveryApi();

  /// 把图片字节封装成可内联投递的载荷。
  ///
  /// 顺序很重要：**先校验体积再算摘要**，超限时不做无谓的 hash 与 base64 编码
  /// （2MB 图的 base64 字符串约 2.7MB 字符，白白占用一次内存）。
  ///
  /// 超限抛 `AppError(code: delivery.too_large)`；
  /// 空内容抛 `AppError(code: delivery.empty)`。
  Future<DeliveryPayload> buildPayload({
    required List<int> bytes,
    required String fileName,
    required String mimeType,
  }) async {
    if (bytes.isEmpty) {
      throw AppError.local(deliveryEmptyCode, '图片内容为空，请重新选择');
    }
    if (bytes.length > maxInlineBytes) {
      throw AppError.local(
        deliveryTooLargeCode,
        '图片过大（最大 2MB），请压缩后重试',
      );
    }
    return DeliveryPayload(
      fileName: fileName,
      mimeType: mimeType,
      base64Data: base64Encode(bytes),
      byteSize: bytes.length,
      // ⚠️ crypto 的 sha256 返回 Digest，必须 .toString() 才是 hex
      sha256: sha256.convert(bytes).toString(),
    );
  }
}
