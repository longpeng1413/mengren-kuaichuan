import 'dart:convert';
import 'dart:typed_data';

enum RemotePayloadKind { text, link, fileStart, fileChunk, fileEnd, cancel }

class RemotePayload {
  const RemotePayload._({
    required this.kind,
    this.text,
    this.transferId,
    this.fileName,
    this.mimeType,
    this.totalBytes,
    this.chunkIndex,
    this.bytes,
  });

  factory RemotePayload.text(String text) {
    final value = text.trim();
    if (value.isEmpty || value.length > 16000) {
      throw const FormatException('invalid remote text');
    }
    return RemotePayload._(kind: RemotePayloadKind.text, text: value);
  }

  factory RemotePayload.link(String link) {
    final value = link.trim();
    final uri = Uri.tryParse(value);
    if (value.length > 4096 ||
        uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty) {
      throw const FormatException('invalid remote link');
    }
    return RemotePayload._(kind: RemotePayloadKind.link, text: value);
  }

  factory RemotePayload.fileStart({
    required String transferId,
    required String fileName,
    required String mimeType,
    required int totalBytes,
  }) {
    if (!_validId(transferId) ||
        fileName.trim().isEmpty ||
        fileName.length > 180 ||
        mimeType.trim().isEmpty ||
        mimeType.length > 100 ||
        totalBytes < 1 ||
        totalBytes > maxRemoteFileBytes) {
      throw const FormatException('invalid remote file metadata');
    }
    return RemotePayload._(
      kind: RemotePayloadKind.fileStart,
      transferId: transferId,
      fileName: fileName.trim(),
      mimeType: mimeType,
      totalBytes: totalBytes,
    );
  }

  factory RemotePayload.fileChunk({
    required String transferId,
    required int chunkIndex,
    required List<int> bytes,
  }) {
    if (!_validId(transferId) ||
        chunkIndex < 0 ||
        bytes.isEmpty ||
        bytes.length > remoteFileChunkBytes) {
      throw const FormatException('invalid remote file chunk');
    }
    return RemotePayload._(
      kind: RemotePayloadKind.fileChunk,
      transferId: transferId,
      chunkIndex: chunkIndex,
      bytes: Uint8List.fromList(bytes),
    );
  }

  factory RemotePayload.fileEnd({required String transferId}) {
    if (!_validId(transferId)) {
      throw const FormatException('invalid remote transfer id');
    }
    return RemotePayload._(
      kind: RemotePayloadKind.fileEnd,
      transferId: transferId,
    );
  }

  factory RemotePayload.cancel({required String transferId}) {
    if (!_validId(transferId)) {
      throw const FormatException('invalid remote transfer id');
    }
    return RemotePayload._(
      kind: RemotePayloadKind.cancel,
      transferId: transferId,
    );
  }

  static const maxRemoteFileBytes = 200 * 1024 * 1024;
  static const remoteFileChunkBytes = 256 * 1024;

  final RemotePayloadKind kind;
  final String? text;
  final String? transferId;
  final String? fileName;
  final String? mimeType;
  final int? totalBytes;
  final int? chunkIndex;
  final Uint8List? bytes;

  bool get isTransferControl => switch (kind) {
    RemotePayloadKind.fileStart ||
    RemotePayloadKind.fileChunk ||
    RemotePayloadKind.fileEnd ||
    RemotePayloadKind.cancel => true,
    _ => false,
  };

  Map<String, Object?> toJson() => {
    'kind': kind.name,
    if (text != null) 'text': text,
    if (transferId != null) 'transferId': transferId,
    if (fileName != null) 'fileName': fileName,
    if (mimeType != null) 'mimeType': mimeType,
    if (totalBytes != null) 'totalBytes': totalBytes,
    if (chunkIndex != null) 'chunkIndex': chunkIndex,
    if (bytes != null) 'bytes': base64Encode(bytes!),
  };

  static RemotePayload? tryFromJson(Object? value) {
    if (value is! Map<String, dynamic>) return null;
    final kindName = value['kind'];
    final kinds = RemotePayloadKind.values.where(
      (candidate) => candidate.name == kindName,
    );
    if (kinds.isEmpty) return null;
    try {
      return switch (kinds.first) {
        RemotePayloadKind.text => RemotePayload.text(value['text'] as String),
        RemotePayloadKind.link => RemotePayload.link(value['text'] as String),
        RemotePayloadKind.fileStart => RemotePayload.fileStart(
          transferId: value['transferId'] as String,
          fileName: value['fileName'] as String,
          mimeType: value['mimeType'] as String,
          totalBytes: value['totalBytes'] as int,
        ),
        RemotePayloadKind.fileChunk => RemotePayload.fileChunk(
          transferId: value['transferId'] as String,
          chunkIndex: value['chunkIndex'] as int,
          bytes: base64Decode(value['bytes'] as String),
        ),
        RemotePayloadKind.fileEnd => RemotePayload.fileEnd(
          transferId: value['transferId'] as String,
        ),
        RemotePayloadKind.cancel => RemotePayload.cancel(
          transferId: value['transferId'] as String,
        ),
      };
    } on Object {
      return null;
    }
  }
}

bool _validId(String value) => RegExp(r'^[a-f0-9]{32}$').hasMatch(value);
