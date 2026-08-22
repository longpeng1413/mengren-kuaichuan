import 'dart:io';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

class DeviceIdentity {
  const DeviceIdentity({
    required this.deviceId,
    required this.displayName,
    required this.platform,
  });

  final String deviceId;
  final String displayName;
  final String platform;

  String get shortId => deviceId.substring(0, 4).toUpperCase();

  DeviceIdentity copyWith({String? displayName}) {
    return DeviceIdentity(
      deviceId: deviceId,
      displayName: displayName ?? this.displayName,
      platform: platform,
    );
  }
}

class DeviceIdentityStore {
  static const _idKey = 'device_id';
  static const _nameKey = 'device_name';

  Future<DeviceIdentity> loadOrCreate() async {
    final preferences = await SharedPreferences.getInstance();
    final existingId = preferences.getString(_idKey);
    final existingName = preferences.getString(_nameKey);

    final identity = DeviceIdentity(
      deviceId: existingId ?? _createId(),
      displayName: existingName ?? _defaultName(),
      platform: currentPlatformName(),
    );

    if (existingId == null || existingName == null) {
      await save(identity);
    }
    return identity;
  }

  Future<void> save(DeviceIdentity identity) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_idKey, identity.deviceId);
    await preferences.setString(_nameKey, identity.displayName);
  }

  static String _createId() {
    final random = Random.secure();
    return List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  static String _defaultName() {
    if (Platform.isAndroid) return '我的安卓手机';
    if (Platform.isWindows) return '我的 Windows 电脑';
    return '我的设备';
  }
}

String currentPlatformName() {
  if (Platform.isAndroid) return 'android';
  if (Platform.isWindows) return 'windows';
  return Platform.operatingSystem;
}
