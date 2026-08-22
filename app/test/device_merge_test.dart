import 'dart:io';

import 'package:lan_transfer/src/discovery/device_merge.dart';
import 'package:lan_transfer/src/discovery/discovered_device.dart';
import 'package:test/test.dart';

void main() {
  test('paired duplex connection wins over direct discovery', () {
    final now = DateTime.now();
    final direct = DiscoveredDevice(
      deviceId: 'phone012345678901',
      displayName: '测试手机',
      platform: 'android',
      address: InternetAddress('192.168.110.148'),
      transferPort: 53318,
      lastSeen: now,
    );
    final paired = DiscoveredDevice(
      deviceId: direct.deviceId,
      displayName: direct.displayName,
      platform: direct.platform,
      address: InternetAddress('192.168.0.65'),
      transferPort: 53318,
      lastSeen: now,
      connectionMode: DeviceConnectionMode.paired,
    );

    final merged = mergeDiscoveredDevices(
      localDevices: [direct],
      pairedDevices: [paired],
    );

    expect(merged, hasLength(1));
    expect(merged.single.isPaired, isTrue);
  });
}
