/// P4/P5 数据层契约测试。
///
/// 目标（对应交接书关键断言）：
/// (a) 配对请求体键集合恰为 `{code,name,kind,platform,app_version,capabilities}`
/// (b) capabilities 每项键恰为 `{name,version}`
/// (c) 决策 body 键恰为 `{decision,reason,device_id}` 且 decision∈{allow_once,allow_session,deny}
/// (d) Session 模型能解析服务端完整 JSON
/// 附加：active-run 空 run_id → null；审批仓储 N+1 过滤与并发上限。
///
/// ⚠️ **不发真请求**：通过替换 dio 的 `HttpClientAdapter` 拦截全部出网调用，
/// 并断言请求体的**键集合**（服务端 `DisallowUnknownFields`，多一个键即 400）。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_mobile/data/local/secure_store.dart';
import 'package:harness_mobile/data/remote/auth_api.dart';
import 'package:harness_mobile/data/remote/device_api.dart';
import 'package:harness_mobile/data/remote/http_client.dart';

/// 拦截适配器：记录每个请求并返回构造好的响应体。
class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.handler);

  final ResponseBody Function(RequestOptions options) handler;

  /// 按到达顺序记录的全部请求（断言请求体契约用）。
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

ResponseBody _jsonBody(Object? body, {int status = 200}) =>
    ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>[Headers.jsonContentType],
      },
    );

/// 构造一个「出网被拦截」的 ApiClient，并暴露 store 供令牌落盘断言。
({ApiClient client, _FakeAdapter adapter, InMemorySecureStore store}) _build(
  Object? Function(RequestOptions options) responder,
) {
  final adapter = _FakeAdapter(
    (RequestOptions options) => _jsonBody(responder(options)),
  );
  final store = InMemorySecureStore();
  final client = ApiClient(
    baseUrl: 'http://localhost:8080',
    tokens: TokenProvider(store),
    dio: Dio()..httpClientAdapter = adapter,
  );
  return (client: client, adapter: adapter, store: store);
}

Map<String, dynamic> _bodyOf(RequestOptions options) {
  final data = options.data;
  expect(data, isA<Map<String, dynamic>>(), reason: '请求体必须是 JSON 对象');
  return data! as Map<String, dynamic>;
}

/// 键集合断言：必须**恰好**等于期望集合（多一个/少一个都失败）。
void _expectExactKeys(Map<String, dynamic> body, Set<String> expected) {
  expect(
    body.keys.toList(),
    unorderedEquals(expected.toList()),
    reason: '请求体键集合必须恰为 $expected（服务端 DisallowUnknownFields）',
  );
}

void main() {
  group('R7 请求体键集合精确性', () {
    test('配对请求体键恰为 {code,name,kind,platform,app_version,capabilities}',
        () async {
      final (:client, :adapter, :store) = _build(
        (RequestOptions options) => <String, dynamic>{
          'device_id': 'dev_1',
          'device_token': 'dt_secret',
          'ws_path': '/api/v1/devices/ws',
          'protocol_version': 1,
        },
      );
      final api = DeviceApi(client: client, store: store);
      await api.pair(code: '123456', name: '我的手机');

      final options = adapter.captured.single;
      expect(options.path, '/api/v1/devices/pair');
      expect(options.method, 'POST');
      // 配对免鉴权：必须打 skipAuth，否则会带用户令牌（服务端该端点无用户上下文）
      expect(options.extra[ApiClient.skipAuthKey], isTrue);

      final body = _bodyOf(options);
      _expectExactKeys(
        body,
        <String>{
          'code',
          'name',
          'kind',
          'platform',
          'app_version',
          'capabilities',
        },
      );
      expect(body['code'], '123456');
      expect(body['kind'], DeviceKinds.mobile);

      // 配对令牌必须落盘（仅此一次明文）
      expect(await store.getDeviceToken(), 'dt_secret');
    });

    test('capabilities 每项键恰为 {name,version}，且为 network+device 两项',
        () async {
      final (:client, :adapter, :store) = _build(
        (RequestOptions options) => <String, dynamic>{
          'device_id': 'dev_1',
          'device_token': 'dt_secret',
          'ws_path': '/ws',
          'protocol_version': 1,
        },
      );
      await DeviceApi(client: client, store: store)
          .pair(code: '123456', name: '我的手机');

      final caps = _bodyOf(adapter.captured.single)['capabilities'];
      expect(caps, isA<List<dynamic>>());
      final list = caps! as List<dynamic>;
      expect(list, hasLength(2));
      for (final item in list) {
        final cap = item as Map<String, dynamic>;
        _expectExactKeys(cap, <String>{'name', 'version'});
      }
      final names = list
          .map((dynamic e) => (e as Map<String, dynamic>)['name'])
          .toList();
      expect(names.toSet(), <dynamic>{'network', 'device'});
    });


    test('登录把单令牌写入 SecureStore，且请求体只有 username/password',
        () async {
      final (:client, :adapter, :store) = _build(
        (RequestOptions options) => <String, dynamic>{
          'user': <String, dynamic>{
            'id': 'u1',
            'username': 'alice',
            'display_name': '爱丽丝',
            'role': 'owner',
          },
          'token': 'ut_secret',
        },
      );
      final user = await AuthApi(client: client, store: store).login(
        username: 'alice',
        password: 'p@ss',
      );

      expect(user.displayName, '爱丽丝');
      expect(await store.getUserToken(), 'ut_secret');
      final options = adapter.captured.single;
      expect(options.path, '/api/v1/auth/login');
      _expectExactKeys(_bodyOf(options), <String>{'username', 'password'});
      expect(options.extra[ApiClient.skipAuthKey], isTrue);
    });
  });

  group('模型宽容解析', () {
    test('Session 能解析服务端完整 JSON（含 int64 毫秒时间戳）', () {
      // 字段与 internal/model/model.go:104-125 完全对齐
      final json = <String, dynamic>{
        'id': 'sess_1',
        'title': '移动端联调',
        'workspace_path': 'D:/WorkSpace/Project/harness_go',
        'project_id': 'proj_1',
        'access_mode': 'workspace_write',
        'model_ref': 'anthropic/claude',
        'user_id': 'u1',
        'source': 'ui',
        'message_count': 42,
        'last_message_at': 1762500000123,
        'total_tokens': 98765,
        'last_run_status': 'waiting_approval',
        'created_at': 1762400000000,
        'updated_at': 1762500000456,
        'deleted_at': null,
        'archived_at': null,
      };
      final session = Session.fromJson(json);

      expect(session.id, 'sess_1');
      expect(session.title, '移动端联调');
      expect(session.workspacePath, 'D:/WorkSpace/Project/harness_go');
      expect(session.projectId, 'proj_1');
      expect(session.accessMode, 'workspace_write');
      expect(session.modelRef, 'anthropic/claude');
      expect(session.source, 'ui');
      expect(session.messageCount, 42);
      // int64 毫秒：必须精确，不能被当作 double 丢精度
      expect(session.lastMessageAt, 1762500000123);
      expect(session.totalTokens, 98765);
      expect(session.lastRunStatus, 'waiting_approval');
      expect(session.createdAt, 1762400000000);
      expect(session.updatedAt, 1762500000456);
      expect(session.deletedAt, isNull);
      expect(session.archivedAt, isNull);
      expect(session.isArchived, isFalse);
      expect(session.hasLiveRun, isTrue);
      expect(session.mayNeedApproval, isTrue);
    });

    test('Session 缺字段/数字为 double 时也不崩', () {
      final session = Session.fromJson(<String, dynamic>{
        'id': 'sess_2',
        'message_count': 42.0,
      });
      expect(session.messageCount, 42);
      expect(session.title, '');
      expect(session.isDeleted, isFalse);
      expect(session.mayNeedApproval, isFalse);
    });

    test('ToolEvent 解析 + 入参摘要为 Map 时按 key=value 拼接', () {
      final event = ToolEvent.fromJson(<String, dynamic>{
        'id': 'evt_1',
        'run_id': 'run_1',
        'tool_name': 'http.fetch',
        'namespace': 'network',
        'args': <String, dynamic>{'url': 'https://example.com', 'method': 'GET'},
        'status': 'pending',
        'risk': 'danger',
        'executor': 'device',
        'source_trust': 'untrusted',
        'started_at': 1762500000789,
      });
      expect(event.id, 'evt_1');
      expect(event.isPending, isTrue);
      expect(event.isHighRisk, isTrue);
      expect(event.argsDigest(), contains('url=https://example.com'));
      expect(event.startedAt, 1762500000789);
