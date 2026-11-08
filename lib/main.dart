/// 应用入口。
///
/// 启动顺序（架构文档 §5.1 状态机）：
/// 1. [AppSession.load] 读取安全存储中的 `device_token` / `user_token` 与 baseUrl
/// 2. 无地址 → 设置页；有地址无设备 → 配对页；已配对未登录 → 登录页；
///    二者齐全 → **审批中心（首屏铁律）**
///
/// ⚠️ 必须包 [ProviderScope]：`HarnessMobileApp` 是 ConsumerStatefulWidget，
/// 所有依赖（SecureStore / SettingsStore / ApiFactory / AppSession）都走 Riverpod。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';

/// App 版本号（供 WebView JS 桥与调试信息使用）。
///
/// 刻意不做成可变量：版本号来自 pubspec 的 `version:` 字段，
/// 运行期不应被修改。Flutter 提供 `package_info_plus` 才能读真实构建版本，
/// 但那需要额外原生插件；自用场景下用编译期常量已足够，
/// 且能避免在无插件环境下抛异常。
const String kAppVersion = '0.1.0';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  if (kDebugMode) {
    // 仅调试期打印，且不含任何凭据（红线 R3）
    debugPrint('[harness] starting v$kAppVersion (debug)');
  }
  runApp(const ProviderScope(child: HarnessMobileApp()));
}
