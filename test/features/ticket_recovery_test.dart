/// 票据失效恢复测试（M3：消除静默白屏）。
///
/// 问题本质（已代码级确认）：`prepareAuth` 曾无条件把签发出的 ticket 拼进
/// 首帧 URL。但 ticket 的 TTL 很短（默认 120s），「签发 → 真正加载」之间
/// 可能已跨过过期点（冷启动、弱网、锁屏被挂起）。**过期票塞进 URL 不会抛错**：
/// 页面照常加载，只是 ticket 兑换失败、Web UI 停在未登录态 —— 用户看到的就是
/// 一片没有解释的空白。
///
/// 本文件按交接书要求覆盖三条路径：
/// 1. **过期票可复现**：用服务端下发的 `expires_at` + 注入的假时钟构造，
///    不依赖真实等待（否则测试不稳定）。
/// 2. **过期 → 重签成功 → 页面恢复**：断言重签了一次、URL 里是新票、
///    过期的旧票**绝不**出现在 URL 里。
/// 3. **重签失败 → 明确错误 UI（可重试 + 可读文案）而非白屏**：
///    断言 UI 里有「重试票据申请」按钮与含原因的文案，且没有创建 WebView。
library;

import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_mobile/core/app/api_services.dart';
import 'package:harness_mobile/core/app/biometric_gate.dart';
import 'package:harness_mobile/core/app/providers.dart';
import 'package:harness_mobile/core/app/webview_lock.dart';
import 'package:harness_mobile/data/local/app_settings_store.dart';
import 'package:harness_mobile/data/local/secure_store.dart';
import 'package:harness_mobile/data/remote/http_client.dart';
import 'package:harness_mobile/data/remote/webview_ticket_api.dart';
import 'package:harness_mobile/features/webview/webview_page.dart';

/// 测试基准时刻（毫秒）。所有「已过期 / 未过期」都相对它计算，
/// 使过期判定成为**确定性的**而非依赖真实时钟。
const int kNowMs = 1893456000000; // 2030-01-01T00:00:00Z

/// 已过期 60 秒的票据。
const int kExpiredAt = kNowMs - 60000;

/// 仍然有效（还有 60 秒）的票据。
const int kValidAt = kNowMs + 60000;

/// **真实世界**已过期的票据（2001-09-09）。
///
/// 页面层用例走的是生产代码的真实时钟（`DateTime.now()`，页面不注入 nowMs），
/// 因此这里必须用「相对今天早已过去」的时间戳，才能真实复现「签发出来的票已废」。
const int kRealPastExpiry = 1000000000000;

/// **真实世界**远期有效的票据（2030-01-01）。
const int kRealFutureExpiry = 1893456000000;

/// 假的内置浏览器实例。
class _FakeWebView implements MobileWebView {
  int reloadCount = 0;

  @override
  Widget build(BuildContext context) =>
      const Center(child: Text('内置页面已恢复', textDirection: TextDirection.ltr));

  @override
  Future<void> reload() async => reloadCount++;

  @override
  Future<bool> canGoBack() async => false;

  @override
  Future<void> goBack() async {}

  @override
  void dispose() {}
}

class _FakeFactory implements WebViewFactory {
  Uri? initialUrl;
  int createCount = 0;
  _FakeWebView? view;

  @override
  MobileWebView create({
    required Uri initialUrl,
    required String bridgeScript,
    required void Function(Uri url) onPageStarted,
    required void Function(Uri url) onPageFinished,
    required void Function(String message) onLoadFailed,
    required bool Function(Uri url) onNavigationRequest,
  }) {
    createCount++;
    this.initialUrl = initialUrl;
    final created = _FakeWebView();
    view = created;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      onPageFinished(initialUrl);
    });
    return created;
  }
}

/// 可编排的票据端点：按调用次序依次返回预设响应。
///
/// 这是构造「过期票」的核心手段：让第 1 次签发返回 `expires_at` 已经过期的票，
/// 第 2 次（重签）返回有效票或失败。**不依赖真实时间流逝**。
class _SequencedTicketAdapter implements HttpClientAdapter {
  _SequencedTicketAdapter(this.responses);

  /// 每次调用的响应构造器（按顺序消费，越界则重复最后一个）。
  final List<ResponseBody Function()> responses;
  int calls = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final index = calls < responses.length ? calls : responses.length - 1;
    calls++;
    return responses[index]();
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _ticketResponse(String ticket, int? expiresAt) => ResponseBody.fromString(
      '{"ticket":"$ticket","expires_at":$expiresAt}',
      200,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>[Headers.jsonContentType],
      },
    );

ResponseBody _errorResponse(int status) => ResponseBody.fromString(
      '{"error":{"code":"unauthorized","message":"票据签发失败"}}',
      status,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>[Headers.jsonContentType],
      },
    );

({WebViewTicketApi api, _SequencedTicketAdapter adapter}) _buildApi(
  List<ResponseBody Function()> responses, {
  String? userToken,
}) {
  final adapter = _SequencedTicketAdapter(responses);
  final store = InMemorySecureStore();
  if (userToken != null) store.setUserToken(userToken);
  final client = ApiClient(
    baseUrl: 'http://localhost:8080',
    tokens: TokenProvider(store),
    dio: Dio()..httpClientAdapter = adapter,
  );
  return (api: WebViewTicketApi(client: client, store: store), adapter: adapter);
}

/// 渲染 WebViewPage（含身份齐备的 Provider 装配）。
Future<({ProviderContainer container, _FakeFactory factory})> _pumpPage(
  WidgetTester tester, {
  required HttpClientAdapter adapter,
  WebViewCookieSink? cookieSink,
}) async {
  final store = InMemorySecureStore();
  await store.setUserToken('ut-1');
  final factory = _FakeFactory();
  final container = ProviderContainer(
    overrides: <Override>[
      secureStoreProvider.overrideWithValue(store),
      settingsStoreProvider.overrideWithValue(
        InMemorySettingsStore(
          const AppSettings(
            baseUrl: 'http://localhost:8080',
            deviceId: 'dev-1',
            deviceName: '测试机',
          ),
        ),
      ),
      apiFactoryProvider.overrideWithValue(
        ApiFactory(store: store, dio: Dio()..httpClientAdapter = adapter),
      ),
      // 解锁门放开：本文件断言的是凭据链路，不是锁屏语义。
      webViewLockProvider.overrideWith(
        (Ref ref) => WebViewLock(
          gate: const AlwaysPassBiometricGate(),
          initial: WebViewLockState.unlocked,
        ),
      ),
      if (cookieSink != null)
        webViewCookieSinkProvider.overrideWithValue(cookieSink),
    ],
  );
  addTearDown(container.dispose);
  await container.read(appSessionProvider).load();

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: WebViewPage(webViewFactory: factory),
      ),
    ),
  );
  // postFrame → prepareAuth（网络往返，可能含重签）→ create。
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 1));
  }
  return (container: container, factory: factory);
}

/// 永不成功的 Cookie sink（用于「票据与 Cookie 双双不可用」的失败场景）。
class _RejectingCookieSink implements WebViewCookieSink {
  int writes = 0;

  @override
  Future<bool> writeSessionCookie({
    required String url,
    required String name,
    required String value,
  }) async {
    writes++;
    return false;
  }

  @override
  Future<void> clearSessionCookies() async {}
}

void main() {
  group('WebViewTicket.isExpiredAt（过期判定，纯函数）', () {
    test('expires_at 已过 → 过期', () {
      const ticket = WebViewTicket(ticket: 'tk', expiresAt: kExpiredAt);
      expect(ticket.isExpiredAt(kNowMs), isTrue);
    });

    test('expires_at 在未来 → 未过期', () {
      const ticket = WebViewTicket(ticket: 'tk', expiresAt: kValidAt);
      expect(ticket.isExpiredAt(kNowMs), isFalse);
    });

    test('expires_at 恰好等于当前时刻 → 视为过期（闭区间，宁可重签）', () {
      // 边界取「已到期即失效」：真机上差 1ms 就可能兑换失败，
      // 与其赌服务端宽容，不如重签一次（成本是一次极短请求）。
      const ticket = WebViewTicket(ticket: 'tk', expiresAt: kNowMs);
      expect(ticket.isExpiredAt(kNowMs), isTrue);
    });

    test('expires_at 缺失 → 不判废（不无依据地把可用链路判死）', () {
      const ticket = WebViewTicket(ticket: 'tk');
      expect(ticket.expiresAt, isNull);
      expect(ticket.isExpiredAt(kNowMs), isFalse);
    });
  });

  group('prepareAuth：过期票 → 自动重签（恢复路径）', () {
    test('首发过期、重签有效 → mode=ticket，URL 只含新票，重签计数=1', () async {
      final (:api, :adapter) = _buildApi(<ResponseBody Function()>[
        // 第 1 次：已过期的票（复现白屏成因）
        () => _ticketResponse('tk-stale', kExpiredAt),
        // 第 2 次（重签）：有效票
        () => _ticketResponse('tk-fresh', kValidAt),
      ]);

      final result = await api.prepareAuth(
        baseUrl: 'http://localhost:8080',
        entryUrl: 'http://localhost:8080/',
        deviceId: 'dev-1',
        nowMsProvider: () => kNowMs,
      );

      // ① 端点被调用了**两次**（首发 + 一次重签）
      expect(adapter.calls, 2);
      // ② 结果可用
      expect(result.mode, WebViewAuthMode.ticket);
      expect(result.ready, isTrue);
      expect(result.ticketRenewCount, 1);
      // ③ 核心否定断言：过期票**绝不**能出现在 URL 里
      expect(result.url.contains('tk-stale'), isFalse);
      expect(result.url, contains('tk-fresh'));
      // ④ 携带的是新票的过期时间
      expect(result.expiresAt, kValidAt);
      // ⑤ URL 依然是 fragment 承载（不进 Referer / access log）
      expect(Uri.parse(result.url).query, isEmpty);
      expect(Uri.parse(result.url).fragment, contains('ticket=tk-fresh'));
    });

    test('过期票 + Cookie 降级可用 → 重签耗尽后走 Cookie，仍不是白屏', () async {
      final (:api, :adapter) = _buildApi(<ResponseBody Function()>[
        () => _ticketResponse('tk-stale-1', kExpiredAt),
        () => _ticketResponse('tk-stale-2', kExpiredAt),
      ], userToken: 'ut_secret');

      final sink = _RecordingSink();
      final result = await api.prepareAuth(
        baseUrl: 'http://localhost:8080',
        entryUrl: 'http://localhost:8080/',
        deviceId: 'dev-1',
        cookieSink: sink,
        nowMsProvider: () => kNowMs,
      );

      // 首发 + 1 次重签 = 2 次，然后放弃并降级
      expect(adapter.calls, 2);
      expect(result.mode, WebViewAuthMode.cookie);
      expect(result.ready, isTrue);
      // 降级 URL 必须是裸入口（不带任何残票）
      expect(result.url, 'http://localhost:8080/');
      expect(result.url.contains('tk-stale'), isFalse);
      expect(sink.writes, 1);
      // 重签确实发生过 1 次（观测用字段）
      expect(result.ticketRenewCount, 1);
    });

    test('重签有预算上限（不会无限重签打爆服务端）', () async {
      final (:api, :adapter) = _buildApi(<ResponseBody Function()>[
        () => _ticketResponse('tk-exp', kExpiredAt),
      ]);

      final result = await api.prepareAuth(
        baseUrl: 'http://localhost:8080',
        entryUrl: 'http://localhost:8080/',
        deviceId: 'dev-1',
        nowMsProvider: () => kNowMs,
      );

      // 首发 1 次 + 重签 maxTicketRenewAttempts 次
      expect(adapter.calls, 1 + api.maxTicketRenewAttempts);
      expect(result.mode, WebViewAuthMode.none);
      expect(result.failure, WebViewAuthFailure.ticketExpired);
    });
  });

  group('prepareAuth：重签失败 → 可读失败原因（不白屏）', () {
    test('过期后重签抛错 + 无 Cookie → none 且 failure=ticketExpired', () async {
      final (:api, :adapter) = _buildApi(<ResponseBody Function()>[
        () => _ticketResponse('tk-stale', kExpiredAt),
        () => _errorResponse(401),
      ]);

      final result = await api.prepareAuth(
        baseUrl: 'http://localhost:8080',
        entryUrl: 'http://localhost:8080/',
        deviceId: 'dev-1',
        nowMsProvider: () => kNowMs,
      );

      expect(result.mode, WebViewAuthMode.none);
      expect(result.ready, isFalse);
      // 这是「过期」而不是「签发失败」：用户能据此判断是重试还是重新登录
      expect(result.failure, WebViewAuthFailure.ticketExpired);
      // 失败文案必须可读、且非空
      expect(result.failureMessage, WebViewAuthFailure.ticketExpired.message);
      expect(result.failureMessage, contains('过期'));
      // 成功路径下绝不能残留失败文案
      expect(
        const WebViewAuthResult(mode: WebViewAuthMode.ticket, url: 'x')
            .failureMessage,
        '',
      );
    });

    test('首发即 404 且无 Cookie → none 且 failure=ticketIssueFailed', () async {
      final (:api, :adapter) = _buildApi(<ResponseBody Function()>[
        () => _errorResponse(404),
      ]);

      final result = await api.prepareAuth(
        baseUrl: 'http://localhost:8080',
        entryUrl: 'http://localhost:8080/',
        deviceId: 'dev-1',
        nowMsProvider: () => kNowMs,
      );

      expect(result.mode, WebViewAuthMode.none);
      expect(result.failure, WebViewAuthFailure.ticketIssueFailed);
      // 不应因「404 无法签发」而白跑一次重签
      expect(adapter.calls, 1);
    });

    test('无 deviceId → failure=noDeviceId（指引回配对页而非含糊失败）', () async {
      final (:api, :adapter) = _buildApi(<ResponseBody Function()>[
        () => _ticketResponse('tk', kValidAt),
      ]);

      final result = await api.prepareAuth(
        baseUrl: 'http://localhost:8080',
        entryUrl: 'http://localhost:8080/',
        deviceId: '',
        nowMsProvider: () => kNowMs,
      );

      expect(result.mode, WebViewAuthMode.none);
      expect(result.failure, WebViewAuthFailure.noDeviceId);
      expect(adapter.calls, 0); // 没身份就不该打端点
    });

    test('Ticket 与 Cookie 双双失败 → 保留**票据根因**而非 Cookie 失败（用户能自救）',
        () async {
      final (:api, :adapter) = _buildApi(<ResponseBody Function()>[
        () => _errorResponse(404),
      ], userToken: 'ut_secret');

      final result = await api.prepareAuth(
        baseUrl: 'http://localhost:8080',
        entryUrl: 'http://localhost:8080/',
        deviceId: 'dev-1',
        cookieSink: _RejectingCookieSink(),
        nowMsProvider: () => kNowMs,
      );

      expect(result.mode, WebViewAuthMode.none);
      // 根因是「票据签发失败」，而不是「Cookie 写不进去」——
      // 后者是备用路径的次生失败，报给用户只会让人无从下手。
      expect(result.failure, WebViewAuthFailure.ticketIssueFailed);
      expect(result.failure, isNot(WebViewAuthFailure.cookieUnavailable));
    });

    test('Cookie 写入被拒且无票据根因 → failure=cookieUnavailable', () async {
      // 无 deviceId 时票据路径不产生「过期/签发失败」，Cookie 是唯一被执行
      // 的路径；它失败时的原因应保留下来 —— 但 noDeviceId 更具体、优先。
      final (:api, :adapter) = _buildApi(<ResponseBody Function()>[
        () => _ticketResponse('tk', kValidAt),
      ], userToken: 'ut_secret');

      final result = await api.prepareAuth(
        baseUrl: 'http://localhost:8080',
        entryUrl: 'http://localhost:8080/',
        deviceId: '',
        cookieSink: _RejectingCookieSink(),
        nowMsProvider: () => kNowMs,
      );

      expect(result.mode, WebViewAuthMode.none);
      // 具体原因优先：缺身份比「Cookie 写不进去」更能指引用户去配对
      expect(result.failure, WebViewAuthFailure.noDeviceId);
    });

    test('四种失败原因全部有非空可读文案（无「哑巴失败」）', () {
      for (final failure in WebViewAuthFailure.values) {
        expect(failure.message.trim(), isNotEmpty, reason: failure.name);
        // 文案必须给出下一步动作，否则用户只能干等
        expect(
          failure.message,
          anyOf(contains('重试'), contains('重新登录'), contains('重新配对')),
          reason: '${failure.name} 的文案缺少可执行的下一步',
        );
      }
    });
  });

  group('WebViewPage：过期票恢复 / 失败提示（绝不白屏）', () {
    testWidgets('过期 → 重签成功 → 页面恢复（首帧 URL 用新票）',
        (WidgetTester tester) async {
      final adapter = _SequencedTicketAdapter(<ResponseBody Function()>[
        () => _ticketResponse('tk-stale', kRealPastExpiry),
        () => _ticketResponse('tk-fresh', kRealFutureExpiry),
      ]);
      final pumped = await _pumpPage(tester, adapter: adapter);

      // ① WebView 真的被创建了（不是错误页）
      expect(adapter.calls, 2); // 首发 1 + 重签 1
      expect(pumped.factory.createCount, 1);
      expect(pumped.factory.initialUrl, isNotNull);
      // ② 首帧 URL 带的是**新票**
      expect(pumped.factory.initialUrl!.fragment, 'ticket=tk-fresh');
      expect(pumped.factory.initialUrl.toString().contains('tk-stale'), isFalse);
      // ③ 没有任何错误 UI
      expect(find.text('重试票据申请'), findsNothing);
      expect(find.textContaining('无法为内置页面获取登录凭据'), findsNothing);
      // ④ 页面主体可见
      expect(find.text('内置页面已恢复'), findsOneWidget);
    });

    testWidgets('过期且重签失败 → 明确错误 UI（可重试按钮 + 可读原因），不是白屏',
        (WidgetTester tester) async {
      // 用「远期」时钟无意义，这里让两次签发都返回过期票 + Cookie 也不可用，
      // 从而把链路逼到最后的 none 分支（真机上就是这个组合导致白屏）。
      final adapter = _SequencedTicketAdapter(<ResponseBody Function()>[
        () => _ticketResponse('tk-stale', kRealPastExpiry),
        () => _ticketResponse('tk-stale-2', kRealPastExpiry),
      ]);
      final pumped = await _pumpPage(
        tester,
        adapter: adapter,
        cookieSink: _RejectingCookieSink(),
      );

      // ① 绝不创建 WebView（fail-closed，不裸地址放行）
      expect(pumped.factory.createCount, 0);
      expect(pumped.factory.initialUrl, isNull);
      // ② 统一抬头 + 具体原因都必须在（用户能读懂为什么进不去）
      expect(find.textContaining('无法为内置页面获取登录凭据'), findsOneWidget);
      expect(
        find.textContaining(WebViewAuthFailure.ticketExpired.message),
        findsOneWidget,
      );
      // ③ 必须有可重试动作
      expect(find.text('重试'), findsOneWidget);
      expect(find.text('重试票据申请'), findsOneWidget);
      // ④ 必须有「回账号页重新登录」出口（凭据类失败的唯一自救路径）
      expect(find.text('回账号页重新登录'), findsOneWidget);
      // ⑤ 否定断言：屏幕上不得只剩空白（Scaffold body 里必须有内容）
      expect(find.byType(Column), findsWidgets);
    });

    testWidgets('点「重试票据申请」后服务端恢复 → 页面自动恢复',
        (WidgetTester tester) async {
      // 序列：过期 → 过期（失败进入错误 UI）→ 用户点重试 → 有效票
      final adapter = _SequencedTicketAdapter(<ResponseBody Function()>[
        () => _ticketResponse('tk-stale-1', kRealPastExpiry),
        () => _ticketResponse('tk-stale-2', kRealPastExpiry),
        () => _ticketResponse('tk-recovered', kRealFutureExpiry),
      ]);
      final pumped = await _pumpPage(
        tester,
        adapter: adapter,
        cookieSink: _RejectingCookieSink(),
      );

      // 前置：确实停在错误 UI
      expect(find.text('重试票据申请'), findsOneWidget);
      expect(pumped.factory.createCount, 0);

      // 用户点「重试票据申请」→ 重新走认证链路
      await tester.tap(find.text('重试票据申请'));
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 1));
      }

      // 恢复：WebView 建起来了，且用的是新票
      expect(pumped.factory.createCount, 1);
      expect(pumped.factory.initialUrl!.fragment, 'ticket=tk-recovered');
      expect(find.text('内置页面已恢复'), findsOneWidget);
      expect(find.text('重试票据申请'), findsNothing);
    });
  });
}

/// 记录型 Cookie sink（成功写入）。
class _RecordingSink implements WebViewCookieSink {
  int writes = 0;

  @override
  Future<bool> writeSessionCookie({
    required String url,
    required String name,
    required String value,
  }) async {
    writes++;
    return true;
  }

  @override
  Future<void> clearSessionCookies() async {}
}
