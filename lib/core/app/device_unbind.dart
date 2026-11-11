/// 端侧「解除本机绑定」的唯一实现（账号页 / 登录页 / 设置页三个入口共用）。
///
/// ## 为什么必须收敛到一个函数（2026-11 修复的两个真实 bug）
/// 1. **只清本地、不通知服务端**：旧实现三处入口各自 `stop WS → clearAll`，
///    服务端 devices 表里的绑定记录原封不动，管理端「设备列表」里那台设备
///    永远挂着 —— 用户以为解绑了、服务端认为还绑着。
/// 2. **顺序错了就解不了绑**：`POST /api/v1/devices/unpair` 的鉴权凭据就是
///    `device_token`，一旦先 `clearAll()` 把令牌抹掉，再也没法通知服务端
///    （用户令牌还可能早就过期 7 天）。因此 unpair **必须排在清理之前**。
///
/// ## 失败语义（铁律）
/// unpair 失败**绝不阻断**本地解绑：本地凭据一清，用户「这台机器不再绑定我」
/// 的意图就已达成；把它打成失败只会让用户卡在「解绑失败」而不敢继续
/// （本地留着一整套凭据比服务端留一条吊销记录危险得多）。失败只降级为
/// 一句可读提示（「已解除本机绑定，但未能通知服务端」）。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/remote/device_api.dart';
import 'providers.dart';

/// 通知服务端吊销本机的设备绑定。返回**是否成功通知**（绝不抛异常）。
///
/// - [device] 为 null（未配置服务端地址）→ 没有可通知的对象，返回 false；
/// - 本机无 device_token / 网络异常 / 服务端 5xx → 一律 false（由调用方提示）。
///
/// ⚠️ 服务端该端点**幂等**：令牌无效 / 设备不存在 / 已吊销 都回 204，
/// 所以「本来就没绑」不会被误判成失败。
///
/// 刻意不依赖 `WidgetRef`：这样「失败不阻断本地解绑」这条铁律可以在
/// **纯 Dart 单测**里被直接断言（见 `test/core/device_unbind_test.dart`），
/// 不必搭一整棵 widget 树。
Future<bool> notifyServerUnpair(DeviceApi? device) async {
  if (device == null) return false;
  try {
    await device.unpair();
    return true;
  } on Object {
    // 故意吞掉所有异常：解绑的目标状态是「本机不再绑定」，本地清理会兜底。
    return false;
  }
}

/// 完整解绑的**核心流程**（与 UI 无关，可纯单测）：
/// **先**通知服务端（要令牌），**再**按既有顺序清本地。
///
/// 返回 [notifyServerUnpair] 的结果，调用方据此给出诚实提示
/// （`true` → 「已解除本机绑定」；`false` → 「已解除本机绑定，但未能通知服务端」）。
///
/// 🔴 顺序铁律：`localUnbind` **绝不允许**跑在 unpair 之前 —— 它会把
/// `device_token` 一并抹掉，之后再也无法凭令牌通知服务端。
Future<bool> performUnbind({
  required DeviceApi? device,
  required Future<void> Function() localUnbind,
}) async {
  final notified = await notifyServerUnpair(device);
  await localUnbind();
  return notified;
}

/// 主动解绑的本地清理（顺序即语义，勿随意调整）。
///
/// 1. **先停 WS**：device_token 即将被抹掉，继续重连只会持续 401 打满日志；
/// 2. **清 WebView Cookie**：否则内置页面仍带着上一个会话，与原生侧不一致；
/// 3. `resetPairing()`：清 Keychain 全部令牌 + Settings 里的设备身份，
///    相位回 [AppStage.pairing]（`go_router` 的 redirect 会自动落到配对页）；
/// 4. `clearAll()`：兜底抹掉任何残留键。
Future<void> completeLocalUnbind(WidgetRef ref) async {
  final controller = ref.read(deviceWsControllerProvider);
  await controller.stop();
  await ref.read(webViewCookieSinkProvider).clearSessionCookies();
  await ref.read(appSessionProvider).resetPairing();
  await ref.read(secureStoreProvider).clearAll();
  // 主动解绑期间服务端也会推 `device.revoked`，可能触发 WS 控制器的
  // 「服务端已解除本设备绑定」自动收敛文案。用户自己按的按钮，那条
  // 原因文案只会让人困惑（以为被别处踢了），这里消费掉。
  controller.clearRevocationNotice();
}

/// 完整解绑（UI 入口用）：先 `servicesOf(ref).device.unpair()`，再清本地。
Future<bool> unbindThisDevice(WidgetRef ref) => performUnbind(
      device: servicesOf(ref)?.device,
      localUnbind: () => completeLocalUnbind(ref),
    );
