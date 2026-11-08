/// 生物识别闸门（审批红线：高风险动作需二次确认）。
///
/// 抽成接口的理由：`local_auth` 是平台插件，widget 测试里无法真实弹窗；
/// 审批中心的「高风险必须过生物识别」逻辑必须能在无设备环境下被断言。
library;

import 'package:local_auth/local_auth.dart';

/// 生物识别闸门。
abstract class BiometricGate {
  /// 返回 true 表示已通过校验。
  ///
  /// **fail-closed**：设备不支持 / 用户取消 / 插件异常一律返回 false，
  /// 绝不因为「拿不到结果」就默认放行高风险操作。
  Future<bool> authenticate({required String reason});
}

/// 生产实现（Face ID / Touch ID / 指纹 / 设备凭据）。
class LocalAuthBiometricGate implements BiometricGate {
  LocalAuthBiometricGate({LocalAuthentication? auth})
      : _auth = auth ?? LocalAuthentication();

  final LocalAuthentication _auth;

  @override
  Future<bool> authenticate({required String reason}) async {
    try {
      if (!await _auth.isDeviceSupported()) return false;
      return await _auth.authenticate(
        localizedReason: reason,
        options: const AuthenticationOptions(stickyAuth: true),
      );
    } on Object {
      // MissingPluginException / PlatformException / 用户取消 → 一律拒绝
      return false;
    }
  }
}

/// 无生物识别能力的替代闸门（仅供测试与 CI 注入，**不得**用于生产默认值）。
class AlwaysPassBiometricGate implements BiometricGate {
  const AlwaysPassBiometricGate();

  @override
  Future<bool> authenticate({required String reason}) async => true;
}

/// 恒定拒绝的闸门（用于验证 fail-closed 分支）。
class AlwaysDenyBiometricGate implements BiometricGate {
  const AlwaysDenyBiometricGate();

  @override
  Future<bool> authenticate({required String reason}) async => false;
}
