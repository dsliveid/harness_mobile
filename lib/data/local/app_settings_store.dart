/// 端侧配置存储（服务端地址 + 本机设备身份）。
///
/// 为什么单独一层：`SecureStore` 只承载**令牌**（红线 R3），
/// 而 baseUrl / device_id / 设备名属于「非机密但需跨启动保留」的配置。
/// 二者混在一个抽象里会让「令牌只进 Keychain」的边界变模糊。
///
/// 生产实现仍走 `flutter_secure_storage`（复用同库，避免新增依赖且天然加密），
/// 测试用 [InMemorySettingsStore]。
library;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// 不可变配置快照。
class AppSettings {
  const AppSettings({
    this.baseUrl = '',
    this.deviceId = '',
    this.deviceName = '',
  });

  /// 归一化后的服务端地址（无尾斜杠）。
  final String baseUrl;

  /// 本机配对得到的设备 ID（审批决策 `device_id` 字段来源）。
  final String deviceId;

  /// 本机设备展示名（配对时上报）。
  final String deviceName;

  bool get hasBaseUrl => baseUrl.isNotEmpty;

  bool get hasDevice => deviceId.isNotEmpty;

  AppSettings copyWith({
    String? baseUrl,
    String? deviceId,
    String? deviceName,
  }) =>
      AppSettings(
        baseUrl: baseUrl ?? this.baseUrl,
        deviceId: deviceId ?? this.deviceId,
        deviceName: deviceName ?? this.deviceName,
      );

  @override
  String toString() =>
      'AppSettings(baseUrl=$baseUrl, deviceId=$deviceId, name=$deviceName)';
}

/// 配置存储抽象。
abstract class SettingsStore {
  Future<AppSettings> load();

  Future<void> save(AppSettings settings);

  Future<void> clear();
}

/// 存储键（集中定义）。
abstract final class SettingsKeys {
  static const String baseUrl = 'harness.base_url';
  static const String deviceId = 'harness.device_id';
  static const String deviceName = 'harness.device_name';
}

/// 生产实现（Keychain / EncryptedSharedPreferences）。
class SecureSettingsStore implements SettingsStore {
  SecureSettingsStore({FlutterSecureStorage? storage})
      : _storage = storage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(encryptedSharedPreferences: true),
              iOptions: IOSOptions(
                accessibility: KeychainAccessibility.first_unlock_this_device,
              ),
            );

  final FlutterSecureStorage _storage;

  @override
  Future<AppSettings> load() async {
    final baseUrl = await _storage.read(key: SettingsKeys.baseUrl) ?? '';
    final deviceId = await _storage.read(key: SettingsKeys.deviceId) ?? '';
    final deviceName = await _storage.read(key: SettingsKeys.deviceName) ?? '';
    return AppSettings(
      baseUrl: baseUrl,
      deviceId: deviceId,
      deviceName: deviceName,
    );
  }

  @override
  Future<void> save(AppSettings settings) async {
    await _storage.write(key: SettingsKeys.baseUrl, value: settings.baseUrl);
    await _storage.write(key: SettingsKeys.deviceId, value: settings.deviceId);
    await _storage.write(
      key: SettingsKeys.deviceName,
      value: settings.deviceName,
    );
  }

  @override
  Future<void> clear() async {
    await _storage.delete(key: SettingsKeys.baseUrl);
    await _storage.delete(key: SettingsKeys.deviceId);
    await _storage.delete(key: SettingsKeys.deviceName);
  }
}

/// 内存实现（CI / widget 测试专用，**绝不用于生产**）。
class InMemorySettingsStore implements SettingsStore {
  InMemorySettingsStore([this._value = const AppSettings()]);

  AppSettings _value;

  AppSettings get value => _value;

  @override
  Future<AppSettings> load() async => _value;

  @override
  Future<void> save(AppSettings settings) async {
    _value = settings;
  }

  @override
  Future<void> clear() async {
    _value = const AppSettings();
  }
}
