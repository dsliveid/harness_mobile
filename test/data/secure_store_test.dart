import 'package:flutter_test/flutter_test.dart';
import 'package:harness_mobile/core/error/app_error.dart';
import 'package:harness_mobile/data/local/secure_store.dart';

void main() {
  group('InMemorySecureStore：令牌往返', () {
    late InMemorySecureStore store;

    setUp(() => store = InMemorySecureStore());

    test('设备令牌写入后可读出', () async {
      await store.setDeviceToken('dev_tok_123');
      expect(await store.getDeviceToken(), 'dev_tok_123');
    });

    test('设备令牌删除后为 null', () async {
      await store.setDeviceToken('dev_tok_123');
      await store.deleteDeviceToken();
      expect(await store.getDeviceToken(), isNull);
    });

    test('未设置时返回 null 而非抛异常', () async {
      expect(await store.getDeviceToken(), isNull);
      expect(await store.getUserToken(), isNull);
      expect(await store.hasUserToken(), isFalse);
    });

    test('用户令牌单令牌写入后可读', () async {
      await store.setUserToken('tok_abc');
      expect(await store.getUserToken(), 'tok_abc');
      expect(await store.hasUserToken(), isTrue);
    });

    test('空字符串视为未登录（避免半截状态）', () async {
      await store.setUserToken('');
      expect(await store.hasUserToken(), isFalse);
    });

    test('删除用户令牌后为未登录', () async {
      await store.setUserToken('tok_abc');
      await store.deleteUserToken();
      expect(await store.getUserToken(), isNull);
      expect(await store.hasUserToken(), isFalse);
    });

    test('clearAll 清空全部凭据且可重复调用', () async {
      await store.setDeviceToken('d');
      await store.setUserToken('u');
      await store.clearAll();

      expect(await store.getDeviceToken(), isNull);
      expect(await store.getUserToken(), isNull);
      expect(store.keys, isEmpty);
      expect(store.clearedCount, 1);
    });

    test('设备与用户令牌各自独立，互不影响', () async {
      await store.setDeviceToken('device_only');
      expect(await store.getUserToken(), isNull);
      await store.setUserToken('user_only');
      expect(await store.getDeviceToken(), 'device_only');
    });

    test('存储键命名符合约定，不落明文到其他键', () async {
      await store.setDeviceToken('d');
      expect(store.keys, equals({SecureKeys.deviceToken}));
      await store.setUserToken('u');
      expect(store.keys, equals({SecureKeys.deviceToken, SecureKeys.userToken}));
    });
  });

  group('maskToken：绝不泄露明文（红线 R3）', () {
    test('长令牌保留首4尾2，中间打码', () {
      final masked = maskToken('abcdefghijklmnop');
      expect(masked.contains('abcdefghijklmnop'), isFalse);
      expect(masked, 'abcd***op');
    });

    test('短令牌整体打码', () {
      expect(maskToken('abc'), '***');
      expect(maskToken('12345678'), '***');
    });

    test('空值安全', () {
      expect(maskToken(null), '<empty>');
      expect(maskToken(''), '<empty>');
    });
  });

  group('AppError：服务端错误体解析', () {
    test('标准错误体逐字段解析', () {
      final e = AppError.fromResponseBody(const {
        'error': {
          'code': 'approval.already_decided',
          'message': '该审批已被处理',
          'trace_id': 'tr_123',
          'details': {'approval_id': 'ap_1'},
        }
      }, statusCode: 409);

      expect(e.code, ErrorCode.approvalAlreadyDecided);
      expect(e.message, '该审批已被处理');
      expect(e.traceId, 'tr_123');
      expect(e.details!['approval_id'], 'ap_1');
      expect(e.statusCode, 409);
      expect(e.isApprovalAlreadyDecided, isTrue);
    });

    test('非约定格式退化为 internal，不崩溃', () {
      final e = AppError.fromResponseBody('plain text error', statusCode: 500);
      expect(e.code, ErrorCode.internal);
      expect(e.message, isNotEmpty);
      expect(e.statusCode, 500);
    });

    test('null 响应体也安全', () {
      final e = AppError.fromResponseBody(null, statusCode: 502);
      expect(e.code, ErrorCode.internal);
    });

    test('缺 code 字段时兜底为 internal', () {
      final e = AppError.fromResponseBody(const {
        'error': {'message': '出错了'}
      }, statusCode: 400);
      expect(e.code, ErrorCode.internal);
      expect(e.message, '出错了');
    });
  });

  group('AppError：语义判定（红线相关）', () {
    test('审批需在指定设备确认（R5）', () {
      const e = AppError(
        code: ErrorCode.approvalDeviceMismatch,
        message: '需在桌面端确认',
        statusCode: 403,
      );
      expect(e.isApprovalDeviceMismatch, isTrue);
      expect(e.displayMessage, '需在桌面端确认');
    });

    test('设备被吊销 → 引导重新配对', () {
      const e = AppError(code: ErrorCode.deviceRevoked, message: '');
      expect(e.isDeviceRevoked, isTrue);
      expect(e.displayMessage, contains('重新配对'));
    });

    test('协议不兼容 → 提示升级', () {
      const e = AppError(code: ErrorCode.deviceProtocolMismatch, message: '');
      expect(e.isProtocolMismatch, isTrue);
      expect(e.displayMessage, contains('升级'));
    });

    test('401 语义：状态码或错误码任一命中', () {
      const byStatus = AppError(code: 'whatever', message: '', statusCode: 401);
      const byCode = AppError(code: ErrorCode.unauthorized, message: '');
      expect(byStatus.isUnauthorized, isTrue);
      expect(byCode.isUnauthorized, isTrue);
    });

    test('R7：400 必须透出服务端 message（排查字段漂移的关键）', () {
      const e = AppError(
        code: ErrorCode.invalidArgument,
        message: '请求体格式错误: unknown field "device_id"',
        statusCode: 400,
      );
      expect(e.isInvalidArgument, isTrue);
      // displayMessage 优先用服务端原文，不能吞掉
      expect(e.displayMessage, contains('unknown field'));
    });

    test('displayMessage 在 message 为空时按码兜底', () {
      const e = AppError(code: ErrorCode.unavailable, message: '');
      expect(e.displayMessage, contains('网络'));
    });
  });

  group('AppError：网络错误构造', () {
    test('network 工厂产出 unavailable 码', () {
      final e = AppError.network('连不上');
      expect(e.code, ErrorCode.unavailable);
      expect(e.displayMessage, '连不上');
    });

    test('toString 含码与状态，便于日志排查', () {
      const e = AppError(code: 'x.y', message: 'm', statusCode: 400);
      expect(e.toString(), contains('x.y'));
      expect(e.toString(), contains('400'));
    });
  });
}
