import 'dart:io';

import 'package:lan_transfer/src/discovery/device_merge.dart';
import 'package:lan_transfer/src/discovery/discovered_device.dart';
import 'package:test/test.dart';

void main() {
  test('direct discovery wins over paired connection', () {
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
    expect(merged.single.connectionMode, DeviceConnectionMode.direct);
    expect(merged.single.routeLabel, '局域网直连');
  });

  test('local routes win over VPS relay for the same device', () {
    final now = DateTime.now();
    final remote = DiscoveredDevice(
      deviceId: 'phone012345678901',
      displayName: '测试手机',
      platform: 'android',
      address: InternetAddress.loopbackIPv4,
      transferPort: 0,
      lastSeen: now,
      connectionMode: DeviceConnectionMode.remote,
    );
    final direct = DiscoveredDevice(
      deviceId: remote.deviceId,
      displayName: remote.displayName,
      platform: remote.platform,
      address: InternetAddress('192.168.43.2'),
      transferPort: 53318,
      lastSeen: now,
    );

    final merged = mergeDiscoveredDevices(
      localDevices: [direct],
      pairedDevices: const [],
      remoteDevices: [remote],
    );

    expect(merged.single.connectionMode, DeviceConnectionMode.direct);
    expect(merged.single.routeLabel, '局域网直连');
    expect(remote.routeLabel, '公网 VPS 中转');
  });
}
