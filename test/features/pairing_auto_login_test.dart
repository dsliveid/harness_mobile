/// 「配对后免二次登录」端到端（Widget 级）回归。
///
/// ## 这个文件防的是什么
///
/// 服务端 `POST /api/v1/devices/pair` 在「配对码携带授权用户」上线后，会在
/// 原有四字段之外**并列**下发 `user_token` / `user` / `session_ttl_s` 三兄弟。
/// 端侧必须据此：
/// 1. **三兄弟齐备** → 用户令牌已由 `DeviceApi.pair` 落 Keychain，
///    配对页再 `markSignedIn()`，阶段**直接跳到** `AppStage.webview`，
///    用户不再看到登录页（这是本任务的核心收益）；
/// 2. **三者缺失**（旧服务端 / 历史配对码）→ **合法降级**，阶段停在
///    `AppStage.login`，文案仍是「配对成功，请登录账号」，且配对**必须成功**。
///
/// 断言口径刻意选「阶段 + 用户可见文案」而不是内部字段：
/// 这样日后重写导航实现（换 go / 换 push / 换回调）不会误伤本用例，
/// 而一旦有人把 `markSignedIn()` 删掉、或把降级分支写成强登录，立即红。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_mobile/app.dart';
import 'package:harness_mobile/core/app/api_services.dart';
import 'package:harness_mobile/core/app/app_session.dart';
import 'package:harness_mobile/core/app/providers.dart';
import 'package:harness_mobile/data/local/app_settings_store.dart';
import 'package:harness_mobile/data/local/secure_store.dart';

/// 只应答配对端点的适配器：整个用例只发生这一次出网调用。
///
/// WebView 首屏的 ticket 请求也走同一个 dio，返回体不含 ticket 时
/// 页面会 fail-closed 停在提示态 —— 本文件不关心首屏渲染，只关心阶段。
class _PairAdapter implements HttpClientAdapter {
  _PairAdapter(this.pairBody);

  /// 配对 201 响应体（含或不含三兄弟由各用例自行决定）。
  final Map<String, dynamic> pairBody;

  /// 记录是否真的发出过配对请求（防止用例「假通过」）。
  int pairCalls = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.path.endsWith('/devices/pair')) {
      pairCalls++;
      return _json(pairBody, 201);
    }
    // 其余端点（webview-ticket 等）返回空对象，让首屏自行降级。
    return _json(<String, dynamic>{}, 200);
  }

  ResponseBody _json(Map<String, dynamic> body, int status) =>
      ResponseBody.fromString(
        jsonEncode(body),
        status,
        headers: <String, List<String>>{
          Headers.contentTypeHeader: <String>[Headers.jsonContentType],
        },
      );

  @override
  void close({bool force = false}) {}
}

/// 装配一份「已配置地址、未配对」的 App，并注入只应答配对的 dio。
Future<ProviderContainer> _pumpPairing(
  WidgetTester tester,
  _PairAdapter adapter,
) async {
  final store = InMemorySecureStore();
  final container = ProviderContainer(
    overrides: <Override>[
      secureStoreProvider.overrideWithValue(store),
      settingsStoreProvider.overrideWithValue(
        InMemorySettingsStore(
          const AppSettings(baseUrl: 'http://localhost:8080'),
        ),
      ),
      apiFactoryProvider.overrideWithValue(
        ApiFactory(store: store, dio: Dio()..httpClientAdapter = adapter),
      ),
    ],
  );
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const HarnessMobileApp(),
    ),
  );
  // 首帧 + postFrameCallback(load) + redirect 重算
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  return container;
}

/// 填配对码并点「完成配对」，等异步配对 + 阶段重算落地。
Future<void> _submitPairing(WidgetTester tester) async {
  await tester.enterText(find.byType(TextFormField).first, 'AB12-CD34');
  await tester.pump();
  await tester.tap(find.text('完成配对'));
  // 配对是 async（网络往返 → 写 Keychain → notifyListeners → redirect），
  // 固定次数 pump 比 pumpAndSettle 稳定（首屏还在拉 ticket，settle 可能不收敛）。
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

void main() {
  group('配对响应携带 user_token → 免登录直接进首屏', () {
    testWidgets('stage 直接为 webview，文案为「配对成功，已自动登录」',
        (WidgetTester tester) async {
      final adapter = _PairAdapter(<String, dynamic>{
        'device_id': 'dev_1',
        'device_token': 'dt_secret',
        'ws_path': '/api/v1/devices/ws',
        'protocol_version': 1,
        'user_token': 'hgt_secret',
        'user': <String, dynamic>{
          'id': 'u1',
          'username': 'alice',
          'display_name': '爱丽丝',
          'role': 'owner',
        },
        'session_ttl_s': 604800,
      });
      final container = await _pumpPairing(tester, adapter);
      expect(container.read(appSessionProvider).stage, AppStage.pairing);

      await _submitPairing(tester);

      final session = container.read(appSessionProvider);
      // 核心断言：不经过 login，直接 webview
      expect(session.stage, AppStage.webview);
      expect(session.paired, isTrue);
      expect(session.signedIn, isTrue);
      expect(session.deviceId, 'dev_1');
      // markPaired 必须仍然生效（阶段门禁依赖设备身份）
      expect(session.deviceName, isNotEmpty);
      expect(adapter.pairCalls, 1);
      // 用户可见文案：明确告知已自动登录
      // （SnackBar 进出场动画期间同文案会有两个 Text 实例，故用 findsWidgets）
      expect(find.text('配对成功，已自动登录'), findsWidgets);
      expect(find.text('登录账号'), findsNothing);
    });
  });

  group('配对响应不含 user_token → 合法降级', () {
    testWidgets('stage 为 login，文案为「配对成功，请登录账号」，配对不失败',
        (WidgetTester tester) async {
      final adapter = _PairAdapter(<String, dynamic>{
        'device_id': 'dev_2',
        'device_token': 'dt_secret',
        'ws_path': '/api/v1/devices/ws',
        'protocol_version': 1,
      });
      final container = await _pumpPairing(tester, adapter);

      await _submitPairing(tester);

      final session = container.read(appSessionProvider);
      // 降级正确：配对成功但未登录
      expect(session.stage, AppStage.login);
      expect(session.paired, isTrue);
      expect(session.signedIn, isFalse);
      expect(session.deviceId, 'dev_2');
      expect(adapter.pairCalls, 1);
      // 不得出现任何错误态（降级不是失败）
      // （SnackBar 动画期间同文案会有两个 Text 实例，故用 findsWidgets）
      expect(find.text('配对成功，请登录账号'), findsWidgets);
    });
  });
}
