/// 解绑流程语义测试：「unpair 失败**仍**完成本地解绑」。
///
/// ## 为什么必须把这条钉死
/// 本地凭据一清，用户「这台机器不再绑定我」的意图就已达成；把 unpair 的
/// 网络失败上升为「解绑失败」，只会让用户卡在原地、并继续把一整套仍然有效
/// 的令牌留在 Keychain 里（比服务端留一条吊销记录危险得多）。
///
/// 同时反向钉死**顺序**：unpair 必须跑在本地清理**之前** —— 它的鉴权凭据
/// 就是 `device_token`，`clearAll()` 一旦先跑，服务端再也通知不到，
/// 这正是本任务要修的真实 bug 之一。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_mobile/core/app/device_unbind.dart';
import 'package:harness_mobile/data/local/secure_store.dart';
import 'package:harness_mobile/data/remote/device_api.dart';
import 'package:harness_mobile/data/remote/http_client.dart';

class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.handler);

  final ResponseBody Function(RequestOptions options) handler;
  final List<RequestOptions> captured = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    captured.add(options);
    return handler(options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _json(Object? body, int status) => ResponseBody.fromString(
      body == null ? '' : jsonEncode(body),
      status,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>[Headers.jsonContentType],
      },
    );

/// 一套被拦截出网的测试夹具。
class _Fixture {
  _Fixture(this.responder)
      : store = InMemorySecureStore(),
        adapter = _FakeAdapter(responder);

  final ResponseBody Function(RequestOptions options) responder;
  final InMemorySecureStore store;
  final _FakeAdapter adapter;

  late final DeviceApi api = DeviceApi(
    client: ApiClient(
      baseUrl: 'http://localhost:8080',
      tokens: TokenProvider(store),
      dio: Dio()..httpClientAdapter = adapter,
    ),
    store: store,
  );
}

ResponseBody Function(RequestOptions options) _ok204() =>
    (RequestOptions options) => _json(null, 204);

void main() {
  group('performUnbind：先通知服务端，再清本地', () {
    test('unpair 失败（网络异常）→ notified=false，但本地解绑照常执行', () async {
      final f = _Fixture(
        (RequestOptions options) => throw DioException(
          requestOptions: options,
          type: DioExceptionType.connectionError,
          message: 'no network',
        ),
      );
      await f.store.setDeviceToken('dt_secret');
      await f.store.setUserToken('ut_secret');

      var localRan = false;
      final notified = await performUnbind(
        device: f.api,
        localUnbind: () async {
          localRan = true;
          await f.store.clearAll();
        },
      );

      // ★ 本文件的核心断言
      expect(notified, isFalse, reason: '网络异常必须降级为「未能通知服务端」');
      expect(localRan, isTrue, reason: 'unpair 失败绝不能阻断本地解绑');
      expect(await f.store.getDeviceToken(), isNull);
      expect(await f.store.getUserToken(), isNull);
      // 请求确实发出去过（不是被静默跳过）
      expect(f.adapter.captured.single.path, '/api/v1/devices/unpair');
    });

    test('unpair 返回 401 → 同样不阻断本地解绑', () async {
      final f = _Fixture(
        (RequestOptions options) => _json(
          <String, dynamic>{
            'error': <String, dynamic>{
              'code': 'unauthorized',
              'message': '令牌已被吊销',
            },
          },
          401,
        ),
      );
      await f.store.setDeviceToken('dt_expired');

      var localRan = false;
      final notified = await performUnbind(
        device: f.api,
        localUnbind: () async {
          localRan = true;
          await f.store.clearAll();
        },
      );

      expect(notified, isFalse);
      expect(localRan, isTrue);
    });

    test('unpair 成功（204）→ notified=true 且本地同样被清', () async {
      final f = _Fixture(_ok204());
      await f.store.setDeviceToken('dt_secret');

      var localRan = false;
      final notified = await performUnbind(
        device: f.api,
        localUnbind: () async {
          localRan = true;
          await f.store.clearAll();
        },
      );

      expect(notified, isTrue);
      expect(localRan, isTrue);
      expect(f.store.clearedCount, 1);
    });

    test('顺序铁律：unpair 请求发出时 device_token 仍在（本地清理尚未跑）',
        () async {
      String? tokenAtRequestTime;
      final f = _Fixture((RequestOptions options) {
        tokenAtRequestTime = options.headers['Authorization'] as String?;
        return _json(null, 204);
      });
      await f.store.setDeviceToken('dt_secret');

      await performUnbind(
        device: f.api,
        localUnbind: () async {
          await f.store.clearAll();
        },
      );

      // ★ 若有人把 clearAll 挪到 unpair 之前，这里会变成 null（凭证已丢）
      expect(tokenAtRequestTime, 'Bearer dt_secret');
    });

    test('未配置服务端（device 为 null）→ notified=false，本地解绑仍完成', () async {
      var localRan = false;
      final notified = await performUnbind(
        device: null,
        localUnbind: () async {
          localRan = true;
        },
      );

      expect(notified, isFalse);
      expect(localRan, isTrue);
    });
  });

  group('notifyServerUnpair：绝不向外抛异常', () {
    test('本机无设备令牌（unpair 内部抛 AppError）→ 返回 false 而非抛出', () async {
      final f = _Fixture(_ok204());

      final notified = await notifyServerUnpair(f.api);

      expect(notified, isFalse);
      expect(f.adapter.captured, isEmpty, reason: '无设备令牌时不应发请求');
    });

    test('服务端 5xx → 返回 false 而非抛出（不打断调用方）', () async {
      final f = _Fixture(
        (RequestOptions options) => _json(
          <String, dynamic>{
            'error': <String, dynamic>{
              'code': 'internal',
              'message': '服务端错误',
            },
          },
          500,
        ),
      );
      await f.store.setDeviceToken('dt_secret');

      expect(await notifyServerUnpair(f.api), isFalse);
    });
  });
}
