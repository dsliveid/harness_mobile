/// 端侧自我解绑端点契约测试（`POST /api/v1/devices/unpair`）。
///
/// ## 这个文件防的是什么
/// 1. **鉴权凭据必须是 `device_token`**：服务端 `unpairDevice`
///    （`device_handler.go:226-242`）只读 `bearerToken(r)` 去吊销自己，
///    随手沿用默认拦截器打出去的就是 `user_token` —— 而解绑时刻用户令牌
///    很可能已过期 7 天（正是设备持久绑定要解决的问题），必然 401。
/// 2. **不能有请求体键**：服务端 `decodeJSON` 启用了 `DisallowUnknownFields`，
///    多发一个键就 400，解绑静默失败。
/// 3. **无设备令牌时不发请求**：那是必然 401，纯属白打服务端日志。
/// 4. **幂等**：204 空响应（令牌无效 / 已吊销也是 204）必须正常返回，
///    绝不能因为「没有 body 可解析」而抛异常。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_mobile/core/error/app_error.dart';
import 'package:harness_mobile/data/local/secure_store.dart';
import 'package:harness_mobile/data/remote/device_api.dart';
import 'package:harness_mobile/data/remote/http_client.dart';

/// 拦截适配器：记录每个请求并返回构造好的响应体。
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

ResponseBody Function(RequestOptions options) _ok204() =>
    (RequestOptions options) => _json(null, 204);

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

void main() {
  group('DeviceApi.unpair：凭设备令牌自我解约', () {
    test('Bearer 必须是 device_token（绝不能被默认拦截器换成 user_token）', () async {
      final f = _Fixture(_ok204());
      // 真机常态：老用户会话 + 设备令牌并存。
      await f.store.setUserToken('ut_expired');
      await f.store.setDeviceToken('dt_secret');

      await f.api.unpair();

      final options = f.adapter.captured.single;
      expect(options.path, '/api/v1/devices/unpair');
      expect(options.method, 'POST');
      // ★ 核心断言：只有设备令牌，用户令牌绝不能出现
      expect(options.headers['Authorization'], 'Bearer dt_secret');
      expect(options.headers['Authorization'], isNot('Bearer ut_expired'));
      // 免鉴权标记必须置位，否则拦截器会额外注入用户令牌形成两套凭据
      expect(options.extra[ApiClient.skipAuthKey], isTrue);
    });

    test('无请求体键（DisallowUnknownFields 下多一键即 400）', () async {
      final f = _Fixture(_ok204());
      await f.store.setDeviceToken('dt_secret');

      await f.api.unpair();

      final data = f.adapter.captured.single.data;
      expect(data, isA<Map<String, dynamic>>());
      expect((data! as Map<String, dynamic>).keys, isEmpty);
    });

    test('204 空响应必须正常返回（幂等：已吊销 / 令牌无效也是 204）', () async {
      final f = _Fixture(_ok204());
      await f.store.setDeviceToken('dt_secret');

      // 不抛即可（返回 void）
      await expectLater(f.api.unpair(), completes);
    });

    test('本机无设备令牌 → 不发请求，直接抛 AppError（避免必然 401 打满日志）',
        () async {
      final f = _Fixture(_ok204());
      // 只留用户令牌，没有设备令牌
      await f.store.setUserToken('ut_only');

      await expectLater(f.api.unpair(), throwsA(isA<AppError>()));
      expect(f.adapter.captured, isEmpty, reason: '无设备令牌时不得发起请求');
    });

    test('401 → AppError 上抛（由调用方降级为「未能通知服务端」）', () async {
      final f = _Fixture(
        (RequestOptions options) => _json(
          <String, dynamic>{
            'error': <String, dynamic>{
              'code': 'unauthorized',
              'message': '缺少设备令牌',
            },
          },
          401,
        ),
      );
      await f.store.setDeviceToken('dt_secret');

      await expectLater(
        f.api.unpair(),
        throwsA(isA<AppError>().having(
          (AppError e) => e.statusCode,
          'statusCode',
          401,
        )),
      );
    });

    test('服务端 5xx → AppError 上抛（解绑路径会降级而不阻断本地清理）', () async {
      final f = _Fixture(
        (RequestOptions options) => _json(
          <String, dynamic>{
            'error': <String, dynamic>{
              'code': 'device.disabled',
              'message': '设备功能未配置',
            },
          },
          503,
        ),
      );
      await f.store.setDeviceToken('dt_secret');

      await expectLater(f.api.unpair(), throwsA(isA<AppError>()));
    });

    test('revoke(deviceId) 仍存在但只走 DELETE（管理端用，端侧不调）', () async {
      final f = _Fixture((RequestOptions options) => _json(null, 204));

      await f.api.revoke('dev-1');

      final options = f.adapter.captured.single;
      expect(options.path, '/api/v1/devices/dev-1');
      expect(options.method, 'DELETE');
      // 管理端端点靠默认拦截器注入**用户令牌**，绝不能打 deviceAuth
      expect(options.extra[ApiClient.skipAuthKey], isNot(true));
    });
  });
}
