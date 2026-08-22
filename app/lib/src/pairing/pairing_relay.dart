import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as path;

import '../chat/chat_message.dart';
import '../device/device_identity.dart';
import '../discovery/discovered_device.dart';
import '../transfer/transfer_client.dart';
import '../transfer/transfer_models.dart';
import 'pairing_endpoint.dart';

class PairingRelay {
  factory PairingRelay({
    required DeviceIdentity identity,
    required String pairingCode,
  }) => PairingRelay._(identity, pairingCode);

  PairingRelay._(this._identity, this.pairingCode);

  static const channelPath = '/v1/pair/channel';
  static const protocolVersion = 2;

  DeviceIdentity _identity;
  final String pairingCode;
  final Map<String, _RelaySession> _sessions = {};
  bool _connecting = false;
  bool _disposed = false;

  final StreamController<List<DiscoveredDevice>> _devicesController =
      StreamController<List<DiscoveredDevice>>.broadcast();
  final StreamController<IncomingTransferRequest> _incomingController =
      StreamController<IncomingTransferRequest>.broadcast();
  final StreamController<CompletedTransfer> _completedController =
      StreamController<CompletedTransfer>.broadcast();
  final StreamController<IncomingTextMessage> _messagesController =
      StreamController<IncomingTextMessage>.broadcast();
  final StreamController<TransferProgressUpdate> _progressController =
      StreamController<TransferProgressUpdate>.broadcast();

  Stream<List<DiscoveredDevice>> get devices => _devicesController.stream;
  Stream<IncomingTransferRequest> get incoming => _incomingController.stream;
  Stream<CompletedTransfer> get completed => _completedController.stream;
  Stream<IncomingTextMessage> get messages => _messagesController.stream;
  Stream<TransferProgressUpdate> get incomingProgress =>
      _progressController.stream;
  bool get isConnecting => _connecting;
  bool hasSession(String deviceId) => _sessions.containsKey(deviceId);

  void updateIdentity(DeviceIdentity identity) {
    _identity = identity;
    for (final session in _sessions.values) {
      session.updateLocalIdentity(identity);
    }
  }

  Future<bool> handleHttpRequest(HttpRequest request) async {
    if (request.uri.path != channelPath) return false;

    final suppliedCode = normalizePairingCode(
      request.uri.queryParameters['code'] ?? '',
    );
    if (suppliedCode != pairingCode) {
      request.response.statusCode = HttpStatus.forbidden;
      request.response.write('invalid_pairing_code');
      await request.response.close();
      return true;
    }
    if (!WebSocketTransformer.isUpgradeRequest(request)) {
      request.response.statusCode = HttpStatus.upgradeRequired;
      await request.response.close();
      return true;
    }

    // Files such as MP4/ZIP are already compressed. Per-message compression
    // wastes CPU and can reduce LAN throughput substantially on phones.
    final socket = await WebSocketTransformer.upgrade(
      request,
      compression: CompressionOptions.compressionOff,
    );
    final session = _createSession(
      socket: socket,
      remoteAddress:
          request.connectionInfo?.remoteAddress ?? InternetAddress.anyIPv4,
      remotePort: request.connectionInfo?.remotePort ?? 0,
    );
    try {
      await session.start();
      _register(session);
    } catch (_) {
      await session.close();
    }
    return true;
  }

  Future<DiscoveredDevice> connect(PairingEndpoint endpoint) async {
    if (_disposed) throw const TransferException('配对服务已经停止');
    if (_connecting) throw const TransferException('正在连接，请稍候');

    final existing = _sessions.values.where(
      (session) => session.remoteAddress.address == endpoint.host,
    );
    if (existing.isNotEmpty) return _deviceFor(existing.first);

    _connecting = true;
    try {
      final addresses = await InternetAddress.lookup(
        endpoint.host,
        type: InternetAddressType.IPv4,
      ).timeout(const Duration(seconds: 5));
      if (addresses.isEmpty) throw const TransferException('无法解析配对地址');

      final uri = Uri(
        scheme: 'ws',
        host: endpoint.host,
        port: endpoint.port,
        path: channelPath,
        queryParameters: {'code': endpoint.code},
      );
      final socket = await WebSocket.connect(
        uri.toString(),
        compression: CompressionOptions.compressionOff,
      ).timeout(const Duration(seconds: 8));
      final session = _createSession(
        socket: socket,
        remoteAddress: addresses.first,
        remotePort: endpoint.port,
      );
      await session.start();
      final registered = _register(session);
      return _deviceFor(registered);
    } on TimeoutException {
      throw const TransferException('连接配对设备超时');
    } on SocketException catch (error) {
      throw TransferException('无法连接配对设备：${error.message}');
    } on WebSocketException catch (error) {
      throw TransferException('配对握手失败：${error.message}');
    } finally {
      _connecting = false;
    }
  }

  Future<TransferResult> sendFile({
    required String receiverId,
    required File file,
    TransferProgress? onProgress,
    TransferCancellationToken? cancellation,
  }) async {
    final session = _sessions[receiverId];
    if (session == null) throw const TransferException('配对连接已经断开');
    return session.sendFile(
      file,
      onProgress: onProgress,
      cancellation: cancellation,
    );
  }

  Future<String> sendText({
    required String receiverId,
    required String text,
  }) async {
    final session = _sessions[receiverId];
    if (session == null) throw const TransferException('配对连接已经断开');
    return session.sendText(text);
  }

  Future<void> disconnect(String deviceId) async {
    final session = _sessions.remove(deviceId);
    if (session != null) await session.close();
    _emitDevices();
  }

  _RelaySession _createSession({
    required WebSocket socket,
    required InternetAddress remoteAddress,
    required int remotePort,
  }) {
    return _RelaySession(
      socket: socket,
      localIdentity: _identity,
      remoteAddress: remoteAddress,
      remotePort: remotePort,
      onIncoming: _incomingController.add,
      onCompleted: _completedController.add,
      onMessage: _messagesController.add,
      onProgress: _progressController.add,
      onIdentityChanged: _emitDevices,
    );
  }

  _RelaySession _register(_RelaySession session) {
    final remoteId = session.remoteIdentity.deviceId;
    final previous = _sessions[remoteId];
    // Both peers derive the same key from the two hello nonces. If simultaneous
    // reconnects create two cross-connections, both sides therefore keep the
    // same one instead of each closing the connection selected by its peer.
    if (previous != null &&
        previous.sessionKey.compareTo(session.sessionKey) <= 0) {
      unawaited(session.close());
      return previous;
    }
    _sessions[remoteId] = session;
    if (previous != null && !identical(previous, session)) {
      unawaited(previous.close());
    }
    session.closed.whenComplete(() {
      if (identical(_sessions[remoteId], session)) {
        _sessions.remove(remoteId);
        _emitDevices();
      }
    });
    _emitDevices();
    return session;
  }

  DiscoveredDevice _deviceFor(_RelaySession session) {
    final identity = session.remoteIdentity;
    return DiscoveredDevice(
      deviceId: identity.deviceId,
      displayName: identity.displayName,
      platform: identity.platform,
      address: session.remoteAddress,
      transferPort: session.remotePort,
      lastSeen: DateTime.now(),
      connectionMode: DeviceConnectionMode.paired,
    );
  }

  void _emitDevices() {
    if (_devicesController.isClosed) return;
    final snapshot = _sessions.values.map(_deviceFor).toList()
      ..sort(
        (left, right) => left.displayName.toLowerCase().compareTo(
          right.displayName.toLowerCase(),
        ),
      );
    _devicesController.add(List.unmodifiable(snapshot));
  }

  Future<void> dispose() async {
    _disposed = true;
    final sessions = _sessions.values.toList();
    _sessions.clear();
    await Future.wait(sessions.map((session) => session.close()));
    await _devicesController.close();
    await _incomingController.close();
    await _completedController.close();
    await _messagesController.close();
    await _progressController.close();
  }
}

class _RelaySession {
  _RelaySession({
    required this.socket,
    required this._localIdentity,
    required this.remoteAddress,
    required this.remotePort,
    required this.onIncoming,
    required this.onCompleted,
    required this.onMessage,
    required this.onProgress,
    required this.onIdentityChanged,
  });

  final WebSocket socket;
  DeviceIdentity _localIdentity;
  final InternetAddress remoteAddress;
  final int remotePort;
  final void Function(IncomingTransferRequest) onIncoming;
  final void Function(CompletedTransfer) onCompleted;
  final void Function(IncomingTextMessage) onMessage;
  final void Function(TransferProgressUpdate) onProgress;
  final void Function() onIdentityChanged;

  final Completer<DeviceIdentity> _remoteIdentityCompleter = Completer();
  final Completer<void> _closedCompleter = Completer();
  final Map<String, _OutgoingRelayTransfer> _outgoing = {};
  final Map<String, _IncomingRelayTransfer> _incoming = {};
  final Map<String, IncomingTransferRequest> _incomingOffers = {};
  final Map<String, Completer<void>> _outgoingMessages = {};
  final String _localSessionNonce = _randomRelayId();
  StreamSubscription<dynamic>? _subscription;
  DeviceIdentity? _remoteIdentity;
  String? _remoteSessionNonce;
  String? _activeIncomingId;
  bool _sending = false;
  bool _isClosed = false;

  DeviceIdentity get remoteIdentity => _remoteIdentity!;
  String get sessionKey {
    final remote = _remoteSessionNonce!;
    return _localSessionNonce.compareTo(remote) <= 0
        ? '$_localSessionNonce:$remote'
        : '$remote:$_localSessionNonce';
  }

  Future<void> get closed => _closedCompleter.future;

  Future<void> start() async {
    _subscription = socket.listen(
      _handleEvent,
      onDone: _handleClosed,
      onError: (_) => _handleClosed(),
      cancelOnError: false,
    );
    _sendHello();
    await _remoteIdentityCompleter.future.timeout(const Duration(seconds: 8));
  }

  void updateLocalIdentity(DeviceIdentity identity) {
    _localIdentity = identity;
    _sendHello();
  }

  Future<TransferResult> sendFile(
    File file, {
    TransferProgress? onProgress,
    TransferCancellationToken? cancellation,
  }) async {
    if (_isClosed) throw const TransferException('配对连接已经断开');
    if (_sending) throw const TransferException('该配对设备正在接收另一个文件');
    _sending = true;

    final transferId = _randomRelayId();
    final fileSize = await file.length();
    final fileName = path.basename(file.path);
    final state = _OutgoingRelayTransfer(fileName: fileName);
    _outgoing[transferId] = state;
    final removeCancellationListener = cancellation?.addListener(
      () => unawaited(close()),
    );
    try {
      cancellation?.throwIfCancelled();
      _sendJson({
        'type': 'offer',
        'transferId': transferId,
        'senderId': _localIdentity.deviceId,
        'senderName': _localIdentity.displayName,
        'fileName': fileName,
        'fileSize': fileSize,
      });

      final accepted = await state.decision.future.timeout(
        const Duration(seconds: 60),
      );
      cancellation?.throwIfCancelled();
      if (!accepted) throw const TransferException('接收方拒绝了文件');

      _sendJson({'type': 'contentStart', 'transferId': transferId});
      onProgress?.call(0, fileSize);
      await socket.addStream(_relayFileChunks(file, fileSize, onProgress));
      cancellation?.throwIfCancelled();
      _sendJson({'type': 'contentEnd', 'transferId': transferId});

      final savedFileName = await state.completed.future.timeout(
        const Duration(minutes: 30),
      );
      cancellation?.throwIfCancelled();
      return TransferResult(fileName: fileName, savedFileName: savedFileName);
    } on TimeoutException {
      throw const TransferException('等待配对设备响应超时');
    } catch (_) {
      if (cancellation?.isCancelled ?? false) {
        throw const TransferCancelledException();
      }
      rethrow;
    } finally {
      removeCancellationListener?.call();
      _outgoing.remove(transferId);
      _sending = false;
    }
  }

  Future<String> sendText(String text) async {
    if (_isClosed) throw const TransferException('配对连接已经断开');
    final trimmed = text.trim();
    if (trimmed.isEmpty) throw const TransferException('消息不能为空');
    if (trimmed.length > 16000) {
      throw const TransferException('单条消息不能超过 16000 个字符');
    }
    final messageId = _randomRelayId();
    final acknowledged = Completer<void>();
    _outgoingMessages[messageId] = acknowledged;
    try {
      _sendJson({
        'type': 'message',
        'messageId': messageId,
        'senderId': _localIdentity.deviceId,
        'senderName': _localIdentity.displayName,
        'text': trimmed,
        'sentAt': DateTime.now().toUtc().toIso8601String(),
      });
      await acknowledged.future.timeout(const Duration(seconds: 10));
      return messageId;
    } on TimeoutException {
      throw const TransferException('等待对方确认消息超时');
    } finally {
      _outgoingMessages.remove(messageId);
    }
  }

  void _handleEvent(dynamic event) {
    if (event is String) {
      _handleText(event);
    } else if (event is List<int>) {
      _handleBinary(event);
    }
  }

  void _handleText(String value) {
    Map<String, dynamic> message;
    try {
      final decoded = jsonDecode(value);
      if (decoded is! Map<String, dynamic>) return;
      message = decoded;
    } on FormatException {
      return;
    }

    switch (message['type']) {
      case 'hello':
        _handleHello(message);
      case 'offer':
        unawaited(_handleOffer(message));
      case 'decision':
        _handleDecision(message);
      case 'contentStart':
        _handleContentStart(message);
      case 'contentEnd':
        unawaited(_handleContentEnd(message));
      case 'complete':
        _handleComplete(message);
      case 'error':
        _handleRemoteError(message);
      case 'message':
        _handleIncomingMessage(message);
      case 'messageAck':
        _handleMessageAck(message);
    }
  }

  void _handleIncomingMessage(Map<String, dynamic> message) {
    final messageId = message['messageId'];
    final senderId = message['senderId'];
    final senderName = message['senderName'];
    final text = message['text'];
    final sentAt = DateTime.tryParse(message['sentAt']?.toString() ?? '');
    if (messageId is! String ||
        !RegExp(r'^[a-f0-9]{32}$').hasMatch(messageId) ||
        senderId is! String ||
        senderId.length < 8 ||
        senderName is! String ||
        senderName.trim().isEmpty ||
        text is! String ||
        text.trim().isEmpty ||
        text.length > 16000 ||
        sentAt == null) {
      return;
    }
    onMessage(
      IncomingTextMessage(
        messageId: messageId,
        senderId: senderId,
        senderName: senderName.trim(),
        text: text.trim(),
        sentAt: sentAt,
      ),
    );
    _sendJson({'type': 'messageAck', 'messageId': messageId});
  }

  void _handleMessageAck(Map<String, dynamic> message) {
    final messageId = message['messageId'];
    if (messageId is! String) return;
    final acknowledged = _outgoingMessages[messageId];
    if (acknowledged != null && !acknowledged.isCompleted) {
      acknowledged.complete();
    }
  }

  void _handleHello(Map<String, dynamic> message) {
    final version = message['protocol'];
    final deviceId = message['deviceId'];
    final displayName = message['displayName'];
    final platform = message['platform'];
    final sessionNonce = message['sessionNonce'];
    if (version != PairingRelay.protocolVersion ||
        deviceId is! String ||
        deviceId.length < 8 ||
        displayName is! String ||
        displayName.trim().isEmpty ||
        platform is! String ||
        platform.isEmpty ||
        sessionNonce is! String ||
        !RegExp(r'^[a-f0-9]{32}$').hasMatch(sessionNonce)) {
      return;
    }

    _remoteIdentity = DeviceIdentity(
      deviceId: deviceId,
      displayName: displayName.trim(),
      platform: platform,
    );
    _remoteSessionNonce = sessionNonce;
    if (!_remoteIdentityCompleter.isCompleted) {
      _remoteIdentityCompleter.complete(_remoteIdentity);
    } else {
      onIdentityChanged();
    }
  }

  Future<void> _handleOffer(Map<String, dynamic> message) async {
    final transferId = message['transferId'];
    final senderId = message['senderId'];
    final senderName = message['senderName'];
    final fileName = message['fileName'];
    final fileSize = message['fileSize'];
    if (transferId is! String ||
        !RegExp(r'^[a-f0-9]{32}$').hasMatch(transferId) ||
        senderId is! String ||
        senderId.length < 8 ||
        senderName is! String ||
        senderName.trim().isEmpty ||
        fileName is! String ||
        fileName.trim().isEmpty ||
        fileSize is! int ||
        fileSize < 0 ||
        _incoming.containsKey(transferId)) {
      _sendJson({
        'type': 'error',
        'transferId': transferId,
        'message': 'invalid_offer',
      });
      return;
    }

    final decisionCompleter = Completer<TransferDecision>();
    final request = IncomingTransferRequest(
      decisionCompleter,
      transferId: transferId,
      senderId: senderId,
      senderName: senderName.trim(),
      fileName: _sanitizeRelayFileName(fileName),
      fileSize: fileSize,
    );
    _incomingOffers[transferId] = request;
    onIncoming(request);

    TransferDecision decision;
    try {
      decision = await request.decision.timeout(const Duration(seconds: 60));
    } on TimeoutException {
      decision = const TransferDecision.reject();
    }
    _incomingOffers.remove(transferId);
    if (!decision.accepted || decision.destinationDirectory == null) {
      _sendJson({
        'type': 'decision',
        'transferId': transferId,
        'accepted': false,
      });
      return;
    }

    try {
      await decision.destinationDirectory!.create(recursive: true);
      final destination = await _uniqueRelayDestination(
        decision.destinationDirectory!,
        request.fileName,
      );
      final temporary = File('${destination.path}.part-$transferId');
      _incoming[transferId] = _IncomingRelayTransfer(
        transferId: transferId,
        senderId: senderId,
        senderName: senderName.trim(),
        fileName: request.fileName,
        expectedSize: fileSize,
        destination: destination,
        temporary: temporary,
        sink: temporary.openWrite(mode: FileMode.writeOnly),
      );
      _sendJson({
        'type': 'decision',
        'transferId': transferId,
        'accepted': true,
      });
    } catch (_) {
      _sendJson({
        'type': 'error',
        'transferId': transferId,
        'message': 'destination_failed',
      });
    }
  }

  void _handleDecision(Map<String, dynamic> message) {
    final transferId = message['transferId'];
    final accepted = message['accepted'];
    if (transferId is! String || accepted is! bool) return;
    final state = _outgoing[transferId];
    if (state != null && !state.decision.isCompleted) {
      state.decision.complete(accepted);
    }
  }

  void _handleContentStart(Map<String, dynamic> message) {
    final transferId = message['transferId'];
    if (transferId is! String || !_incoming.containsKey(transferId)) return;
    _activeIncomingId = transferId;
    _emitIncomingProgress(_incoming[transferId]!, 0, force: true);
  }

  void _handleBinary(List<int> bytes) {
    final transferId = _activeIncomingId;
    if (transferId == null) return;
    final state = _incoming[transferId];
    if (state == null) return;
    state.received += bytes.length;
    if (state.received > state.expectedSize) {
      unawaited(_failIncoming(state, 'file_too_large'));
      return;
    }
    state.sink.add(bytes);
    state.bytesSinceFlush += bytes.length;
    _emitIncomingProgress(
      state,
      state.received,
      force: state.received == state.expectedSize,
    );
    if (state.bytesSinceFlush >= 16 * 1024 * 1024 && !state.isFlushing) {
      state.isFlushing = true;
      _subscription?.pause();
      unawaited(_flushIncoming(state));
    }
  }

  Future<void> _flushIncoming(_IncomingRelayTransfer state) async {
    try {
      await state.sink.flush();
      state.bytesSinceFlush = 0;
    } catch (_) {
      await _failIncoming(state, 'write_failed');
    } finally {
      state.isFlushing = false;
      if (!_isClosed) _subscription?.resume();
    }
  }

  void _emitIncomingProgress(
    _IncomingRelayTransfer state,
    int received, {
    required bool force,
  }) {
    final now = DateTime.now();
    final previous = state.lastProgressAt;
    if (!force &&
        previous != null &&
        now.difference(previous) < const Duration(milliseconds: 100)) {
      return;
    }
    state.lastProgressAt = now;
    onProgress(
      TransferProgressUpdate(
        transferId: state.transferId,
        peerId: state.senderId,
        peerName: state.senderName,
        fileName: state.fileName,
        transferredBytes: received,
        totalBytes: state.expectedSize,
      ),
    );
  }

  Future<void> _handleContentEnd(Map<String, dynamic> message) async {
    final transferId = message['transferId'];
    if (transferId is! String || transferId != _activeIncomingId) return;
    _activeIncomingId = null;
    final state = _incoming.remove(transferId);
    if (state == null) return;

    try {
      await state.sink.flush();
      await state.sink.close();
      if (state.received != state.expectedSize) {
        throw const FormatException('file_size_mismatch');
      }
      final completedFile = await state.temporary.rename(
        state.destination.path,
      );
      onCompleted(
        CompletedTransfer(
          transferId: transferId,
          senderId: state.senderId,
          senderName: state.senderName,
          file: completedFile,
          fileSize: state.expectedSize,
        ),
      );
      _sendJson({
        'type': 'complete',
        'transferId': transferId,
        'savedFileName': path.basename(completedFile.path),
      });
    } on FormatException catch (error) {
      if (await state.temporary.exists()) await state.temporary.delete();
      _sendJson({
        'type': 'error',
        'transferId': transferId,
        'message': error.message,
      });
    } catch (_) {
      if (await state.temporary.exists()) await state.temporary.delete();
      _sendJson({
        'type': 'error',
        'transferId': transferId,
        'message': 'write_failed',
      });
    }
  }

  void _handleComplete(Map<String, dynamic> message) {
    final transferId = message['transferId'];
    final savedFileName = message['savedFileName'];
    if (transferId is! String || savedFileName is! String) return;
    final state = _outgoing[transferId];
    if (state != null && !state.completed.isCompleted) {
      state.completed.complete(savedFileName);
    }
  }

  void _handleRemoteError(Map<String, dynamic> message) {
    final transferId = message['transferId'];
    final error = message['message'];
    if (transferId is! String) return;
    final state = _outgoing[transferId];
    if (state == null) return;
    final exception = TransferException(_relayErrorMessage(error));
    if (!state.decision.isCompleted) state.decision.completeError(exception);
    if (!state.completed.isCompleted) state.completed.completeError(exception);
  }

  Future<void> _failIncoming(_IncomingRelayTransfer state, String error) async {
    if (!identical(_incoming.remove(state.transferId), state)) return;
    if (_activeIncomingId == state.transferId) _activeIncomingId = null;
    await state.sink.close();
    if (await state.temporary.exists()) await state.temporary.delete();
    onProgress(
      TransferProgressUpdate(
        transferId: state.transferId,
        peerId: state.senderId,
        peerName: state.senderName,
        fileName: state.fileName,
        transferredBytes: state.received,
        totalBytes: state.expectedSize,
        cancelled: true,
      ),
    );
    _sendJson({
      'type': 'error',
      'transferId': state.transferId,
      'message': error,
    });
  }

  void _sendHello() {
    _sendJson({
      'type': 'hello',
      'protocol': PairingRelay.protocolVersion,
      'deviceId': _localIdentity.deviceId,
      'displayName': _localIdentity.displayName,
      'platform': _localIdentity.platform,
      'sessionNonce': _localSessionNonce,
    });
  }

  void _sendJson(Map<String, Object?> message) {
    if (!_isClosed) socket.add(jsonEncode(message));
  }

  void _handleClosed() {
    if (_isClosed) return;
    _isClosed = true;
    final exception = const TransferException('配对连接已经断开');
    if (!_remoteIdentityCompleter.isCompleted) {
      _remoteIdentityCompleter.completeError(exception);
    }
    for (final state in _outgoing.values) {
      if (!state.decision.isCompleted) {
        state.decision.completeError(exception);
      } else if (!state.completed.isCompleted) {
        state.completed.completeError(exception);
      }
    }
    _outgoing.clear();
    for (final acknowledged in _outgoingMessages.values) {
      if (!acknowledged.isCompleted) acknowledged.completeError(exception);
    }
    _outgoingMessages.clear();
    for (final request in _incomingOffers.values) {
      request.cancel();
    }
    _incomingOffers.clear();
    for (final state in _incoming.values) {
      unawaited(_failIncoming(state, 'connection_closed'));
    }
    if (!_closedCompleter.isCompleted) _closedCompleter.complete();
  }

  Future<void> close() async {
    if (!_isClosed) {
      await socket.close(WebSocketStatus.normalClosure);
      _handleClosed();
    }
    await _subscription?.cancel();
  }
}

Stream<List<int>> _relayFileChunks(
  File file,
  int total,
  TransferProgress? onProgress,
) async* {
  var transferred = 0;
  DateTime? lastProgressAt;
  final input = await file.open();
  try {
    while (transferred < total) {
      final chunk = await input.read(min(1024 * 1024, total - transferred));
      if (chunk.isEmpty) break;
      transferred += chunk.length;
      final now = DateTime.now();
      if (transferred == total ||
          lastProgressAt == null ||
          now.difference(lastProgressAt) >= const Duration(milliseconds: 100)) {
        lastProgressAt = now;
        onProgress?.call(transferred, total);
      }
      yield chunk;
    }
  } finally {
    await input.close();
  }
}

class _OutgoingRelayTransfer {
  _OutgoingRelayTransfer({required this.fileName});

  final String fileName;
  final Completer<bool> decision = Completer();
  final Completer<String> completed = Completer();
}

class _IncomingRelayTransfer {
  _IncomingRelayTransfer({
    required this.transferId,
    required this.senderId,
    required this.senderName,
    required this.fileName,
    required this.expectedSize,
    required this.destination,
    required this.temporary,
    required this.sink,
  });

  final String transferId;
  final String senderId;
  final String senderName;
  final String fileName;
  final int expectedSize;
  final File destination;
  final File temporary;
  final IOSink sink;
  int received = 0;
  int bytesSinceFlush = 0;
  bool isFlushing = false;
  DateTime? lastProgressAt;
}

String _randomRelayId() {
  final random = Random.secure();
  return List.generate(
    16,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
}

String _sanitizeRelayFileName(String input) {
  var name = input.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_').trim();
  name = name.replaceAll(RegExp(r'[. ]+$'), '');
  if (name.isEmpty || name == '.' || name == '..') return '未命名文件';
  return name.length <= 180 ? name : name.substring(0, 180);
}

Future<File> _uniqueRelayDestination(
  Directory directory,
  String fileName,
) async {
  final safeName = _sanitizeRelayFileName(fileName);
  var candidate = File(path.join(directory.path, safeName));
  if (!await candidate.exists()) return candidate;

  final extension = path.extension(safeName);
  final stem = path.basenameWithoutExtension(safeName);
  for (var index = 1; index < 10000; index++) {
    candidate = File(path.join(directory.path, '$stem ($index)$extension'));
    if (!await candidate.exists()) return candidate;
  }
  throw const FileSystemException('无法生成不重复的文件名');
}

String _relayErrorMessage(Object? error) {
  switch (error) {
    case 'file_size_mismatch':
      return '文件大小校验失败';
    case 'file_too_large':
      return '发送的数据超过声明大小';
    case 'write_failed':
    case 'destination_failed':
      return '接收方无法保存文件';
    case 'connection_closed':
      return '配对连接已经断开';
    default:
      return '配对传输失败';
  }
}
