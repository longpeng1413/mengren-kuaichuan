import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mengren_remote_protocol/remote_protocol.dart';

class RelayServer {
  RelayServer({
    required this.accessToken,
    this.deliveryTimeout = const Duration(seconds: 30),
    this.onLog,
  });

  static const protocolVersion = EncryptedRemoteEnvelope.protocolVersion;
  static const maximumWireMessageBytes = 768 * 1024;

  final String accessToken;
  final Duration deliveryTimeout;
  final void Function(String message)? onLog;
  final Map<String, _RelayClient> _clients = {};
  final Map<String, _PendingRelay> _pendingRelays = {};
  HttpServer? _server;

  int? get port => _server?.port;
  int get onlineCount => _clients.length;

  Future<void> start({InternetAddress? address, int port = 8080}) async {
    if (_server != null) return;
    if (accessToken.length < 24) {
      throw const FormatException(
        'relay access token must have 24+ characters',
      );
    }
    final server = await HttpServer.bind(
      address ?? InternetAddress.loopbackIPv4,
      port,
    );
    _server = server;
    server.listen(_handleRequest);
  }

  Future<void> _handleRequest(HttpRequest request) async {
    if (request.uri.path == '/healthz') {
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({'ok': true, 'online': onlineCount}));
      await request.response.close();
      return;
    }
    if (request.uri.path != '/v1/relay') {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }
    if (request.headers.value(HttpHeaders.authorizationHeader) !=
        'Bearer $accessToken') {
      request.response.statusCode = HttpStatus.unauthorized;
      await request.response.close();
      return;
    }
    if (!WebSocketTransformer.isUpgradeRequest(request)) {
      request.response.statusCode = HttpStatus.upgradeRequired;
      await request.response.close();
      return;
    }
    final socket = await WebSocketTransformer.upgrade(
      request,
      compression: CompressionOptions.compressionOff,
    );
    _acceptSocket(socket);
  }

  void _acceptSocket(WebSocket socket) {
    _RelayClient? client;
    Timer? helloTimer = Timer(const Duration(seconds: 10), () {
      if (client == null) socket.close(WebSocketStatus.policyViolation);
    });
    socket.listen(
      (event) {
        if (event is! String || event.length > maximumWireMessageBytes) {
          socket.close(WebSocketStatus.messageTooBig);
          return;
        }
        Object? decoded;
        try {
          decoded = jsonDecode(event);
        } on FormatException {
          _sendError(socket, 'invalid_json');
          return;
        }
        if (decoded is! Map<String, dynamic>) {
          _sendError(socket, 'invalid_message');
          return;
        }
        if (client == null) {
          client = _register(socket, decoded);
          if (client != null) {
            helloTimer?.cancel();
            helloTimer = null;
          }
          return;
        }
        _handleClientMessage(client!, decoded);
      },
      onDone: () {
        helloTimer?.cancel();
        final registered = client;
        if (registered != null &&
            identical(_clients[registered.deviceId], registered)) {
          _clients.remove(registered.deviceId);
          _broadcastPeerState(registered, online: false);
          _handleClientOffline(registered.deviceId);
          _log('offline device=${_shortId(registered.deviceId)}');
        }
      },
      onError: (_) {},
      cancelOnError: false,
    );
  }

  _RelayClient? _register(WebSocket socket, Map<String, dynamic> message) {
    final deviceId = message['deviceId'];
    final displayName = message['displayName'];
    final platform = message['platform'];
    if (message['type'] != 'hello' ||
        message['protocol'] != protocolVersion ||
        !_validDeviceId(deviceId) ||
        displayName is! String ||
        displayName.trim().isEmpty ||
        displayName.length > 80 ||
        (platform != 'android' && platform != 'windows')) {
      _sendError(socket, 'invalid_hello');
      socket.close(WebSocketStatus.policyViolation);
      return null;
    }
    final client = _RelayClient(
      deviceId: deviceId as String,
      displayName: displayName.trim(),
      platform: platform as String,
      socket: socket,
    );
    final previous = _clients[client.deviceId];
    _clients[client.deviceId] = client;
    previous?.socket.close(WebSocketStatus.normalClosure, 'replaced');
    socket.add(
      jsonEncode({
        'type': 'helloAck',
        'protocol': protocolVersion,
        'peers': _clients.values
            .where((peer) => peer.deviceId != client.deviceId)
            .map((peer) => peer.publicJson)
            .toList(),
      }),
    );
    _broadcastPeerState(client, online: true);
    _log('online device=${_shortId(client.deviceId)} count=$onlineCount');
    return client;
  }

  void _handleClientMessage(_RelayClient sender, Map<String, dynamic> message) {
    switch (message['type']) {
      case 'relay':
        _handleRelay(sender, message);
      case 'receipt':
        _handleReceipt(sender, message);
      default:
        _sendError(sender.socket, 'unsupported_message');
    }
  }

  void _handleRelay(_RelayClient sender, Map<String, dynamic> message) {
    final envelope = EncryptedRemoteEnvelope.tryFromJson(message['envelope']);
    if (envelope == null || envelope.senderId != sender.deviceId) {
      _sendError(sender.socket, 'invalid_envelope');
      return;
    }
    if (_pendingRelays.containsKey(envelope.messageId)) {
      _sendError(
        sender.socket,
        'duplicate_message_id',
        messageId: envelope.messageId,
      );
      return;
    }
    final recipient = _clients[envelope.recipientId];
    if (recipient == null) {
      _sendError(
        sender.socket,
        'recipient_offline',
        messageId: envelope.messageId,
      );
      return;
    }
    late final _PendingRelay pending;
    final timer = Timer(deliveryTimeout, () {
      final current = _pendingRelays.remove(envelope.messageId);
      if (!identical(current, pending)) return;
      final onlineSender = _clients[envelope.senderId];
      if (onlineSender != null) {
        _sendError(
          onlineSender.socket,
          'delivery_timeout',
          messageId: envelope.messageId,
        );
      }
      _log('timeout message=${_shortId(envelope.messageId)}');
    });
    pending = _PendingRelay(
      messageId: envelope.messageId,
      senderId: envelope.senderId,
      recipientId: envelope.recipientId,
      timer: timer,
    );
    _pendingRelays[envelope.messageId] = pending;
    recipient.socket.add(
      jsonEncode({'type': 'relay', 'envelope': envelope.toJson()}),
    );
    sender.socket.add(
      jsonEncode({'type': 'relayed', 'messageId': envelope.messageId}),
    );
    _log(
      'relayed message=${_shortId(envelope.messageId)} '
      'from=${_shortId(envelope.senderId)} '
      'to=${_shortId(envelope.recipientId)} '
      'bytes=${envelope.cipherText.length}',
    );
  }

  void _handleReceipt(_RelayClient recipient, Map<String, dynamic> message) {
    final messageId = message['messageId'];
    final status = message['status'];
    final code = message['code'];
    if (messageId is! String ||
        !RegExp(r'^[a-f0-9]{32}$').hasMatch(messageId) ||
        (status != 'delivered' && status != 'rejected') ||
        (status == 'rejected' &&
            code != 'decrypt_failed' &&
            code != 'processing_failed')) {
      _sendError(recipient.socket, 'invalid_receipt');
      return;
    }
    final pending = _pendingRelays[messageId];
    if (pending == null || pending.recipientId != recipient.deviceId) {
      _sendError(recipient.socket, 'unknown_receipt');
      return;
    }
    _pendingRelays.remove(messageId);
    pending.timer.cancel();
    final sender = _clients[pending.senderId];
    if (sender == null) return;
    if (status == 'delivered') {
      sender.socket.add(
        jsonEncode({'type': 'delivered', 'messageId': messageId}),
      );
      _log('delivered message=${_shortId(messageId)}');
    } else {
      _sendError(sender.socket, code as String, messageId: messageId);
      _log('rejected message=${_shortId(messageId)} code=$code');
    }
  }

  void _handleClientOffline(String deviceId) {
    final affected = _pendingRelays.values
        .where(
          (pending) =>
              pending.senderId == deviceId || pending.recipientId == deviceId,
        )
        .toList();
    for (final pending in affected) {
      _pendingRelays.remove(pending.messageId);
      pending.timer.cancel();
      if (pending.recipientId == deviceId) {
        final sender = _clients[pending.senderId];
        if (sender != null) {
          _sendError(
            sender.socket,
            'recipient_disconnected',
            messageId: pending.messageId,
          );
        }
      }
    }
  }

  void _broadcastPeerState(_RelayClient changed, {required bool online}) {
    final message = jsonEncode({
      'type': online ? 'peerOnline' : 'peerOffline',
      'peer': changed.publicJson,
    });
    for (final client in _clients.values) {
      if (client.deviceId != changed.deviceId) client.socket.add(message);
    }
  }

  void _sendError(WebSocket socket, String code, {String? messageId}) {
    socket.add(
      jsonEncode({
        'type': 'error',
        'code': code,
        if (messageId != null) 'messageId': messageId,
      }),
    );
  }

  void _log(String message) => onLog?.call(message);

  Future<void> close() async {
    final clients = _clients.values.toList();
    _clients.clear();
    for (final pending in _pendingRelays.values) {
      pending.timer.cancel();
    }
    _pendingRelays.clear();
    await Future.wait(
      clients.map((client) => client.socket.close(WebSocketStatus.goingAway)),
    );
    await _server?.close(force: true);
    _server = null;
  }
}

class _PendingRelay {
  const _PendingRelay({
    required this.messageId,
    required this.senderId,
    required this.recipientId,
    required this.timer,
  });

  final String messageId;
  final String senderId;
  final String recipientId;
  final Timer timer;
}

class _RelayClient {
  const _RelayClient({
    required this.deviceId,
    required this.displayName,
    required this.platform,
    required this.socket,
  });

  final String deviceId;
  final String displayName;
  final String platform;
  final WebSocket socket;

  Map<String, Object?> get publicJson => {
    'deviceId': deviceId,
    'displayName': displayName,
    'platform': platform,
  };
}

bool _validDeviceId(Object? value) =>
    value is String && value.length >= 8 && value.length <= 128;

String _shortId(String value) =>
    value.length <= 8 ? value : value.substring(0, 8);
