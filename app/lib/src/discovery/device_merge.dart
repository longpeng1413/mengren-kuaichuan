import 'discovered_device.dart';

List<DiscoveredDevice> mergeDiscoveredDevices({
  required Iterable<DiscoveredDevice> localDevices,
  required Iterable<DiscoveredDevice> pairedDevices,
  Iterable<DiscoveredDevice> remoteDevices = const [],
}) {
  // Prefer a freshly discovered HTTP endpoint for maximum LAN throughput.
  // Sending still falls back to the paired WebSocket if the direct route is
  // unreachable, which keeps routed and broadcast-filtered networks working.
  final byId = <String, DiscoveredDevice>{
    for (final device in remoteDevices) device.deviceId: device,
    for (final device in pairedDevices) device.deviceId: device,
    for (final device in localDevices) device.deviceId: device,
  };
  return byId.values.toList()..sort(
    (left, right) => left.displayName.toLowerCase().compareTo(
      right.displayName.toLowerCase(),
    ),
  );
}
