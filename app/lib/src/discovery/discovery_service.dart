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
  Timer? _bindRetryTimer;
  bool _disposed = false;
  bool _paused = false;
  bool _announcing = false;
  bool _restartingSocket = false;
  String? _lastNetworkSignature;

  final Map<String, DiscoveredDevice> _devices = {};
  final StreamController<List<DiscoveredDevice>> _devicesController =
      StreamController<List<DiscoveredDevice>>.broadcast();

  Stream<List<DiscoveredDevice>> get devices => _devicesController.stream;

  Future<void> start() async {
    if (_disposed) return;
    _paused = false;
    await _bindSocket();
    _startTimers();
    unawaited(announce());
  }

  /// Releases Android UDP work while the app is in the background. Android
  /// drops the multicast lock at that point, so continuing to broadcast can
  /// otherwise cause an endless socket-restart loop.
  Future<void> pause() async {
    if (_disposed || _paused) return;
    _paused = true;
    _announceTimer?.cancel();
    _announceTimer = null;
    _cleanupTimer?.cancel();
    _cleanupTimer = null;
    _bindRetryTimer?.cancel();
    _bindRetryTimer = null;
    await _closeSocket();
  }

  Future<void> resume() => start();

  bool get _isActive => !_disposed && !_paused;

  void _startTimers() {
    if (!_isActive) return;
    _announceTimer ??= Timer.periodic(
      _announceEvery,
      (_) => unawaited(announce()),
    );
    _cleanupTimer ??= Timer.periodic(
      const Duration(seconds: 1),
      (_) => _removeOfflineDevices(),
    );
  }

  void updateIdentity(DeviceIdentity identity) {
    _identity = identity;
    if (_isActive) unawaited(announce());
  }

  Future<void> _bindSocket() async {
    if (_socket != null || !_isActive) return;

    try {
      final socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        discoveryPort,
        reuseAddress: true,
      );
      if (!_isActive) {
        socket.close();
        return;
      }
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
      _scheduleBindRetry(const Duration(seconds: 2));
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
    if (_announcing || !_isActive) return;
    final socket = _socket;
    if (socket == null) {
      unawaited(_bindSocket());
      return;
    }

    _announcing = true;
    try {
      final addresses = await _networkService.listAddresses();
      if (!_isActive || !identical(socket, _socket)) return;
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
        // A broadcast can be rejected while a phone switches networks or is
        // backgrounded. That does not mean the bound UDP socket is broken;
        // repeatedly tearing it down here previously created one restart per
        // second and could leave Android unresponsive when it returned.
        _onLog?.call('discovery_announce_skipped reason=no_broadcast_target');
      }
    } on SocketException catch (error) {
      _onLog?.call('discovery_announce_failed error=${error.message}');
    } catch (error) {
      _onLog?.call('discovery_network_scan_failed error=$error');
    } finally {
      _announcing = false;
    }
  }

  void _removeOfflineDevices() {
    if (!_isActive) return;
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
    if (!_isActive || _restartingSocket) return;
    _restartingSocket = true;
    try {
      await _closeSocket();
      _scheduleBindRetry(const Duration(seconds: 2));
    } finally {
      _restartingSocket = false;
    }
  }

  Future<void> _closeSocket() async {
    final subscription = _socketSubscription;
    _socketSubscription = null;
    final socket = _socket;
    _socket = null;
    await subscription?.cancel();
    socket?.close();
  }

  void _scheduleBindRetry(Duration delay) {
    if (!_isActive || _bindRetryTimer?.isActive == true) return;
    _bindRetryTimer = Timer(delay, () {
      _bindRetryTimer = null;
      unawaited(_bindSocket());
    });
  }

  Future<void> dispose() async {
    _disposed = true;
    _announceTimer?.cancel();
    _cleanupTimer?.cancel();
    _bindRetryTimer?.cancel();
    await _closeSocket();
    await _devicesController.close();
  }
}
