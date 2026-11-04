import 'dart:io';

/// [offline] marks a device known from chat history that is not reachable
/// right now; sending to it queues until it is seen again.
enum DeviceConnectionMode { direct, paired, remote, offline }

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
  bool get isOffline => connectionMode == DeviceConnectionMode.offline;

  String get routeLabel => switch (connectionMode) {
    DeviceConnectionMode.direct => '局域网直连',
    DeviceConnectionMode.paired => '局域网安全连接',
    DeviceConnectionMode.remote => '公网 VPS 中转',
    DeviceConnectionMode.offline => '离线',
  };

  /// A placeholder for a device that is only known from chat history.
  factory DiscoveredDevice.offline({
    required String deviceId,
    required String displayName,
    required String platform,
    required DateTime lastSeen,
  }) => DiscoveredDevice(
    deviceId: deviceId,
    displayName: displayName,
    platform: platform,
    address: InternetAddress.anyIPv4,
    transferPort: 0,
    lastSeen: lastSeen,
    connectionMode: DeviceConnectionMode.offline,
  );

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
