/// 会话登出语义测试（2026-11 修正：signOut 只清 user_token）。
///
/// 为什么需要这个文件：`signOut()` 曾经调用 `SecureStore.clearAll()`，
/// 会把 `device_token` 一并抹掉，而 [AppSession.paired] 只读 `_deviceId`
/// （Settings 里的非机密字段），于是产生「UI 说已配对、Keychain 里没有令牌」
/// 的不一致死局。服务端**没有任何端点**能重新下发 `device_token`
/// （只有消费新配对码的 `POST /api/v1/devices/pair`），用户登出一次就必须
/// 回桌面端重新生成配对码 —— 这与 `signOut()` 文档承诺完全相反。
///
/// 同时这是设备长连接（`/api/v1/devices/ws`）的前提：WS 只认 device_token
/// （服务端 `device_handler.go` 明确「端侧没有用户账号」），
/// 若登出即清 device_token，长连接必然在登出后永久失联且无法恢复。
///
/// 本文件用**断言**把守这条语义，防止后人「顺手」改回 clearAll()。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:harness_mobile/core/app/app_session.dart';
import 'package:harness_mobile/data/local/app_settings_store.dart';
import 'package:harness_mobile/data/local/secure_store.dart';

/// 构造一个「已配对的设备」：设备令牌 + 用户令牌 + Settings 里的设备身份。
Future<(AppSession, InMemorySecureStore)> _signedInSession() async {
  final store = InMemorySecureStore();
  await store.setDeviceToken('device-token-abc');
  await store.setUserToken('user-token-xyz');

  final settings = InMemorySettingsStore(
    const AppSettings(
      baseUrl: 'http://localhost:8080',
      deviceId: 'dev-1',
      deviceName: '测试机',
    ),
  );

  final session = AppSession(settings: settings, tokens: store);
  await session.load();
  return (session, store);
}

void main() {
  group('signOut：只清用户令牌，保留设备令牌', () {
    test('登出后 user_token 消失、device_token 仍在（核心断言）', () async {
      final (session, store) = await _signedInSession();
      expect(await store.hasUserToken(), isTrue);
      expect(await store.getDeviceToken(), 'device-token-abc');

      await session.signOut();

      // ★ 用户令牌必须被清除
      expect(await store.getUserToken(), isNull);
      expect(await store.hasUserToken(), isFalse);
      // ★ 设备令牌必须被**保留** —— 这一行是本文件的全部意义
      expect(await store.getDeviceToken(), 'device-token-abc');
    });

    test('登出后阶段回落到 login，但仍是「已配对」', () async {
      final (session, _) = await _signedInSession();
      expect(session.stage, AppStage.webview);

      await session.signOut();

      expect(session.signedIn, isFalse);
      // 配对（设备被授权接入）与登录（这个人是谁）正交：登出不动配对
      expect(session.paired, isTrue);
      expect(session.stage, AppStage.login);
    });

    test('登出后重新登录可恢复（无需重新配对）', () async {
      final (session, store) = await _signedInSession();
      await session.signOut();
      expect(session.stage, AppStage.login);

      // 模拟重新登录：AuthApi 只写 user_token，然后 markSignedIn
      await store.setUserToken('user-token-new');
      await session.markSignedIn();

      // 关键：设备身份全程未变，未要求重新配对
      expect(session.deviceId, 'dev-1');
      expect(await store.getDeviceToken(), 'device-token-abc');
      expect(session.stage, AppStage.webview);
    });

    test('登出不调 clearAll（用 clearedCount 反向断言）', () async {
      final (session, store) = await _signedInSession();

      await session.signOut();

      // clearAll 会把 device_token 一起清掉并自增计数；登出路径绝不能碰它。
      expect(store.clearedCount, 0);
      expect(store.keys, equals({SecureKeys.deviceToken}));
    });
  });

  group('resetPairing：解绑必须清空全部（与登出形成对照）', () {
    test('解绑后设备令牌与用户令牌都消失，阶段回到 pairing', () async {
      final (session, store) = await _signedInSession();

      await session.resetPairing();

      expect(await store.getDeviceToken(), isNull);
      expect(await store.getUserToken(), isNull);
      expect(session.paired, isFalse);
      expect(session.stage, AppStage.pairing);
      // 明确：解绑走 clearAll，与登出路径的「只删 user_token」正相反
      expect(store.clearedCount, 1);
    });
  });
}
