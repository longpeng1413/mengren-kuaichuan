import 'dart:convert';
import 'dart:typed_data';

enum RemotePayloadKind { text, link, imageStart, imageChunk, imageEnd, cancel }

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

  factory RemotePayload.imageStart({
    required String transferId,
    required String fileName,
    required String mimeType,
    required int totalBytes,
  }) {
    if (!_validId(transferId) ||
        fileName.trim().isEmpty ||
        fileName.length > 180 ||
        !mimeType.startsWith('image/') ||
        mimeType.length > 100 ||
        totalBytes < 1 ||
        totalBytes > maxRemoteImageBytes) {
      throw const FormatException('invalid remote image metadata');
    }
    return RemotePayload._(
      kind: RemotePayloadKind.imageStart,
      transferId: transferId,
      fileName: fileName.trim(),
      mimeType: mimeType,
      totalBytes: totalBytes,
    );
  }

  factory RemotePayload.imageChunk({
    required String transferId,
    required int chunkIndex,
    required List<int> bytes,
  }) {
    if (!_validId(transferId) ||
        chunkIndex < 0 ||
        bytes.isEmpty ||
        bytes.length > remoteImageChunkBytes) {
      throw const FormatException('invalid remote image chunk');
    }
    return RemotePayload._(
      kind: RemotePayloadKind.imageChunk,
      transferId: transferId,
      chunkIndex: chunkIndex,
      bytes: Uint8List.fromList(bytes),
    );
  }

  factory RemotePayload.imageEnd({required String transferId}) {
    if (!_validId(transferId)) {
      throw const FormatException('invalid remote transfer id');
    }
    return RemotePayload._(
      kind: RemotePayloadKind.imageEnd,
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

  static const maxRemoteImageBytes = 20 * 1024 * 1024;
  static const remoteImageChunkBytes = 256 * 1024;

  final RemotePayloadKind kind;
  final String? text;
  final String? transferId;
  final String? fileName;
  final String? mimeType;
  final int? totalBytes;
  final int? chunkIndex;
  final Uint8List? bytes;

  bool get isTransferControl => switch (kind) {
    RemotePayloadKind.imageStart ||
    RemotePayloadKind.imageChunk ||
    RemotePayloadKind.imageEnd ||
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
        RemotePayloadKind.imageStart => RemotePayload.imageStart(
          transferId: value['transferId'] as String,
          fileName: value['fileName'] as String,
          mimeType: value['mimeType'] as String,
          totalBytes: value['totalBytes'] as int,
        ),
        RemotePayloadKind.imageChunk => RemotePayload.imageChunk(
          transferId: value['transferId'] as String,
          chunkIndex: value['chunkIndex'] as int,
          bytes: base64Decode(value['bytes'] as String),
        ),
        RemotePayloadKind.imageEnd => RemotePayload.imageEnd(
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
