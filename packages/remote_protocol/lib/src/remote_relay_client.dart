import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'encrypted_remote_envelope.dart';

enum RemoteRelayStatus { disconnected, connecting, connected }

class RemotePeer {
  const RemotePeer({
    required this.deviceId,
    required this.displayName,
    required this.platform,
  });

  final String deviceId;
  final String displayName;
  final String platform;

  static RemotePeer? tryFromJson(Object? value) {
    if (value is! Map<String, dynamic>) return null;
    final deviceId = value['deviceId'];
    final displayName = value['displayName'];
    final platform = value['platform'];
    if (deviceId is! String ||
        deviceId.length < 8 ||
        deviceId.length > 128 ||
        displayName is! String ||
        displayName.trim().isEmpty ||
        displayName.length > 80 ||
        (platform != 'android' && platform != 'windows')) {
      return null;
    }
    return RemotePeer(
      deviceId: deviceId,
      displayName: displayName.trim(),
      platform: platform as String,
    );
  }
}

class RemoteRelayException implements Exception {
  const RemoteRelayException(this.code);

  final String code;

  @override
  String toString() => 'RemoteRelayException($code)';
}

class RemoteRelayClient {
  RemoteRelayClient({this.ackTimeout = defaultAckTimeout});

  // A file sender can keep multiple encrypted chunks in flight. On a slow or
  // lossy long-haul connection the final chunk in that window may legitimately
  // take tens of seconds to reach the receiving app and return its receipt.
  static const defaultAckTimeout = Duration(seconds: 90);

  final Duration ackTimeout;
  final Map<String, RemotePeer> _peers = {};
  final Map<String, Completer<void>> _pendingDeliveries = {};
  final StreamController<RemoteRelayStatus> _statusController =
      StreamController<RemoteRelayStatus>.broadcast();
  final StreamController<List<RemotePeer>> _peersController =
      StreamController<List<RemotePeer>>.broadcast();
  final StreamController<EncryptedRemoteEnvelope> _envelopesController =
      StreamController<EncryptedRemoteEnvelope>.broadcast();
  final StreamController<RemoteRelayException> _errorsController =
      StreamController<RemoteRelayException>.broadcast();

  WebSocket? _socket;
  RemoteRelayStatus _status = RemoteRelayStatus.disconnected;
  String? _deviceId;
  Completer<void>? _helloAck;
  bool _disposed = false;
  int _connectionGeneration = 0;

  RemoteRelayStatus get status => _status;
  List<RemotePeer> get peers => List.unmodifiable(_peers.values);
  Stream<RemoteRelayStatus> get statuses => _statusController.stream;
  Stream<List<RemotePeer>> get peerUpdates => _peersController.stream;
  Stream<EncryptedRemoteEnvelope> get envelopes => _envelopesController.stream;
  Stream<RemoteRelayException> get errors => _errorsController.stream;

  Future<void> connect({
    required Uri relayUri,
    required String accessToken,
    required String deviceId,
    required String displayName,
    required String platform,
  }) async {
    if (_disposed) throw const RemoteRelayException('client_disposed');
    if (_status != RemoteRelayStatus.disconnected) {
      throw const RemoteRelayException('already_connected');
    }
    if ((relayUri.scheme != 'ws' && relayUri.scheme != 'wss') ||
        relayUri.host.isEmpty) {
      throw const FormatException('relay URL must use ws:// or wss://');
    }
    if (accessToken.length < 24) {
      throw const FormatException(
        'relay access token must have 24+ characters',
      );
    }
    if (deviceId.length < 8 ||
        deviceId.length > 128 ||
        displayName.trim().isEmpty ||
        displayName.length > 80 ||
        (platform != 'android' && platform != 'windows')) {
      throw const FormatException('invalid remote device identity');
    }

    _setStatus(RemoteRelayStatus.connecting);
    final generation = ++_connectionGeneration;
    _deviceId = deviceId;
    final helloAck = Completer<void>();
    _helloAck = helloAck;
    WebSocket? connectingSocket;
    try {
      final socket = await WebSocket.connect(
        relayUri.toString(),
        headers: {HttpHeaders.authorizationHeader: 'Bearer $accessToken'},
      );
      connectingSocket = socket;
      if (generation != _connectionGeneration ||
          _status != RemoteRelayStatus.connecting) {
        await socket.close(WebSocketStatus.normalClosure);
        throw const RemoteRelayException('connection_cancelled');
      }
      socket.pingInterval = const Duration(seconds: 30);
      _socket = socket;
      socket.listen(
        _handleEvent,
        onDone: () => _handleDisconnect(socket, 'connection_closed'),
        onError: (_) => _handleDisconnect(socket, 'connection_error'),
        cancelOnError: false,
      );
      socket.add(
        jsonEncode({
          'type': 'hello',
          'protocol': EncryptedRemoteEnvelope.protocolVersion,
          'deviceId': deviceId,
          'displayName': displayName.trim(),
          'platform': platform,
        }),
      );
      await helloAck.future.timeout(const Duration(seconds: 10));
      if (generation != _connectionGeneration) {
        throw const RemoteRelayException('connection_cancelled');
      }
      _setStatus(RemoteRelayStatus.connected);
    } on Object {
      await connectingSocket?.close();
      if (generation == _connectionGeneration) {
        _socket = null;
        _helloAck = null;
        _setStatus(RemoteRelayStatus.disconnected);
      }
      rethrow;
    }
  }

  Future<void> sendEnvelope(EncryptedRemoteEnvelope envelope) async {
    final socket = _socket;
    if (_status != RemoteRelayStatus.connected || socket == null) {
      throw const RemoteRelayException('not_connected');
    }
    if (envelope.senderId != _deviceId) {
      throw const RemoteRelayException('sender_mismatch');
    }
    if (_pendingDeliveries.containsKey(envelope.messageId)) {
      throw const RemoteRelayException('duplicate_message_id');
    }
    final delivery = Completer<void>();
    _pendingDeliveries[envelope.messageId] = delivery;
    socket.add(jsonEncode({'type': 'relay', 'envelope': envelope.toJson()}));
    try {
      await delivery.future.timeout(
        ackTimeout,
        onTimeout: () => throw const RemoteRelayException('delivery_timeout'),
      );
    } finally {
      _pendingDeliveries.remove(envelope.messageId);
    }
  }

  Future<void> acknowledgeEnvelope(
    String messageId, {
    String? failureCode,
  }) async {
    final socket = _socket;
    if (_status != RemoteRelayStatus.connected || socket == null) {
      throw const RemoteRelayException('not_connected');
    }
    if (!RegExp(r'^[a-f0-9]{32}$').hasMatch(messageId)) {
      throw const FormatException('invalid remote message id');
    }
    if (failureCode != null &&
        failureCode != 'decrypt_failed' &&
        failureCode != 'processing_failed') {
      throw const FormatException('invalid delivery failure code');
    }
    socket.add(
      jsonEncode({
        'type': 'receipt',
        'messageId': messageId,
        'status': failureCode == null ? 'delivered' : 'rejected',
        if (failureCode != null) 'code': failureCode,
      }),
    );
  }

  void _handleEvent(Object? event) {
    if (event is! String) return;
    Object? decoded;
    try {
      decoded = jsonDecode(event);
    } on FormatException {
      _publishError(const RemoteRelayException('invalid_server_json'));
      return;
    }
    if (decoded is! Map<String, dynamic>) return;
    switch (decoded['type']) {
      case 'helloAck':
        if (decoded['protocol'] != EncryptedRemoteEnvelope.protocolVersion) {
          _helloAck?.completeError(
            const RemoteRelayException('protocol_mismatch'),
          );
          return;
        }
        _peers.clear();
        final peers = decoded['peers'];
        if (peers is List) {
          for (final value in peers) {
            final peer = RemotePeer.tryFromJson(value);
            if (peer != null && peer.deviceId != _deviceId) {
              _peers[peer.deviceId] = peer;
            }
          }
        }
        _publishPeers();
        final helloAck = _helloAck;
        if (helloAck != null && !helloAck.isCompleted) helloAck.complete();
      case 'peerOnline':
        final peer = RemotePeer.tryFromJson(decoded['peer']);
        if (peer != null && peer.deviceId != _deviceId) {
          _peers[peer.deviceId] = peer;
          _publishPeers();
        }
      case 'peerOffline':
        final peer = RemotePeer.tryFromJson(decoded['peer']);
        if (peer != null && _peers.remove(peer.deviceId) != null) {
          _publishPeers();
        }
      case 'relay':
        final envelope = EncryptedRemoteEnvelope.tryFromJson(
          decoded['envelope'],
        );
        if (envelope != null && envelope.recipientId == _deviceId) {
          _envelopesController.add(envelope);
        } else {
          _publishError(const RemoteRelayException('invalid_envelope'));
        }
      case 'relayed':
        // This only confirms that the VPS accepted the envelope. The sender
        // remains pending until the receiving app reports successful handling.
        return;
      case 'delivered':
        final messageId = decoded['messageId'];
        final pending = messageId is String
            ? _pendingDeliveries[messageId]
            : null;
        if (pending != null && !pending.isCompleted) pending.complete();
      case 'error':
        final code = decoded['code'];
        final error = RemoteRelayException(
          code is String ? code : 'unknown_server_error',
        );
        final messageId = decoded['messageId'];
        final pending = messageId is String
            ? _pendingDeliveries[messageId]
            : null;
        if (pending != null && !pending.isCompleted) {
          pending.completeError(error);
        } else {
          _publishError(error);
        }
    }
  }

  void _handleDisconnect(WebSocket source, String code) {
    if (!identical(_socket, source)) return;
    _socket = null;
    _clearConnection(code);
  }

  void _clearConnection(String code) {
    final helloAck = _helloAck;
    if (helloAck != null && !helloAck.isCompleted) {
      helloAck.completeError(RemoteRelayException(code));
    }
    _helloAck = null;
    _peers.clear();
    _publishPeers();
    for (final pending in _pendingDeliveries.values) {
      if (!pending.isCompleted) {
        pending.completeError(RemoteRelayException(code));
      }
    }
    _pendingDeliveries.clear();
    _setStatus(RemoteRelayStatus.disconnected);
  }

  void _publishPeers() {
    if (!_peersController.isClosed) {
      _peersController.add(List.unmodifiable(_peers.values));
    }
  }

  void _publishError(RemoteRelayException error) {
    if (!_errorsController.isClosed) _errorsController.add(error);
  }

  void _setStatus(RemoteRelayStatus status) {
    if (_status == status) return;
    _status = status;
    if (!_statusController.isClosed) _statusController.add(status);
  }

  Future<void> disconnect() async {
    _connectionGeneration += 1;
    final socket = _socket;
    _socket = null;
    await socket?.close(WebSocketStatus.normalClosure);
    _clearConnection('disconnected');
  }

  Future<void> dispose() async {
    if (_disposed) return;
    await disconnect();
    _disposed = true;
    await Future.wait([
      _statusController.close(),
      _peersController.close(),
      _envelopesController.close(),
      _errorsController.close(),
    ]);
  }
}
