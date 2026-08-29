import 'dart:io';

enum DeviceConnectionMode { direct, paired, remote }

class DiscoveredDevice {
  const DiscoveredDevice({
    required this.deviceId,
    required this.displayName,
    required this.platform,
    required this.address,
    required this.transferPort,
    required this.lastSeen,
    this.connectionMode = DeviceConnectionMode.direct,
  });

  final String deviceId;
  final String displayName;
  final String platform;
  final InternetAddress address;
  final int transferPort;
  final DateTime lastSeen;
  final DeviceConnectionMode connectionMode;

  String get shortId => deviceId.substring(0, 4).toUpperCase();
  bool get isPaired => connectionMode == DeviceConnectionMode.paired;
  bool get isRemote => connectionMode == DeviceConnectionMode.remote;

  String get routeLabel => switch (connectionMode) {
    DeviceConnectionMode.direct => '局域网直连',
    DeviceConnectionMode.paired => '局域网安全连接',
    DeviceConnectionMode.remote => '公网 VPS 中转',
  };

  DiscoveredDevice seenAgain({
    required String displayName,
    required String platform,
    required InternetAddress address,
    required int transferPort,
    required DateTime at,
  }) {
    return DiscoveredDevice(
      deviceId: deviceId,
      displayName: displayName,
      platform: platform,
      address: address,
      transferPort: transferPort,
      lastSeen: at,
      connectionMode: connectionMode,
    );
  }
}
