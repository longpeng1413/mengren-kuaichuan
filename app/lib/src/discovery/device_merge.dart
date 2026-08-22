import 'discovered_device.dart';

List<DiscoveredDevice> mergeDiscoveredDevices({
  required Iterable<DiscoveredDevice> localDevices,
  required Iterable<DiscoveredDevice> pairedDevices,
}) {
  // A paired WebSocket is already proven to be duplex. Prefer it over a UDP
  // discovery result because routed Wi-Fi networks can allow traffic in only
  // one direction even when broadcasts happen to reach both devices.
  final byId = <String, DiscoveredDevice>{
    for (final device in localDevices) device.deviceId: device,
    for (final device in pairedDevices) device.deviceId: device,
  };
  return byId.values.toList()..sort(
    (left, right) => left.displayName.toLowerCase().compareTo(
      right.displayName.toLowerCase(),
    ),
  );
}
