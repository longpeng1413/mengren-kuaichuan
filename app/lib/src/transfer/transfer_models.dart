import 'dart:async';
import 'dart:io';

typedef TransferProgress = void Function(int transferredBytes, int totalBytes);

class TransferCancellationToken {
  bool _isCancelled = false;
  final Completer<void> _cancelled = Completer<void>();
  final Set<void Function()> _listeners = {};

  bool get isCancelled => _isCancelled;
  Future<void> get whenCancelled => _cancelled.future;

  void cancel() {
    if (_isCancelled) return;
    _isCancelled = true;
    _cancelled.complete();
    final listeners = _listeners.toList();
    _listeners.clear();
    for (final listener in listeners) {
      listener();
    }
  }

  void Function() addListener(void Function() listener) {
    if (_isCancelled) {
      listener();
      return () {};
    }
    _listeners.add(listener);
    return () => _listeners.remove(listener);
  }

  void throwIfCancelled() {
    if (_isCancelled) throw const TransferCancelledException();
  }
}

class TransferCancelledException implements Exception {
  const TransferCancelledException();

  @override
  String toString() => '发送已取消';
}

class TransferProgressUpdate {
  const TransferProgressUpdate({
    required this.transferId,
    required this.peerId,
    required this.peerName,
    required this.fileName,
    required this.transferredBytes,
    required this.totalBytes,
    this.cancelled = false,
  });

  final String transferId;
  final String peerId;
  final String peerName;
  final String fileName;
  final int transferredBytes;
  final int totalBytes;
  final bool cancelled;
}

class IncomingTransferRequest {
  IncomingTransferRequest(
    this._decision, {
    required this.transferId,
    required this.senderId,
    required this.senderName,
    required this.fileName,
    required this.fileSize,
  });

  final String transferId;
  final String senderId;
  final String senderName;
  final String fileName;
  final int fileSize;
  final Completer<TransferDecision> _decision;
  final Completer<void> _cancelled = Completer<void>();

  bool get isResolved => _decision.isCompleted;
  Future<TransferDecision> get decision => _decision.future;
  Future<void> get cancelled => _cancelled.future;

  void accept(Directory destinationDirectory) {
    if (!_decision.isCompleted) {
      _decision.complete(TransferDecision.accept(destinationDirectory));
    }
  }

  void reject() {
    if (!_decision.isCompleted) {
      _decision.complete(const TransferDecision.reject());
    }
  }

  void cancel() {
    if (!_cancelled.isCompleted) _cancelled.complete();
    if (!_decision.isCompleted) {
      _decision.complete(const TransferDecision.cancelled());
    }
  }
}

class TransferDecision {
  const TransferDecision._({
    required this.accepted,
    this.destinationDirectory,
    this.wasCancelled = false,
  });

  const TransferDecision.accept(Directory destinationDirectory)
    : this._(accepted: true, destinationDirectory: destinationDirectory);

  const TransferDecision.reject() : this._(accepted: false);

  const TransferDecision.cancelled()
    : this._(accepted: false, wasCancelled: true);

  final bool accepted;
  final Directory? destinationDirectory;
  final bool wasCancelled;
}

class CompletedTransfer {
  const CompletedTransfer({
    required this.transferId,
    required this.senderId,
    required this.senderName,
    required this.file,
    required this.fileSize,
  });

  final String transferId;
  final String senderId;
  final String senderName;
  final File file;
  final int fileSize;
}

class TransferResult {
  const TransferResult({required this.fileName, required this.savedFileName});

  final String fileName;
  final String savedFileName;
}
