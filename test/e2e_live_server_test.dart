/// 三端联调 E2E：移动端真实 API 层 ↔ 真实服务端（harness_go）。
///
/// 与 test/data/* 下的 mock 测试不同，本文件**不发任何 fake**：
/// AuthApi / DeviceApi / WebViewTicketApi 全部走真实 dio socket，
/// 打到 `HARNESS_E2E_BASE_URL`（默认 http://127.0.0.1:5611）。
///
/// 覆盖的移动端主链（与 App 运行期同一条路径）：
///   登录 → 签发配对码 → 凭码配对（device_token 入 SecureStore）
///   → 签发 WebView ticket → 页面内兑换（Set-Cookie）
///   → 建纯对话会话 → 发起 run → 轮询消息断言助手回复
///
/// 运行条件（不满足时**自动跳过**，绝不让常规 `flutter test` 变红）：
///   1. 服务端已在 BASE_URL 运行；
///   2. `HARNESS_E2E_PASSWORD` 提供登录口令（用户名可用 HARNESS_E2E_USER 覆盖，
///      默认 admin）。口令不写进仓库。
///
/// 用法（Windows PowerShell）：
///   $env:HARNESS_E2E_PASSWORD='...'
///   flutter test test/e2e_live_server_test.dart
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:harness_mobile/data/local/secure_store.dart';
import 'package:harness_mobile/data/remote/auth_api.dart';
import 'package:harness_mobile/data/remote/device_api.dart';
import 'package:harness_mobile/data/remote/http_client.dart';
import 'package:harness_mobile/data/remote/webview_ticket_api.dart';

const String _baseUrlEnv = 'HARNESS_E2E_BASE_URL';

Future<String> resolveBaseUrl() async =>
    Platform.environment[_baseUrlEnv] ?? 'http://127.0.0.1:5611';

Future<bool> probeHealthz(String baseUrl) async {
  try {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
    final req = await client.getUrl(Uri.parse('$baseUrl/healthz'));
    final resp = await req.close().timeout(const Duration(seconds: 5));
    await resp.drain<void>();
    client.close(force: true);
    return resp.statusCode == 200;
  } catch (_) {
    return false;
  }
}

void main() {
  final baseUrl = Platform.environment[_baseUrlEnv] ?? 'http://127.0.0.1:5611';
  final user = Platform.environment['HARNESS_E2E_USER'] ?? 'admin';
  final password = Platform.environment['HARNESS_E2E_PASSWORD'] ?? '';

  late ApiClient client;
  late InMemorySecureStore store;

  setUpAll(() async {});

  /// 前置条件不满足时返回 null，用例自行跳过。
  Future<ApiClient?> ready() async {
    if (password.isEmpty) return null;
    if (!await probeHealthz(baseUrl)) return null;
    store = InMemorySecureStore();
    client = ApiClient(baseUrl: baseUrl, tokens: TokenProvider(store));
    return client;
  }

  test('移动端主链：登录→配对→ticket→兑换→建会话→对话→回复', () async {
    if (await ready() == null) {
      markTestSkipped('服务端不可达或未设置 HARNESS_E2E_PASSWORD');
      return;
    }

    // ── 1. 登录（真实表单接口，token 落 SecureStore）──────────────────────
    final authApi = AuthApi(client: client, store: store);
    final authUser = await authApi.login(username: user, password: password);
    expect(authUser.username, user);
    expect(await store.getUserToken(), isNotNull, reason: '登录后应有 user_token');

    // ── 2. 签发配对码 + 凭码配对（device_token 落 SecureStore）────────────
    final deviceApi = DeviceApi(
      client: client,
      store: store,
      platform: 'windows',
      appVersion: '0.1.0-e2e',
    );
    final pairCode =
        await deviceApi.createPairCode(name: 'e2e-live', kind: 'mobile');
    expect(pairCode.code, hasLength(6), reason: '服务端配对码应为 6 位数字');
    final paired = await deviceApi.pair(
      code: pairCode.code,
      name: 'flutter-e2e',
      platformOverride: 'windows',
      appVersionOverride: '0.1.0-e2e',
    );
    expect(paired.deviceId, isNotEmpty);
    expect(await store.getDeviceToken(), isNotEmpty,
        reason: '配对后应有 device_token');

    // ── 3. WebView ticket 签发 + 兑换（方案 C）──────────────────────────
    final ticketApi = WebViewTicketApi(
      client: client,
      store: store,
      defaultTtlSeconds: 60,
    );
    final ticket = await ticketApi.issue(deviceId: paired.deviceId);
    expect(ticket.ticket, isNotEmpty);

    // 兑换是页面内 JS 的动作：这里按同一线上契约直接打免鉴权端点。
    final exchange = await client.post<Map<String, dynamic>>(
      '/api/v1/auth/webview-exchange',
      body: <String, dynamic>{'ticket': ticket.ticket},
      options: ApiClient.skipAuth(),
      parse: mapOf,
    );
    expect(exchange['ok'], true, reason: 'ticket 应能兑换出 hg_sess 会话');

    // 一次性语义：同一张 ticket 第二次兑换必须失败（401）。
    Object? replayError;
    try {
      await client.post<Map<String, dynamic>>(
        '/api/v1/auth/webview-exchange',
        body: <String, dynamic>{'ticket': ticket.ticket},
        options: ApiClient.skipAuth(),
        parse: mapOf,
      );
    } catch (e) {
      replayError = e;
    }
    expect(replayError, isNotNull, reason: '已消费的 ticket 重放必须失败');

    // ── 4. 建纯对话会话（workspace_id 空 → 仅对话能力天花板）────────────
    final created = await client.post<Map<String, dynamic>>(
      '/api/v1/sessions',
      body: <String, dynamic>{
        'title': 'flutter-e2e-基础对话',
        'access_mode': 'confirm',
      },
      parse: mapOf,
    );
    final sessionId = created['id'] as String;
    expect(sessionId, isNotEmpty);

    // ── 5. 发起 run 并轮询助手回复 ─────────────────────────────────────
    final run = await client.post<Map<String, dynamic>>(
      '/api/v1/sessions/$sessionId/runs',
      body: <String, dynamic>{
        'input': 'E2E 验证：请只回复四个字：联调畅通',
      },
      parse: mapOf,
    );
    expect(run['run_id'], isNotEmpty, reason: 'run 应被受理（202）');

    final reply = await _waitForAssistantReply(client, sessionId);
    expect(reply, isNotEmpty, reason: '60s 内应收到助手回复（真实 LLM）');
    printOnFailure('助手回复：$reply');
  });

  test('降级会话禁审批：webview Cookie 打审批端点必须 403', () async {
    if (await ready() == null) {
      markTestSkipped('服务端不可达或未设置 HARNESS_E2E_PASSWORD');
      return;
    }

    final authApi = AuthApi(client: client, store: store);
    await authApi.login(username: user, password: password);

    final deviceApi = DeviceApi(
      client: client,
      store: store,
      platform: 'windows',
      appVersion: '0.1.0-e2e',
    );
    final pairCode =
        await deviceApi.createPairCode(name: 'e2e-live-2', kind: 'mobile');
    final paired = await deviceApi.pair(
      code: pairCode.code,
      name: 'flutter-e2e-2',
      platformOverride: 'windows',
      appVersionOverride: '0.1.0-e2e',
    );

    final ticketApi = WebViewTicketApi(
      client: client,
      store: store,
      defaultTtlSeconds: 60,
    );
    final ticket = await ticketApi.issue(deviceId: paired.deviceId);

    // 用底层 HttpClient 打兑换端点并读取 Set-Cookie（dio 不暴露 cookie jar）。
    final sess = await _exchangeAndGetSessionCookie(baseUrl, ticket.ticket);
    expect(sess, isNotNull, reason: '兑换响应应下发 hg_sess Cookie');

    // 用该 Cookie 打审批决策端点：不存在的 run/approval 也必须先撞 403 闸门，
    // 而不是 404 —— 这证明 webview kind 检查发生在业务查找之前（协议 §6.2 硬约束③）。
    final status = await _postWithCookie(
      '$baseUrl/api/v1/sessions/e2e-none/runs/r0/approvals/a0/decide',
      cookie: 'hg_sess=$sess',
      body: '{"decision":"deny"}',
    );
    expect(status, 403,
        reason: 'webview 降级会话必须被审批闸门拒绝（协议 §6.2）');
  });
}

/// 兑换 ticket 并从 Set-Cookie 里取 hg_sess 值。
Future<String?> _exchangeAndGetSessionCookie(
  String baseUrl,
  String ticket,
) async {
  final req = await HttpClient()
      .postUrl(Uri.parse('$baseUrl/api/v1/auth/webview-exchange'));
  req.headers.set('Content-Type', 'application/json');
  req.write(jsonEncode(<String, dynamic>{'ticket': ticket}));
  final resp = await req.close();
  final body = await resp.transform(utf8.decoder).join();
  if (resp.statusCode != 200) {
    fail('兑换失败 HTTP ${resp.statusCode}: $body');
  }
  final setCookie = resp.headers.value('set-cookie') ?? '';
  return RegExp('hg_sess=([^;]+)').firstMatch(setCookie)?.group(1);
}

/// 带固定 Cookie 发 POST，返回状态码。
Future<int> _postWithCookie(
  String url, {
  required String cookie,
  required String body,
}) async {
  final req = await HttpClient().postUrl(Uri.parse(url));
  req.headers.set('Content-Type', 'application/json');
  req.headers.set('Cookie', cookie);
  req.write(body);
  final resp = await req.close();
  await resp.drain<void>();
  return resp.statusCode;
}

/// 轮询会话消息，取最后一条非空 assistant 消息（最多 60s）。
Future<String> _waitForAssistantReply(
  ApiClient client,
  String sessionId,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 60));
  while (DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(seconds: 2));
    try {
      final page = await client.get<Map<String, dynamic>>(
        '/api/v1/sessions/$sessionId/messages?limit=100',
        parse: mapOf,
      );
      final items = page['items'] as List<dynamic>? ?? <dynamic>[];
      for (final m in items.reversed) {
        final role = (m as Map<String, dynamic>)['role'];
        if (role == 'assistant') {
          final content = m['content'] as String? ?? '';
          if (content.isNotEmpty) return content;
        }
      }
    } catch (_) {
      // run 尚未产生消息 / 瞬时网络问题：继续轮询直到超时
    }
  }
  return '';
}
