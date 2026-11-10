/// P4/P5/P8 数据层契约测试（批次 C 后已与 WebView 主体架构对齐）。
///
/// 目标（对应交接书关键断言）：
/// (a) 配对请求体键集合恰为 `{code,name,kind,platform,app_version,capabilities}`
/// (b) capabilities 每项键恰为 `{name,version}`
/// (c) 登录请求体键恰为 `{username,password}`，单令牌落盘 SecureStore
/// (d) webview-ticket 请求体键恰为 `{device_id,ttl_s}`（红线 R3：ticket 不进日志）
/// (e) Workspace 只读消费：只有 list/get，**不存在**任何写方法
///
/// ⚠️ **不发真请求**：通过替换 dio 的 `HttpClientAdapter` 拦截全部出网调用，
/// 并断言请求体的**键集合**（服务端 `DisallowUnknownFields`，多一个键即 400）。
///
/// 批次 C 已删除 approval / session / delivery 三域，本文件原先针对
/// `Session.fromJson` / `ToolEvent` / 决策 body 的用例随其宿主类型一并移除
/// （宿主类型已不存在，任何等价断言都无处落点）；取而代之的是
/// workspace / webview-ticket 两条**现役**链路。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_mobile/core/error/app_error.dart';
import 'package:harness_mobile/data/local/secure_store.dart';
import 'package:harness_mobile/data/remote/auth_api.dart';
import 'package:harness_mobile/data/remote/device_api.dart';
import 'package:harness_mobile/data/remote/http_client.dart';
import 'package:harness_mobile/data/remote/webview_ticket_api.dart';
import 'package:harness_mobile/data/remote/workspace_api.dart';
import 'package:harness_mobile/protocol/frame_payloads.dart';

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

  group('WebView 票据 / 工作空间上行契约（批次 C 新增）', () {
    test('webview-ticket 请求体键恰为 {device_id,ttl_s}', () async {
      final (:client, :adapter, :store) = _build(
        (RequestOptions options) => <String, dynamic>{
          'ticket': 'tk_once',
          'expires_at': 1762500120000,
        },
      );
      final api = WebViewTicketApi(client: client, store: store);
      final ticket = await api.issue(deviceId: 'dev_1');

      final options = adapter.captured.single;
      expect(options.path, '/api/v1/auth/webview-ticket');
      expect(options.method, 'POST');
      // 该端点**需要**用户会话，绝不能打 skipAuth（否则拿不到用户上下文）
      expect(options.extra[ApiClient.skipAuthKey], isNot(true));
      _expectExactKeys(_bodyOf(options), <String>{'device_id', 'ttl_s'});
      expect(ticket.ticket, 'tk_once');
      expect(ticket.expiresAt, 1762500120000);
    });

    test('ttl_s 默认 120s，显式传入时不被覆盖', () async {
      final (:client, :adapter, :store) = _build(
        (RequestOptions options) =>
            <String, dynamic>{'ticket': 'tk', 'expires_at': 1},
      );
      final api = WebViewTicketApi(client: client, store: store);

      await api.issue(deviceId: 'dev_1');
      expect(_bodyOf(adapter.captured[0])['ttl_s'], 120);

      await api.issue(deviceId: 'dev_1', ttlSeconds: 30);
      expect(_bodyOf(adapter.captured[1])['ttl_s'], 30);
    });

    test('红线 R3：WebViewTicket.toString() 绝不泄漏 ticket 明文', () async {
      final (:client, :adapter, :store) = _build(
        (RequestOptions options) => <String, dynamic>{
          'ticket': 'SUPER_SECRET_TICKET',
          'expires_at': 1762500120000,
        },
      );
      final api = WebViewTicketApi(client: client, store: store);
      final ticket = await api.issue(deviceId: 'dev_1');

      // 即使有人误把对象丢进日志，也不能带出凭据
      expect(ticket.toString().contains('SUPER_SECRET_TICKET'), isFalse);
      expect(ticket.toString().contains('expires_at'), isTrue);
    });

    test('workspaces 列表只打 GET /api/v1/workspaces 且不带请求体', () async {
      final (:client, :adapter, :store) = _build(
        (RequestOptions options) => <String, dynamic>{
          'items': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 'ws_1',
              'name': '手机空间',
              'kind': 'mobile',
              'online': true,
              'host': 'device:dev_1',
            },
          ],
        },
      );
      final api = WorkspaceApi(client: client);
      final list = await api.listWorkspaces();

      final options = adapter.captured.single;
      expect(options.path, '/api/v1/workspaces');
      expect(options.method, 'GET');
      // GET 不得携带请求体（否则服务端解析异常）
      expect(options.data, isNull);
      expect(list.length, 1);
      expect(list.single.id, 'ws_1');
      expect(list.single.isMobile, isTrue);
    });

    test('items 缺失或非数组 → 空列表，不抛异常', () async {
      final (:client, :adapter, :store) = _build(
        (RequestOptions options) => <String, dynamic>{'items': 'oops'},
      );
      final api = WorkspaceApi(client: client);
      expect(await api.listWorkspaces(), isEmpty);
      // 空 body 同样返回空列表
      final empty = _build((RequestOptions options) => null);
      final emptyApi = WorkspaceApi(client: empty.client);
      expect(await emptyApi.listWorkspaces(), isEmpty);
    });

    test('getWorkspace 404 → AppError 且不返回半成品对象', () async {
      final adapter = _FakeAdapter(
        (RequestOptions options) => ResponseBody.fromString(
          jsonEncode(<String, dynamic>{
            'error': <String, dynamic>{
              'code': 'workspace.not_found',
              'message': '工作空间不存在',
            },
          }),
          404,
          headers: <String, List<String>>{
            Headers.contentTypeHeader: <String>[Headers.jsonContentType],
          },
        ),
      );
      final client = ApiClient(
        baseUrl: 'http://localhost:8080',
        tokens: TokenProvider(InMemorySecureStore()),
        dio: Dio()..httpClientAdapter = adapter,
      );
      final api = WorkspaceApi(client: client);

      await expectLater(
        api.getWorkspace('ws_missing'),
        throwsA(
          isA<AppError>().having(
            (AppError e) => e.message,
            'message',
            '工作空间不存在',
          ),
        ),
      );
    });
  });

  group('模型宽容解析（现役：WorkSpace / Capability）', () {
    test('WorkSpace 能解析服务端完整 JSON（含 int64 毫秒时间戳）', () {
      // 字段与 internal/api/workspace_handler.go / model.Workspace 对齐
      final json = <String, dynamic>{
        'id': 'ws_1',
        'name': '我的手机空间',
        'kind': WorkspaceKinds.mobile,
        'device_id': 'dev_1',
        'root_path': '/data/harness',
        'online': true,
        'host': 'device:dev_1',
        'created_at': 1762400000000,
        'updated_at': 1762500000456,
      };
      final ws = WorkSpace.fromJson(json);

      expect(ws.id, 'ws_1');
      expect(ws.name, '我的手机空间');
      expect(ws.kind, WorkspaceKinds.mobile);
      expect(ws.deviceId, 'dev_1');
      expect(ws.rootPath, '/data/harness');
      expect(ws.online, isTrue);
      expect(ws.host, 'device:dev_1');
      // int64 毫秒：必须精确，不能被当作 double 丢精度
      expect(ws.createdAt, 1762400000000);
      expect(ws.updatedAt, 1762500000456);
      // 能力天花板只看 kind（协议 §4.1），与 online 无关
      expect(ws.isMobile, isTrue);
    });

    test('WorkSpace 缺字段 / 数字为 double 时也不崩，且 online 只认 true', () {
      final ws = WorkSpace.fromJson(<String, dynamic>{
        'id': 'ws_2',
        'created_at': 1762400000000.0,
        // 服务端若下发 "true"（字符串）不得被宽松当成在线
        'online': 'true',
      });
      expect(ws.id, 'ws_2');
      expect(ws.name, '');
      expect(ws.kind, '');
      expect(ws.rootPath, '');
      expect(ws.host, '');
      expect(ws.createdAt, 1762400000000);
      expect(ws.updatedAt, 0);
      // 否定断言：非布尔 true 一律判离线（防「假在线」误导 UI 置灰判断）
      expect(ws.online, isFalse);
      expect(ws.isMobile, isFalse);
    });

    test('WorkspaceKinds 与 DeviceKinds 是两套独立枚举，不得混用', () {
      // 协议 §2.4.3：不存在映射关系，cli/tablet 属于设备形态而非空间类型
      expect(WorkspaceKinds.server, 'server');
      expect(WorkspaceKinds.desktop, 'desktop');
      expect(WorkspaceKinds.mobile, 'mobile');
      expect(WorkspaceKinds.browser, 'browser');
      final workspaceKinds = <String>{
        WorkspaceKinds.server,
        WorkspaceKinds.desktop,
        WorkspaceKinds.mobile,
        WorkspaceKinds.browser,
      };
      expect(workspaceKinds.contains(DeviceKinds.cli), isFalse);
      expect(workspaceKinds.contains(DeviceKinds.tablet), isFalse);
    });

    test('Capability 上行只发 name/version，下行才带 device_id/updated_at', () {
      const cap = Capability(
        name: MobileCapabilities.network,
        version: '1',
        deviceId: 'dev_1',
        updatedAt: 1762500000000,
      );
      // 上行：多一个键即被 DisallowUnknownFields 拒 400
      expect(
        cap.toRequestJson().keys.toList(),
        unorderedEquals(<String>['name', 'version']),
      );
      // 下行：updated_at 非 omitempty 恒出现
      expect(
        cap.toJson().keys.toList(),
        unorderedEquals(<String>[
          'device_id',
          'name',
          'version',
          'updated_at',
        ]),
      );
    });
  });
}
