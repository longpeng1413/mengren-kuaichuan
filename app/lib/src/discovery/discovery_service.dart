import 'dart:async';
import 'dart:io';

import '../device/device_identity.dart';
import 'discovered_device.dart';
import 'discovery_message.dart';

class DiscoveryService {
  DiscoveryService(this._identity);

  static const discoveryPort = 53317;
  static const transferPort = 53318;
  static const _announceEvery = Duration(seconds: 2);
  static const _offlineAfter = Duration(seconds: 7);

  DeviceIdentity _identity;
  RawDatagramSocket? _socket;
  StreamSubscription<RawSocketEvent>? _socketSubscription;
  Timer? _announceTimer;
  Timer? _cleanupTimer;
  bool _disposed = false;

  final Map<String, DiscoveredDevice> _devices = {};
  final StreamController<List<DiscoveredDevice>> _devicesController =
      StreamController<List<DiscoveredDevice>>.broadcast();

  Stream<List<DiscoveredDevice>> get devices => _devicesController.stream;

  Future<void> start() async {
    if (_disposed) return;
    await _bindSocket();
    _announceTimer ??= Timer.periodic(_announceEvery, (_) => announce());
    _cleanupTimer ??= Timer.periodic(
      const Duration(seconds: 1),
      (_) => _removeOfflineDevices(),
    );
    announce();
  }

  void updateIdentity(DeviceIdentity identity) {
    _identity = identity;
    announce();
  }

  Future<void> _bindSocket() async {
    if (_socket != null || _disposed) return;

    try {
      final socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        discoveryPort,
        reuseAddress: true,
      );
      socket.broadcastEnabled = true;
      _socket = socket;
      _socketSubscription = socket.listen(
        _handleSocketEvent,
        onError: (_) => _restartSocket(),
        onDone: _restartSocket,
        cancelOnError: false,
      );
    } on SocketException {
      Timer(const Duration(seconds: 2), _bindSocket);
    }
  }

  void _handleSocketEvent(RawSocketEvent event) {
    if (event != RawSocketEvent.read) return;

    Datagram? datagram;
    while ((datagram = _socket?.receive()) != null) {
      final message = DiscoveryMessage.tryDecode(datagram!.data);
      if (message == null || message.deviceId == _identity.deviceId) continue;

      final now = DateTime.now();
      final existing = _devices[message.deviceId];
      _devices[message.deviceId] = existing == null
          ? DiscoveredDevice(
              deviceId: message.deviceId,
              displayName: message.displayName,
              platform: message.platform,
              address: datagram.address,
              transferPort: message.transferPort,
              lastSeen: now,
            )
          : existing.seenAgain(
              displayName: message.displayName,
              platform: message.platform,
              address: datagram.address,
              transferPort: message.transferPort,
              at: now,
            );
      _emitDevices();
    }
  }

  void announce() {
    final socket = _socket;
    if (socket == null) {
      _bindSocket();
      return;
    }

    final message = DiscoveryMessage(
      deviceId: _identity.deviceId,
      displayName: _identity.displayName,
      platform: _identity.platform,
      transferPort: transferPort,
    );

    try {
      socket.send(
        message.encode(),
        InternetAddress('255.255.255.255'),
        discoveryPort,
      );
    } on SocketException {
      _restartSocket();
    }
  }

  void _removeOfflineDevices() {
    final cutoff = DateTime.now().subtract(_offlineAfter);
    final before = _devices.length;
    _devices.removeWhere((_, device) => device.lastSeen.isBefore(cutoff));
    if (_devices.length != before) _emitDevices();
  }

  void _emitDevices() {
    final snapshot = _devices.values.toList()
      ..sort(
        (left, right) => left.displayName.toLowerCase().compareTo(
          right.displayName.toLowerCase(),
        ),
      );
    _devicesController.add(List.unmodifiable(snapshot));
  }

  Future<void> _restartSocket() async {
    await _socketSubscription?.cancel();
    _socketSubscription = null;
    _socket?.close();
    _socket = null;
    if (!_disposed) {
      Timer(const Duration(seconds: 1), _bindSocket);
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    _announceTimer?.cancel();
    _cleanupTimer?.cancel();
    await _socketSubscription?.cancel();
    _socket?.close();
    await _devicesController.close();
  }
}
