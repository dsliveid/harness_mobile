/// 审批中心 UI 红线测试（P5 出口门禁）。
///
/// 覆盖交接书的三条硬约束：
/// 1. **RequiredDeviceID 拦截（红线 R5）**：服务端 403 `approval.device_mismatch`
///    时，端侧**不得**就地放行，必须锁定该行并提示「需在指定设备确认」。
/// 2. **生物识别 fail-closed**：高风险（`command`/`danger`）在闸门拒绝时
///    绝不发决策请求。
/// 3. **幂等**：`approval.already_decided` 不当作错误弹窗，而是提示 + 刷新列表。
///
/// 出网通过替换 dio 的 `HttpClientAdapter` 全量拦截，断言真实请求是否发生。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness_mobile/core/app/api_services.dart';
import 'package:harness_mobile/core/app/biometric_gate.dart';
import 'package:harness_mobile/core/app/providers.dart';
import 'package:harness_mobile/data/local/app_settings_store.dart';
import 'package:harness_mobile/data/local/secure_store.dart';
import 'package:harness_mobile/features/approval/approval_center_page.dart';

/// 拦截适配器：按路径分派响应，并记录全部请求。
class _Adapter implements HttpClientAdapter {
  _Adapter(this.responder);

  final ResponseBody Function(RequestOptions options) responder;
  final List<RequestOptions> captured = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    captured.add(options);
    return responder(options);
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

/// 一个待审批工具的会话（`last_run_status=waiting_approval` 才会被扇出）。
Map<String, dynamic> _sessionJson() => <String, dynamic>{
      'id': 'sess-1',
      'title': '测试会话',
      'workspace_path': '/work',
      'access_mode': 'read_write',
      'model_ref': 'm',
      'user_id': 'u1',
      'message_count': 3,
      'last_message_at': 1700000000000,
      'total_tokens': 10,
      'last_run_status': 'waiting_approval',
      'created_at': 1700000000000,
      'updated_at': 1700000000000,
    };

Map<String, dynamic> _pendingEventJson({String risk = 'command'}) =>
    <String, dynamic>{
      'id': 'evt-1',
      'run_id': 'run-1',
      'tool_name': 'fs.write',
      'namespace': 'fs',
      'args': <String, dynamic>{'path': '/work/a.txt'},
      'status': 'pending',
      'risk': risk,
      'executor': 'device',
      'source_trust': 'untrusted',
      'started_at': 1700000000000,
    };

/// 装配审批中心（注入内存存储 + 假生物识别闸门 + 拦截式 dio）。
///
/// ⚠️ 必须先 `await session.load()`：`AppSession.baseUrl` 初始为空串，
/// 不装配的话 `servicesOf` 会返回 null（页面直接显示「请先配置服务端地址」）。
Future<_Adapter> _pumpApprovalCenter(
  WidgetTester tester, {
  required ResponseBody Function(RequestOptions options) responder,
  BiometricGate gate = const AlwaysPassBiometricGate(),
}) async {
  final adapter = _Adapter(responder);
  final store = InMemorySecureStore();
  await store.setUserToken('user-token');
  await store.setDeviceToken('device-token');

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
      biometricGateProvider.overrideWithValue(gate),
      apiFactoryProvider.overrideWithValue(
        ApiFactory(store: store, dio: Dio()..httpClientAdapter = adapter),
      ),
    ],
  );
  addTearDown(container.dispose);
  await container.read(appSessionProvider).load();

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: ApprovalCenterPage()),
    ),
  );
  await tester.pump(); // postFrameCallback → refresh
  await tester.pump(const Duration(milliseconds: 100));
  return adapter;
}

/// 默认 responder：会话列表 1 条 → active-run 有 → tool-events 有 1 条待审批。
ResponseBody _defaultResponder(RequestOptions options) {
  final path = options.path;
  if (path.contains('/active-run')) {
    return _json(<String, dynamic>{
      'run_id': 'run-1',
      'status': 'waiting_approval',
    });
  }
  if (path.contains('/tool-events')) {
    return _json(<String, dynamic>{'items': <Object>[_pendingEventJson()]});
  }
  if (path.contains('/sessions')) {
    return _json(<String, dynamic>{'items': <Object>[_sessionJson()]});
  }
  return _json(<String, dynamic>{});
}

void main() {
  testWidgets('待审批项渲染：工具名 + 风险标签 + 会话标题', (WidgetTester tester) async {
    await _pumpApprovalCenter(tester, responder: _defaultResponder);

    expect(find.text('fs.fs.write'), findsOneWidget);
    expect(find.text('命令'), findsOneWidget); // RiskChip 的 command 文案
    expect(find.text('会话：测试会话'), findsOneWidget);
    expect(find.text('本次允许'), findsOneWidget);
    expect(find.text('拒绝'), findsOneWidget);
  });

  testWidgets(
    '红线 R5：403 approval.device_mismatch → 锁定该行且不视为已批准',
    (WidgetTester tester) async {
      final adapter = await _pumpApprovalCenter(
        tester,
        responder: (RequestOptions options) {
          if (options.path.contains('/approvals/')) {
            return _json(
              <String, dynamic>{
                'error': <String, dynamic>{
                  'code': 'approval.device_mismatch',
                  'message': '该审批需由指定设备确认',
                },
              },
              status: 403,
            );
          }
          return _defaultResponder(options);
        },
      );

      await tester.tap(find.text('本次允许'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // 决策请求确实发出去了（先请求后才被服务端拒绝）
      expect(
        adapter.captured.any((RequestOptions o) => o.path.contains('/decide')),
        isTrue,
      );
      // 行被锁定：出现指定设备提示，且三个动作按钮全部禁用
      expect(find.text('该审批需在指定设备上确认'), findsWidgets);
      final FilledButton allowOnce =
          tester.widget<FilledButton>(find.widgetWithText(FilledButton, '本次允许'));
      expect(allowOnce.onPressed, isNull, reason: 'R5：本机无权决策，必须禁用');
      final TextButton deny =
          tester.widget<TextButton>(find.widgetWithText(TextButton, '拒绝'));
      expect(deny.onPressed, isNull, reason: 'R5：拒绝同样需在指定设备上操作');
    },
  );

  testWidgets(
    '生物识别 fail-closed：闸门拒绝时不发决策请求',
    (WidgetTester tester) async {
      final adapter = await _pumpApprovalCenter(
        tester,
        gate: const AlwaysDenyBiometricGate(),
        responder: _defaultResponder,
      );

      await tester.tap(find.text('本次允许'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(
        adapter.captured.any((RequestOptions o) => o.path.contains('/decide')),
        isFalse,
        reason: '未通过生物识别绝不能放行高风险操作',
      );
      expect(find.text('未通过生物识别，操作已取消'), findsOneWidget);
    },
  );

  testWidgets(
    '幂等：approval.already_decided → 提示并刷新，不锁行不禁用',
    (WidgetTester tester) async {
      var decidedOnce = false;
      final adapter = await _pumpApprovalCenter(
        tester,
        responder: (RequestOptions options) {
          if (options.path.contains('/approvals/')) {
            decidedOnce = true;
            return _json(
              <String, dynamic>{
                'error': <String, dynamic>{
                  'code': 'approval.already_decided',
                  'message': '该审批已被处理',
                },
              },
              status: 409,
            );
          }
          // 决策之后服务端列表为空（他人已批，本地应刷新掉）
          if (options.path.contains('/sessions') && decidedOnce) {
            return _json(<String, dynamic>{'items': <Object>[]});
          }
          return _defaultResponder(options);
        },
      );

      await tester.tap(find.text('本次允许'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));

      expect(decidedOnce, isTrue);
      // 幂等不锁行（不是 R5 语义）
      expect(find.text('该审批需在指定设备上确认'), findsNothing);
      // 刷新后列表为空 → 展示空态
      expect(find.text('暂无待审批项'), findsOneWidget);
      expect(
        adapter.captured.where((RequestOptions o) => o.path.contains('/sessions')),
        isNotEmpty,
      );
    },
  );

  testWidgets('缓存优先：无待审批项时展示空态而非错误', (WidgetTester tester) async {
    await _pumpApprovalCenter(
      tester,
      responder: (RequestOptions options) =>
          _json(<String, dynamic>{'items': <Object>[]}),
    );
    expect(find.text('暂无待审批项'), findsOneWidget);
  });
}
