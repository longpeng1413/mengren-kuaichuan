import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

enum ChatMessageKind { text, file }

class IncomingTextMessage {
  const IncomingTextMessage({
    required this.messageId,
    required this.senderId,
    required this.senderName,
    required this.text,
    required this.sentAt,
  });

  final String messageId;
  final String senderId;
  final String senderName;
  final String text;
  final DateTime sentAt;
}

class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.peerId,
    required this.peerName,
    required this.senderId,
    required this.senderName,
    required this.kind,
    required this.sentAt,
    required this.isOutgoing,
    this.text,
    this.fileName,
    this.filePath,
    this.contentUri,
    this.displayLocation,
    this.fileSize,
    this.isCache = false,
  });

  final String id;
  final String peerId;
  final String peerName;
  final String senderId;
  final String senderName;
  final ChatMessageKind kind;
  final DateTime sentAt;
  final bool isOutgoing;
  final String? text;
  final String? fileName;
  final String? filePath;
  final String? contentUri;
  final String? displayLocation;
  final int? fileSize;
  final bool isCache;

  Map<String, Object?> toJson() => {
    'id': id,
    'peerId': peerId,
    'peerName': peerName,
    'senderId': senderId,
    'senderName': senderName,
    'kind': kind.name,
    'sentAt': sentAt.toIso8601String(),
    'isOutgoing': isOutgoing,
    'text': text,
    'fileName': fileName,
    'filePath': filePath,
    'contentUri': contentUri,
    'displayLocation': displayLocation,
    'fileSize': fileSize,
    'isCache': isCache,
  };

  static ChatMessage? tryFromJson(Object? value) {
    if (value is! Map<String, dynamic>) return null;
    final id = value['id'];
    final peerId = value['peerId'];
    final peerName = value['peerName'];
    final senderId = value['senderId'];
    final senderName = value['senderName'];
    final kindName = value['kind'];
    final sentAt = DateTime.tryParse(value['sentAt']?.toString() ?? '');
    final isOutgoing = value['isOutgoing'];
    final kind = ChatMessageKind.values.where(
      (candidate) => candidate.name == kindName,
    );
    if (id is! String ||
        peerId is! String ||
        peerName is! String ||
        senderId is! String ||
        senderName is! String ||
        sentAt == null ||
        isOutgoing is! bool ||
        kind.isEmpty) {
      return null;
    }
    return ChatMessage(
      id: id,
      peerId: peerId,
      peerName: peerName,
      senderId: senderId,
      senderName: senderName,
      kind: kind.first,
      sentAt: sentAt,
      isOutgoing: isOutgoing,
      text: value['text'] as String?,
      fileName: value['fileName'] as String?,
      filePath: value['filePath'] as String?,
      contentUri: value['contentUri'] as String?,
      displayLocation: value['displayLocation'] as String?,
      fileSize: value['fileSize'] as int?,
      isCache: value['isCache'] as bool? ?? false,
    );
  }
}

class ChatHistoryStore {
  static const _storageKey = 'chat_history_v1';
  static const _maximumMessages = 1000;
  Future<void> _pendingSave = Future<void>.value();

  Future<List<ChatMessage>> load() async {
    final preferences = await SharedPreferences.getInstance();
    final raw = preferences.getString(_storageKey);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return decoded
          .map(ChatMessage.tryFromJson)
          .whereType<ChatMessage>()
          .toList();
    } on FormatException {
      return const [];
    }
  }

  Future<void> save(Iterable<ChatMessage> messages) async {
    final all = messages.toList()
      ..sort((left, right) => left.sentAt.compareTo(right.sentAt));
    final retained = all.length <= _maximumMessages
        ? all
        : all.sublist(all.length - _maximumMessages);
    final encoded = jsonEncode(
      retained.map((message) => message.toJson()).toList(),
    );
    _pendingSave = _pendingSave.catchError((_) {}).then((_) async {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString(_storageKey, encoded);
    });
    await _pendingSave;
  }
}
