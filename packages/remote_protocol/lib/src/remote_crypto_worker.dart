import 'dart:async';
import 'dart:isolate';

import 'encrypted_remote_envelope.dart';
import 'remote_crypto.dart';
import 'remote_payload.dart';

class RemoteCryptoWorkerException implements Exception {
  const RemoteCryptoWorkerException(this.message);

  final String message;

  @override
  String toString() => 'RemoteCryptoWorkerException($message)';
}

/// Keeps expensive PBKDF2, AES-GCM, JSON and Base64 work off Flutter's UI
/// isolate while preserving [RemoteCrypto]'s derived-key cache.
class RemoteCryptoWorker {
  ReceivePort? _responses;
  StreamSubscription<dynamic>? _responseSubscription;
  Isolate? _isolate;
  SendPort? _commands;
  Future<void>? _starting;
  final Map<int, Completer<Object?>> _pending = {};
  int _nextRequestId = 0;
  bool _disposed = false;

  Future<EncryptedRemoteEnvelope> encrypt({
    required RemotePayload payload,
    required String familySecret,
    required String senderId,
    required String recipientId,
    String? messageId,
    DateTime? sentAt,
  }) async {
    final result = await _request('encrypt', {
      'payload': payload,
      'familySecret': familySecret,
      'senderId': senderId,
      'recipientId': recipientId,
      'messageId': messageId,
      'sentAt': sentAt,
    });
    if (result is! EncryptedRemoteEnvelope) {
      throw const RemoteCryptoWorkerException('invalid encrypt result');
    }
    return result;
  }

  Future<RemotePayload> decrypt({
    required EncryptedRemoteEnvelope envelope,
    required String familySecret,
  }) async {
    final result = await _request('decrypt', {
      'envelope': envelope,
      'familySecret': familySecret,
    });
    if (result is! RemotePayload) {
      throw const RemoteCryptoWorkerException('invalid decrypt result');
    }
    return result;
  }

  Future<Object?> _request(
    String operation,
    Map<String, Object?> arguments,
  ) async {
    if (_disposed) {
      throw const RemoteCryptoWorkerException('worker disposed');
    }
    await _ensureStarted();
    final id = _nextRequestId++;
    final completer = Completer<Object?>();
    _pending[id] = completer;
    final commands = _commands;
    if (commands == null) {
      _pending.remove(id);
      throw const RemoteCryptoWorkerException('worker unavailable');
    }
    commands.send({
      'type': 'request',
      'id': id,
      'operation': operation,
      ...arguments,
    });
    return completer.future;
  }

  Future<void> _ensureStarted() {
    if (_disposed) {
      throw const RemoteCryptoWorkerException('worker disposed');
    }
    return _starting ??= _start();
  }

  Future<void> _start() async {
    final responses = ReceivePort();
    _responses = responses;
    final ready = Completer<SendPort>();
    _responseSubscription = responses.listen((message) {
      if (message is Map && message['type'] == 'ready') {
        final port = message['port'];
        if (port is SendPort && !ready.isCompleted) ready.complete(port);
        return;
      }
      if (message == null || message is List) {
        final detail = message is List && message.isNotEmpty
            ? message.first.toString()
            : 'worker exited';
        _commands = null;
        _isolate = null;
        _starting = null;
        if (!ready.isCompleted) {
          ready.completeError(RemoteCryptoWorkerException(detail));
        }
        _failPending(RemoteCryptoWorkerException(detail));
        return;
      }
      if (message is! Map || message['type'] != 'result') return;
      final id = message['id'];
      if (id is! int) return;
      final completer = _pending.remove(id);
      if (completer == null || completer.isCompleted) return;
      if (message['ok'] == true) {
        completer.complete(message['value']);
      } else {
        completer.completeError(
          RemoteCryptoWorkerException(
            message['error']?.toString() ?? 'crypto operation failed',
          ),
          StackTrace.fromString(message['stack']?.toString() ?? ''),
        );
      }
    });
    try {
      _isolate = await Isolate.spawn<SendPort>(
        _remoteCryptoWorkerMain,
        responses.sendPort,
        debugName: 'mengren-remote-crypto',
        onError: responses.sendPort,
        onExit: responses.sendPort,
      );
      _commands = await ready.future.timeout(const Duration(seconds: 10));
    } catch (_) {
      await _responseSubscription?.cancel();
      responses.close();
      _responses = null;
      rethrow;
    }
  }

  void _failPending(Object error) {
    for (final completer in _pending.values) {
      if (!completer.isCompleted) completer.completeError(error);
    }
    _pending.clear();
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    try {
      await _starting;
    } on Object {
      // A failed startup has already completed pending requests with an error.
    }
    _commands?.send(const {'type': 'shutdown'});
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _commands = null;
    _failPending(const RemoteCryptoWorkerException('worker disposed'));
    await _responseSubscription?.cancel();
    _responses?.close();
    _responses = null;
  }
}

Future<void> _remoteCryptoWorkerMain(SendPort responses) async {
  final commands = ReceivePort();
  final crypto = RemoteCrypto();
  responses.send({'type': 'ready', 'port': commands.sendPort});
  await for (final message in commands) {
    if (message is! Map) continue;
    if (message['type'] == 'shutdown') {
      commands.close();
      return;
    }
    if (message['type'] != 'request' || message['id'] is! int) continue;
    final id = message['id'] as int;
    try {
      final Object result = switch (message['operation']) {
        'encrypt' => await crypto.encrypt(
          payload: message['payload'] as RemotePayload,
          familySecret: message['familySecret'] as String,
          senderId: message['senderId'] as String,
          recipientId: message['recipientId'] as String,
          messageId: message['messageId'] as String?,
          sentAt: message['sentAt'] as DateTime?,
        ),
        'decrypt' => await crypto.decrypt(
          envelope: message['envelope'] as EncryptedRemoteEnvelope,
          familySecret: message['familySecret'] as String,
        ),
        _ => throw const RemoteCryptoWorkerException('unsupported operation'),
      };
      responses.send({'type': 'result', 'id': id, 'ok': true, 'value': result});
    } catch (error, stackTrace) {
      responses.send({
        'type': 'result',
        'id': id,
        'ok': false,
        'error': error.toString(),
        'stack': stackTrace.toString(),
      });
    }
  }
}
