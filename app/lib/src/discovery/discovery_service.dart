import 'dart:async';
import 'dart:io';

import '../device/device_identity.dart';
import '../network/local_network_service.dart';
import 'discovered_device.dart';
import 'discovery_message.dart';

class DiscoveryService {
  DiscoveryService(
    this._identity, {
    this._networkService = const LocalNetworkService(),
    this._onLog,
  });

  static const discoveryPort = 53317;
  static const transferPort = 53318;
  static const _announceEvery = Duration(seconds: 2);
  static const _offlineAfter = Duration(seconds: 7);

  DeviceIdentity _identity;
  final LocalNetworkService _networkService;
  final void Function(String message)? _onLog;
  RawDatagramSocket? _socket;
  StreamSubscription<RawSocketEvent>? _socketSubscription;
  Timer? _announceTimer;
  Timer? _cleanupTimer;
  bool _disposed = false;
  bool _announcing = false;
  String? _lastNetworkSignature;

  final Map<String, DiscoveredDevice> _devices = {};
  final StreamController<List<DiscoveredDevice>> _devicesController =
      StreamController<List<DiscoveredDevice>>.broadcast();

  Stream<List<DiscoveredDevice>> get devices => _devicesController.stream;

  Future<void> start() async {
    if (_disposed) return;
    await _bindSocket();
    _announceTimer ??= Timer.periodic(
      _announceEvery,
      (_) => unawaited(announce()),
    );
    _cleanupTimer ??= Timer.periodic(
      const Duration(seconds: 1),
      (_) => _removeOfflineDevices(),
    );
    unawaited(announce());
  }

  void updateIdentity(DeviceIdentity identity) {
    _identity = identity;
    unawaited(announce());
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
      _onLog?.call('discovery_socket_started port=$discoveryPort');
    } on SocketException catch (error) {
      _onLog?.call('discovery_socket_bind_failed error=${error.message}');
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

  Future<void> announce() async {
    if (_announcing || _disposed) return;
    final socket = _socket;
    if (socket == null) {
      unawaited(_bindSocket());
      return;
    }

    _announcing = true;
    try {
      final addresses = await _networkService.listAddresses();
      final targets = discoveryBroadcastTargets(addresses);
      final signature = addresses
          .map(
            (item) =>
                '${item.interfaceName}:${item.address}/${item.prefixLength}:${item.resolvedBroadcastAddress}',
          )
          .join(',');
      if (signature != _lastNetworkSignature) {
        _lastNetworkSignature = signature;
        _onLog?.call(
          'discovery_network_changed interfaces=${addresses.length} '
          'targets=${targets.map((target) => target.address).join(',')}',
        );
      }

      final message = DiscoveryMessage(
        deviceId: _identity.deviceId,
        displayName: _identity.displayName,
        platform: _identity.platform,
        transferPort: transferPort,
      );

      final bytes = message.encode();
      var sentAny = false;
      for (final target in targets) {
        try {
          sentAny = socket.send(bytes, target, discoveryPort) > 0 || sentAny;
        } on SocketException catch (error) {
          _onLog?.call(
            'discovery_target_failed target=${target.address} '
            'error=${error.message}',
          );
        }
      }
      if (!sentAny) {
        throw const SocketException('all discovery broadcast targets failed');
      }
    } on SocketException catch (error) {
      _onLog?.call('discovery_announce_failed error=${error.message}');
      unawaited(_restartSocket());
    } catch (error) {
      _onLog?.call('discovery_network_scan_failed error=$error');
    } finally {
      _announcing = false;
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
