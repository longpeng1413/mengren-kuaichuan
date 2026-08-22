import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;

import '../chat/chat_message.dart';
import '../pairing/pairing_relay.dart';
import 'transfer_models.dart';

class TransferServer {
  TransferServer({this.port = 53318, this.pairingRelay});

  final int port;
  final PairingRelay? pairingRelay;
  HttpServer? _server;
  StreamSubscription<HttpRequest>? _serverSubscription;
  final Map<String, _PendingTransfer> _pendingTransfers = {};
  final Map<String, IncomingTransferRequest> _pendingOffers = {};
  final Map<String, Completer<void>> _activeCancellations = {};

  final StreamController<IncomingTransferRequest> _incomingController =
      StreamController<IncomingTransferRequest>.broadcast();
  final StreamController<CompletedTransfer> _completedController =
      StreamController<CompletedTransfer>.broadcast();
  final StreamController<IncomingTextMessage> _messagesController =
      StreamController<IncomingTextMessage>.broadcast();
  final StreamController<TransferProgressUpdate> _progressController =
      StreamController<TransferProgressUpdate>.broadcast();

  Stream<IncomingTransferRequest> get incoming => _incomingController.stream;
  Stream<CompletedTransfer> get completed => _completedController.stream;
  Stream<IncomingTextMessage> get messages => _messagesController.stream;
  Stream<TransferProgressUpdate> get incomingProgress =>
      _progressController.stream;
  int? get actualPort => _server?.port;

  Future<void> start() async {
    if (_server != null) return;
    final server = await HttpServer.bind(
      InternetAddress.anyIPv4,
      port,
      shared: true,
    );
    _server = server;
    _serverSubscription = server.listen(
      _handleRequest,
      onError: (_) {},
      cancelOnError: false,
    );
  }

  Future<void> _handleRequest(HttpRequest request) async {
    try {
      if (pairingRelay != null &&
          await pairingRelay!.handleHttpRequest(request)) {
        return;
      }
      if (request.method == 'POST' && request.uri.path == '/v1/transfers') {
        await _createTransfer(request);
        return;
      }
      if (request.method == 'POST' && request.uri.path == '/v1/messages') {
        await _receiveMessage(request);
        return;
      }

      final cancelMatch = RegExp(r'^/v1/transfers/([a-f0-9]+)$')
          .firstMatch(request.uri.path);
      if (request.method == 'DELETE' && cancelMatch != null) {
        await _cancelTransfer(request, cancelMatch.group(1)!);
        return;
      }

      final match = RegExp(r'^/v1/transfers/([a-f0-9]+)/content$')
          .firstMatch(request.uri.path);
      if (request.method == 'PUT' && match != null) {
        await _receiveContent(request, match.group(1)!);
        return;
      }

      await _jsonResponse(request.response, HttpStatus.notFound, {
        'error': 'not_found',
      });
    } catch (_) {
      try {
        await _jsonResponse(request.response, HttpStatus.internalServerError, {
          'error': 'internal_error',
        });
      } catch (_) {
        await request.response.close();
      }
    }
  }

  Future<void> _createTransfer(HttpRequest request) async {
    final body = await _readSmallJson(request);
    if (body == null) {
      await _jsonResponse(request.response, HttpStatus.badRequest, {
        'error': 'invalid_request',
      });
      return;
    }

    final senderId = body['senderId'];
    final senderName = body['senderName'];
    final fileName = body['fileName'];
    final fileSize = body['fileSize'];
    final suppliedTransferId = body['transferId'];
    if (senderId is! String ||
        senderId.length < 8 ||
        senderId.length > 128 ||
        senderName is! String ||
        senderName.trim().isEmpty ||
        senderName.length > 80 ||
        fileName is! String ||
        fileName.trim().isEmpty ||
        fileName.length > 255 ||
        fileSize is! int ||
        fileSize < 0 ||
        suppliedTransferId is! String ||
        !RegExp(r'^[a-f0-9]{32}$').hasMatch(suppliedTransferId) ||
        _pendingOffers.containsKey(suppliedTransferId) ||
        _pendingTransfers.containsKey(suppliedTransferId)) {
      await _jsonResponse(request.response, HttpStatus.badRequest, {
        'error': 'invalid_metadata',
      });
      return;
    }

    final transferId = suppliedTransferId;
    final decisionCompleter = Completer<TransferDecision>();
    final incoming = IncomingTransferRequest(
      decisionCompleter,
      transferId: transferId,
      senderId: senderId,
      senderName: senderName.trim(),
      fileName: sanitizeFileName(fileName),
      fileSize: fileSize,
    );
    _pendingOffers[transferId] = incoming;
    _incomingController.add(incoming);

    TransferDecision decision;
    try {
      decision = await decisionCompleter.future.timeout(
        const Duration(seconds: 60),
      );
    } on TimeoutException {
      _pendingOffers.remove(transferId);
      await _jsonResponse(request.response, HttpStatus.requestTimeout, {
        'error': 'confirmation_timeout',
      });
      return;
    }
    _pendingOffers.remove(transferId);

    if (!decision.accepted || decision.destinationDirectory == null) {
      await _jsonResponse(request.response, HttpStatus.forbidden, {
        'error': 'rejected',
      });
      return;
    }

    await decision.destinationDirectory!.create(recursive: true);
    _pendingTransfers[transferId] = _PendingTransfer(
      transferId: transferId,
      senderId: senderId,
      senderName: senderName.trim(),
      fileName: incoming.fileName,
      expectedSize: fileSize,
      destinationDirectory: decision.destinationDirectory!,
    );

    await _jsonResponse(request.response, HttpStatus.created, {
      'transferId': transferId,
    });
  }

  Future<void> _cancelTransfer(HttpRequest request, String transferId) async {
    var found = false;
    final offer = _pendingOffers.remove(transferId);
    if (offer != null) {
      offer.cancel();
      found = true;
    }
    if (_pendingTransfers.remove(transferId) case final pending?) {
      _emitCancelled(pending, 0);
      found = true;
    }
    final active = _activeCancellations[transferId];
    if (active != null && !active.isCompleted) {
      active.complete();
      found = true;
    }
    await _jsonResponse(
      request.response,
      found ? HttpStatus.ok : HttpStatus.notFound,
      {'cancelled': found},
    );
  }

  Future<void> _receiveContent(HttpRequest request, String transferId) async {
    final pending = _pendingTransfers.remove(transferId);
    if (pending == null) {
      await request.drain<void>();
      await _jsonResponse(request.response, HttpStatus.notFound, {
        'error': 'unknown_transfer',
      });
      return;
    }

    final destination = await uniqueDestinationFile(
      pending.destinationDirectory,
      pending.fileName,
    );
    final temporary = File('${destination.path}.part-$transferId');
    IOSink? sink;
    var received = 0;
    final cancellation = Completer<void>();
    _activeCancellations[transferId] = cancellation;

    try {
      _emitProgress(pending, 0, force: true);
      sink = temporary.openWrite(mode: FileMode.writeOnly);
      await for (final chunk in request) {
        if (cancellation.isCompleted) {
          throw const TransferCancelledException();
        }
        received += chunk.length;
        if (received > pending.expectedSize) {
          throw const FormatException('file_too_large');
        }
        sink.add(chunk);
        pending.bytesSinceFlush += chunk.length;
        // Periodic flush bounds queued disk writes without forcing an fsync-like
        // wait every 2 MiB. The larger window materially improves Wi-Fi video
        // throughput while still applying backpressure on long transfers.
        if (pending.bytesSinceFlush >= 16 * 1024 * 1024) {
          await sink.flush();
          pending.bytesSinceFlush = 0;
        }
        _emitProgress(
          pending,
          received,
          force: received == pending.expectedSize,
        );
      }
      if (cancellation.isCompleted) {
        throw const TransferCancelledException();
      }
      await sink.flush();
      await sink.close();
      sink = null;

      if (received != pending.expectedSize) {
        throw const FormatException('file_size_mismatch');
      }

      final completedFile = await temporary.rename(destination.path);
      _completedController.add(
        CompletedTransfer(
          transferId: transferId,
          senderId: pending.senderId,
          senderName: pending.senderName,
          file: completedFile,
          fileSize: pending.expectedSize,
        ),
      );
      await _jsonResponse(request.response, HttpStatus.ok, {
        'savedFileName': path.basename(completedFile.path),
      });
    } on TransferCancelledException {
      await sink?.close();
      if (await temporary.exists()) await temporary.delete();
      _emitCancelled(pending, received);
      try {
        await _jsonResponse(request.response, 499, {'error': 'cancelled'});
      } catch (_) {}
    } on FormatException catch (error) {
      await sink?.close();
      if (await temporary.exists()) await temporary.delete();
      await _jsonResponse(request.response, HttpStatus.badRequest, {
        'error': error.message,
      });
    } catch (_) {
      await sink?.close();
      if (await temporary.exists()) await temporary.delete();
      await _jsonResponse(request.response, HttpStatus.internalServerError, {
        'error': 'write_failed',
      });
    } finally {
      _activeCancellations.remove(transferId);
    }
  }

  void _emitCancelled(_PendingTransfer pending, int received) {
    _progressController.add(
      TransferProgressUpdate(
        transferId: pending.transferId,
        peerId: pending.senderId,
        peerName: pending.senderName,
        fileName: pending.fileName,
        transferredBytes: received,
        totalBytes: pending.expectedSize,
        cancelled: true,
      ),
    );
  }

  void _emitProgress(
    _PendingTransfer pending,
    int received, {
    required bool force,
  }) {
    final now = DateTime.now();
    final previous = pending.lastProgressAt;
    if (!force &&
        previous != null &&
        now.difference(previous) < const Duration(milliseconds: 100)) {
      return;
    }
    pending.lastProgressAt = now;
    _progressController.add(
      TransferProgressUpdate(
        transferId: pending.transferId,
        peerId: pending.senderId,
        peerName: pending.senderName,
        fileName: pending.fileName,
        transferredBytes: received,
        totalBytes: pending.expectedSize,
      ),
    );
  }

  Future<void> _receiveMessage(HttpRequest request) async {
    final body = await _readSmallJson(request);
    final messageId = body?['messageId'];
    final senderId = body?['senderId'];
    final senderName = body?['senderName'];
    final text = body?['text'];
    final sentAt = DateTime.tryParse(body?['sentAt']?.toString() ?? '');
    if (messageId is! String ||
        !RegExp(r'^[a-f0-9]{32}$').hasMatch(messageId) ||
        senderId is! String ||
        senderId.length < 8 ||
        senderName is! String ||
        senderName.trim().isEmpty ||
        senderName.length > 80 ||
        text is! String ||
        text.trim().isEmpty ||
        text.length > 16000 ||
        sentAt == null) {
      await _jsonResponse(request.response, HttpStatus.badRequest, {
        'error': 'invalid_message',
      });
      return;
    }
    _messagesController.add(
      IncomingTextMessage(
        messageId: messageId,
        senderId: senderId,
        senderName: senderName.trim(),
        text: text.trim(),
        sentAt: sentAt,
      ),
    );
    await _jsonResponse(request.response, HttpStatus.created, {
      'messageId': messageId,
    });
  }

  Future<Map<String, dynamic>?> _readSmallJson(HttpRequest request) async {
    final bytes = <int>[];
    await for (final chunk in request) {
      bytes.addAll(chunk);
      if (bytes.length > 64 * 1024) return null;
    }
    try {
      final decoded = jsonDecode(utf8.decode(bytes));
      return decoded is Map<String, dynamic> ? decoded : null;
    } on FormatException {
      return null;
    }
  }

  static Future<void> _jsonResponse(
    HttpResponse response,
    int status,
    Map<String, Object?> body,
  ) async {
    response.statusCode = status;
    response.headers.contentType = ContentType.json;
    response.write(jsonEncode(body));
    await response.close();
  }

  Future<void> dispose() async {
    await _serverSubscription?.cancel();
    await _server?.close(force: true);
    _server = null;
    for (final offer in _pendingOffers.values) {
      offer.cancel();
    }
    _pendingOffers.clear();
    for (final cancellation in _activeCancellations.values) {
      if (!cancellation.isCompleted) cancellation.complete();
    }
    _activeCancellations.clear();
    await pairingRelay?.dispose();
    await _incomingController.close();
    await _completedController.close();
    await _messagesController.close();
    await _progressController.close();
  }
}

class _PendingTransfer {
  _PendingTransfer({
    required this.transferId,
    required this.senderId,
    required this.senderName,
    required this.fileName,
    required this.expectedSize,
    required this.destinationDirectory,
  });

  final String transferId;
  final String senderId;
  final String senderName;
  final String fileName;
  final int expectedSize;
  final Directory destinationDirectory;
  DateTime? lastProgressAt;
  int bytesSinceFlush = 0;
}

String sanitizeFileName(String input) {
  var name = input.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_').trim();
  name = name.replaceAll(RegExp(r'[. ]+$'), '');
  if (name.isEmpty || name == '.' || name == '..') return '未命名文件';
  return name.length <= 180 ? name : name.substring(0, 180);
}

Future<File> uniqueDestinationFile(Directory directory, String fileName) async {
  final safeName = sanitizeFileName(fileName);
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
