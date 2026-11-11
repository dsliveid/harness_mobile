/// WebView 认证透传测试（[WebViewTicketApi]，批次 C-4）。
///
/// 覆盖架构文档 §4.2 的两条路径与一条红线：
/// - **方案 C（ticket）**：原生换一次性 ticket → 页面用 fragment 携带换会话；
/// - **方案 B（Cookie 降级）**：ticket 端点未接线时把原生会话写进 CookieManager；
/// - **红线 R3**：ticket / 用户令牌**绝不进日志、绝不进注入脚本**、不落进错误文案。
///
/// 关键否定断言（不是只测 happy path）：
/// 1. `buildBridgeScript` 的输出里**绝不能**出现 ticket 或任何令牌；
/// 2. `WebViewTicket.toString()` / `WebViewAuthResult.toString()` 打码；
/// 3. 方案 C 失败时必须降级而不是抛给 UI，两条都不可用 → `none`（回原生登录）。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_mobile/data/local/secure_store.dart';
import 'package:harness_mobile/data/remote/http_client.dart';
import 'package:harness_mobile/data/remote/webview_ticket_api.dart';
import 'package:harness_mobile/features/webview/js_bridge.dart';

/// 可编排的拦截适配器：按 handler 构造响应，记录全部请求。
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

ResponseBody _json(Object? body, {int status = 200}) => ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>[Headers.jsonContentType],
      },
    );

/// 假的 Cookie 写入端口（记录写入内容，便于断言"写的是什么"）。
class _FakeCookieSink implements WebViewCookieSink {
  _FakeCookieSink({this.accept = true});

  final bool accept;
  final List<({String url, String name, String value})> writes =
      <({String url, String name, String value})>[];
  int clearCount = 0;

  @override
  Future<bool> writeSessionCookie({
    required String url,
    required String name,
    required String value,
  }) async {
    writes.add((url: url, name: name, value: value));
    return accept;
  }

  @override
  Future<void> clearSessionCookies() async {
    clearCount++;
  }
}

({WebViewTicketApi api, _FakeAdapter adapter, InMemorySecureStore store}) _build(
  ResponseBody Function(RequestOptions options) handler, {
  String? userToken,
  String? deviceToken,
  int ttl = 120,
}) {
  final adapter = _FakeAdapter(handler);
  final store = InMemorySecureStore();
  if (userToken != null) {
    // InMemorySecureStore 的写入是同步落 Map 的，这里用 await 保持接口一致
    store.setUserToken(userToken);
  }
  if (deviceToken != null) {
    store.setDeviceToken(deviceToken);
  }
  final client = ApiClient(
    baseUrl: 'http://localhost:8080',
    tokens: TokenProvider(store),
    dio: Dio()..httpClientAdapter = adapter,
  );
  return (
    api: WebViewTicketApi(client: client, store: store, defaultTtlSeconds: ttl),
    adapter: adapter,
    store: store,
  );
}

void main() {
  group('appendTicketFragment（纯函数）', () {
    test('裸入口 URL → 追加 #ticket=', () {
      final url = appendTicketFragment('http://h:8080/', 'tk_1');
      expect(url, 'http://h:8080/#ticket=tk_1');
      expect(extractTicketFragment(url), 'tk_1');
    });

    test('保留既有 hash 路由（服务端 Web UI 是 hash 路由，冲掉会白屏）', () {
      final url = appendTicketFragment('http://h:8080/#/', 'tk_1');
      // `#/` 必须仍在，ticket 追加在其后
      expect(url.startsWith('http://h:8080/#/'), isTrue);
      expect(url.contains('ticket=tk_1'), isTrue);
      expect(extractTicketFragment(url), 'tk_1');
    });

    test('ticket 走 fragment 而非 query（不进 Referer / access log）', () {
      final url = appendTicketFragment('http://h:8080/', 'tk_1');
      final uri = Uri.parse(url);
      // 硬约束：query 必须为空，凭据只能出现在 fragment
      expect(uri.query.isEmpty, isTrue);
      expect(uri.queryParameters.containsKey('ticket'), isFalse);
      expect(uri.fragment, contains('ticket='));
    });

    test('特殊字符被 encodeComponent（防 fragment 注入）', () {
      final url = appendTicketFragment('http://h:8080/', 'a&b=c d/#e');
      final uri = Uri.parse(url);
      // 原始 & = 空格 # 不得以裸形态出现，否则会被拆成额外参数
      expect(uri.fragment.contains('a&b=c'), isFalse);
      expect(extractTicketFragment(url), 'a&b=c d/#e');
    });

    test('空入口 / 空 ticket → 原样返回，不产生半截 URL', () {
      expect(appendTicketFragment('', 'tk'), '');
      expect(appendTicketFragment('http://h:8080/', ''), 'http://h:8080/');
    });

    test('无 scheme 的裸文本不抛异常，且不产生「半截 URL」', () {
      // 事实核定：Uri.tryParse('not a url') 其实**会**成功（空格被编码），
      // 因此 appendTicketFragment 不会走 null 分支。这里锁定真实行为：
      // 不崩、且返回值始终是合法 Uri。
      final out = appendTicketFragment('not a url', 'tk');
      expect(out, isNotEmpty);
      expect(Uri.tryParse(out), isNotNull);
      // ticket 仍被正确携带（不会被吞掉）
      expect(extractTicketFragment(out), 'tk');
    });
  });

  group('红线 R3：ticket / 令牌绝不进日志与注入脚本', () {
    test('WebViewTicket.toString() 不含 ticket 明文', () {
      const ticket = WebViewTicket(ticket: 'SECRET_TK', expiresAt: 123);
      expect(ticket.toString().contains('SECRET_TK'), isFalse);
      expect(ticket.toString(), contains('123'));
    });

    test('WebViewAuthResult.toString() 只暴露模式，不含 URL（URL 带 ticket）', () {
      const result = WebViewAuthResult(
        mode: WebViewAuthMode.ticket,
        url: 'http://h:8080/#ticket=SECRET_TK',
        expiresAt: 123,
      );
      expect(result.toString().contains('SECRET_TK'), isFalse);
      expect(result.toString(), contains('ticket'));
    });

    test('注入脚本绝不能出现 ticket / 任何令牌字段（R3 硬门禁）', () {
      final script = buildBridgeScript(appVersion: '1.2.3');
      // 令牌类
      for (final forbidden in <String>[
        'device_token',
        'deviceToken',
        'user_token',
        'userToken',
        'access_token',
        'refresh_token',
        'Authorization',
        'Bearer',
        'password',
        'ticket',
        'hg_sess',
      ]) {
        expect(
          script.contains(forbidden),
          isFalse,
          reason: '注入脚本出现了 "$forbidden"，违反红线 R3（凭据泄漏到页面上下文）',
        );
      }
    });

    test('注入脚本只声明能力，不含任何真实凭据值', () {
      final script = buildBridgeScript(appVersion: '1.2.3');
      // 能力声明必须存在（页面据此降级 UI）
      expect(script, contains('capabilities'));
      expect(script, contains('approvalDecide'));
      // 移动端不执行命令、不能建项目
      expect(script, contains('exec: false'));
      expect(script, contains('createProject: false'));
    });
  });

  group('issue（方案 C：一次性票据签发）', () {
    test('成功签发返回 ticket 与 expires_at', () async {
      final (:api, :adapter, :store) = _build(
        (RequestOptions options) =>
            _json(<String, dynamic>{'ticket': 'tk_1', 'expires_at': 999}),
      );
      final ticket = await api.issue(deviceId: 'dev_1');

      expect(ticket.ticket, 'tk_1');
      expect(ticket.expiresAt, 999);
      expect(ticket.isEmpty, isFalse);
      expect(adapter.captured.single.path, '/api/v1/auth/webview-ticket');
    });

    test('服务端未返回 ticket → isEmpty 为真（调用方据此降级）', () async {
      final (:api, :adapter, :store) = _build(
        (RequestOptions options) => _json(<String, dynamic>{'expires_at': 1}),
      );
      final ticket = await api.issue(deviceId: 'dev_1');
      expect(ticket.isEmpty, isTrue);
      expect(ticket.ticket, '');
    });

    test('ticket 非字符串（如数字）→ 宽容降级为空，不抛类型异常', () async {
      final (:api, :adapter, :store) = _build(
        (RequestOptions options) => _json(<String, dynamic>{'ticket': 12345}),
      );
      final ticket = await api.issue(deviceId: 'dev_1');
      expect(ticket.ticket, '');
      expect(ticket.isEmpty, isTrue);
    });

    test('该端点需要用户会话：不得打 skipAuth（否则服务端无用户上下文）',
        () async {
      final (:api, :adapter, :store) = _build(
        (RequestOptions options) =>
            _json(<String, dynamic>{'ticket': 'tk', 'expires_at': 1}),
        userToken: 'ut_secret',
      );
      await api.issue(deviceId: 'dev_1');
      final options = adapter.captured.single;
      expect(options.extra[ApiClient.skipAuthKey], isNot(true));
      // 必须带 Bearer 令牌
      expect(options.headers['Authorization'], 'Bearer ut_secret');
    });
  });

  group('prepareAuth（方案 C 优先，失败降级 B）', () {
    test('ticket 可用 → mode=ticket 且 URL 带 fragment', () async {
      // ⚠️ fixture 修正（M3）：`expires_at` 是**毫秒**时间戳，原值 999 对应
      // 1970-01-01，本身就是一张过期票 —— 旧实现不校验过期因此侥幸通过，
      // 而 M3 起过期票会被判废重签（这正是要修的白屏成因）。
      // 这里改成远期时间戳以表达「票仍然有效」，断言强度不变。
      const futureExpiry = 1893456000000; // 2030-01-01
      final (:api, :adapter, :store) = _build(
        (RequestOptions options) => _json(
          <String, dynamic>{'ticket': 'tk_1', 'expires_at': futureExpiry},
        ),
      );
      final result = await api.prepareAuth(
        baseUrl: 'http://localhost:8080',
        entryUrl: 'http://localhost:8080/',
        deviceId: 'dev_1',
      );

      expect(result.mode, WebViewAuthMode.ticket);
      expect(result.ready, isTrue);
      expect(result.url, contains('#ticket=tk_1'));
      expect(result.expiresAt, futureExpiry);
      // 首发即可用 → 不应发生任何重签
      expect(result.ticketRenewCount, 0);
    });

    test('ticket 端点 404 → 静默降级到方案 B（不抛给 UI）', () async {
      // 路径感知：票据端点 404，但 `/auth/me` 必须 200 —— 否则 Cookie 降级前的
      // 有效性校验会把本次降级判为不可用（那是 Bug 2 修复的应有行为），
      // 本条断言的是「票据不可用时能降级」，因此用户会话必须是**有效的**。
      final (:api, :adapter, :store) = _build(
        (RequestOptions options) {
          if (options.path == '/api/v1/auth/me') {
            return _json(<String, dynamic>{'id': 'u1', 'username': 'alice'});
          }
          return _json(
            <String, dynamic>{
              'error': <String, dynamic>{'code': 'not_found', 'message': '未实现'},
            },
            status: 404,
          );
        },
        userToken: 'ut_secret',
      );
      final sink = _FakeCookieSink();
      final result = await api.prepareAuth(
        baseUrl: 'http://localhost:8080',
        entryUrl: 'http://localhost:8080/',
        deviceId: 'dev_1',
        cookieSink: sink,
      );

      expect(result.mode, WebViewAuthMode.cookie);
      expect(result.ready, isTrue);
      // 降级后 URL 必须是裸入口（不能残留半截 fragment）
      expect(result.url, 'http://localhost:8080/');
      expect(result.url.contains('ticket'), isFalse);
      // Cookie 写入内容：name 为 hg_sess，value 为用户令牌
      expect(sink.writes.single.name, kSessionCookieName);
      expect(sink.writes.single.value, 'ut_secret');
    });

    test('ticket 失败 + 无 cookieSink → mode=none（回原生登录，不弹 Web 登录表单）',
        () async {
      final (:api, :adapter, :store) = _build(
        (RequestOptions options) => _json(<String, dynamic>{}, status: 500),
      );
      final result = await api.prepareAuth(
        baseUrl: 'http://localhost:8080',
        entryUrl: 'http://localhost:8080/',
        deviceId: 'dev_1',
      );
      expect(result.mode, WebViewAuthMode.none);
      expect(result.ready, isFalse);
      expect(result.url, 'http://localhost:8080/');
    });

    test('无 deviceId → 直接跳过方案 C，只用 Cookie 降级', () async {
      final (:api, :adapter, :store) = _build(
        (RequestOptions options) => _json(<String, dynamic>{'ticket': 'tk', 'expires_at': 1}),
        userToken: 'ut_secret',
      );
      final sink = _FakeCookieSink();
      final result = await api.prepareAuth(
        baseUrl: 'http://localhost:8080',
        entryUrl: 'http://localhost:8080/',
        cookieSink: sink,
      );

      expect(result.mode, WebViewAuthMode.cookie);
      // 未尝试签发 ticket（Cookie 降级前的有效性校验会打 /auth/me，
      // 那是**另一条**端点，不能用「零请求」来断言「没走方案 C」）
      expect(
        adapter.captured.map((RequestOptions r) => r.path),
        isNot(contains('/api/v1/auth/webview-ticket')),
      );
    });

    test('Cookie sink 拒绝写入 → none（不得谎报已透传）', () async {
      final (:api, :adapter, :store) = _build(
        (RequestOptions options) => _json(<String, dynamic>{}, status: 404),
        userToken: 'ut_secret',
      );
      final sink = _FakeCookieSink(accept: false);
      final result = await api.prepareAuth(
        baseUrl: 'http://localhost:8080',
        entryUrl: 'http://localhost:8080/',
        deviceId: 'dev_1',
        cookieSink: sink,
      );
      expect(result.mode, WebViewAuthMode.none);
      expect(result.ready, isFalse);
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  // P1 兜底加固：「两轮登录」回归保护。
  //
  // 旧实现 ticket 一成功就 return，方案 B（写 hg_sess）永远走不到 —— 于是
  // Web 前端一旦没有消费 `#ticket=`（兑换环节断链），页面 `/auth/me` 就 401，
  // 用户在 WebView 里被要求**再登一次**。
  // 新语义：ticket 成功 → 仍 best-effort 补写 Cookie，但**绝不**因补写失败降级。
  // ══════════════════════════════════════════════════════════════════════════
  group('prepareAuth：ticket 成功后的 best-effort Cookie 兜底（P1）', () {
    /// 票据端点吐有效票，其余（`/auth/me`）按 [sessionValid] 应答。
    ({WebViewTicketApi api, _FakeAdapter adapter, InMemorySecureStore store})
        buildTicketOk({bool sessionValid = true}) => _build(
              (RequestOptions options) {
                if (options.path == '/api/v1/auth/me') {
                  return sessionValid
                      ? _json(<String, dynamic>{'id': 'u1', 'username': 'alice'})
                      : _json(
                          <String, dynamic>{
                            'error': <String, dynamic>{'code': 'unauthorized'},
                          },
                          status: 401,
                        );
                }
                return _json(<String, dynamic>{
                  'ticket': 'tk_1',
                  'expires_at': 1893456000000, // 2030-01-01，确保未过期
                });
              },
              userToken: 'ut_secret',
            );

    test('ticket 成功 + Cookie 注入也成功 → mode=ticket 且 cookieInjected=true',
        () async {
      final (:api, :adapter, :store) = buildTicketOk();
      final sink = _FakeCookieSink();
      final result = await api.prepareAuth(
        baseUrl: 'http://localhost:8080',
        entryUrl: 'http://localhost:8080/',
        deviceId: 'dev_1',
        cookieSink: sink,
      );

      // 主路径不变：仍然是 ticket（兜底不得篡改 mode）
      expect(result.mode, WebViewAuthMode.ticket);
      expect(result.ready, isTrue);
      expect(result.failure, isNull);
      expect(result.url, contains('#ticket=tk_1'));
      // 兜底确实落地：双写（ticket + hg_sess）
      expect(result.cookieInjected, isTrue);
      expect(sink.writes.single.name, kSessionCookieName);
      expect(sink.writes.single.value, 'ut_secret');
    });

    test('★ ticket 成功 + Cookie 注入失败 → 仍 mode=ticket / ready / failure=null',
        () async {
      // 本组**最关键**的回归保护：兜底失败绝不能把已成功的 ticket 降级，
      // 更不能产生 failure 文案（否则用户会看到与本可用的链路无关的错误）。
      final (:api, :adapter, :store) = buildTicketOk();
      final sink = _FakeCookieSink(accept: false);
      final result = await api.prepareAuth(
        baseUrl: 'http://localhost:8080',
        entryUrl: 'http://localhost:8080/',
        deviceId: 'dev_1',
        cookieSink: sink,
      );

      expect(result.mode, WebViewAuthMode.ticket);
      expect(result.ready, isTrue);
      expect(result.failure, isNull);
      expect(result.failureMessage, '');
      expect(result.url, contains('#ticket=tk_1'));
      // 观测位如实反映「没写进去」
      expect(result.cookieInjected, isFalse);
      // 确实尝试过（证明不是「压根没走兜底」的假通过）
      expect(sink.writes.length, 1);
    });

    test('ticket 成功 + Cookie 前置校验失败（/auth/me 401）→ 不写 jar 也不降级',
        () async {
      // 死令牌绝不能进 Cookie jar（Bug 2 铁律），但 ticket 依然可用。
      final (:api, :adapter, :store) = buildTicketOk(sessionValid: false);
      final sink = _FakeCookieSink();
      final result = await api.prepareAuth(
        baseUrl: 'http://localhost:8080',
        entryUrl: 'http://localhost:8080/',
        deviceId: 'dev_1',
        cookieSink: sink,
      );

      expect(sink.writes, isEmpty);
      expect(result.mode, WebViewAuthMode.ticket);
      expect(result.cookieInjected, isFalse);
      expect(result.failure, isNull);
    });

    test('ticket 成功 + cookieSink == null → 不抛异常，cookieInjected=false',
        () async {
      final (:api, :adapter, :store) = buildTicketOk();
      final result = await api.prepareAuth(
        baseUrl: 'http://localhost:8080',
        entryUrl: 'http://localhost:8080/',
        deviceId: 'dev_1',
        // 未装配 Cookie 端口（WebViewPage 在某些入口就是这样）
        cookieSink: null,
      );

      expect(result.mode, WebViewAuthMode.ticket);
      expect(result.ready, isTrue);
      expect(result.cookieInjected, isFalse);
    });

    test('Cookie 降级成功时 cookieInjected 也应为 true（观测位语义一致）',
        () async {
      // 反面对照：降级路径本来就是「注入成功才 return」，因此必须为 true。
      final (:api, :adapter, :store) = _build(
        (RequestOptions options) {
          if (options.path == '/api/v1/auth/me') {
            return _json(<String, dynamic>{'id': 'u1', 'username': 'alice'});
          }
          return _json(<String, dynamic>{}, status: 404); // 票据端点未实现
        },
        userToken: 'ut_secret',
      );
      final sink = _FakeCookieSink();
      final result = await api.prepareAuth(
        baseUrl: 'http://localhost:8080',
        entryUrl: 'http://localhost:8080/',
        deviceId: 'dev_1',
        cookieSink: sink,
      );

      expect(result.mode, WebViewAuthMode.cookie);
      expect(result.cookieInjected, isTrue);
    });
  });

  group('injectSessionCookie（方案 B）', () {
    test('无用户令牌 → 直接 false，不调用 sink（避免写入空 Cookie）', () async {
      final (:api, :adapter, :store) = _build(
        (RequestOptions options) => _json(<String, dynamic>{}),
      );
      final sink = _FakeCookieSink();
      final ok = await api.injectSessionCookie(
        sink: sink,
        baseUrl: 'http://localhost:8080',
      );
      expect(ok, isFalse);
      expect(sink.writes, isEmpty);
    });

    test('有令牌 → 写入 hg_sess，且 url 是 baseUrl', () async {
      final (:api, :adapter, :store) = _build(
        (RequestOptions options) => _json(<String, dynamic>{}),
        userToken: 'ut_secret',
      );
      final sink = _FakeCookieSink();
      final ok = await api.injectSessionCookie(
        sink: sink,
        baseUrl: 'http://localhost:8080',
      );
      expect(ok, isTrue);
      expect(sink.writes.single.name, 'hg_sess');
      expect(sink.writes.single.url, 'http://localhost:8080');
    });

    test('空串令牌等同无令牌', () async {
      final store = InMemorySecureStore();
      await store.setUserToken('');
      final adapter = _FakeAdapter(
        (RequestOptions options) => _json(<String, dynamic>{}),
      );
      final api = WebViewTicketApi(
        client: ApiClient(
          baseUrl: 'http://localhost:8080',
          tokens: TokenProvider(store),
          dio: Dio()..httpClientAdapter = adapter,
        ),
        store: store,
      );
      final sink = _FakeCookieSink();
      expect(
        await api.injectSessionCookie(
          sink: sink,
          baseUrl: 'http://localhost:8080',
        ),
        isFalse,
      );
      expect(sink.writes, isEmpty);
    });
  });
}
