import 'dart:convert';
import 'dart:typed_data';

class EncryptedRemoteEnvelope {
  const EncryptedRemoteEnvelope({
    required this.messageId,
    required this.senderId,
    required this.recipientId,
    required this.sentAt,
    required this.nonce,
    required this.cipherText,
    required this.mac,
  });

  static const protocolVersion = 3;
  static const maximumCipherTextBytes = 512 * 1024;

  final String messageId;
  final String senderId;
  final String recipientId;
  final DateTime sentAt;
  final Uint8List nonce;
  final Uint8List cipherText;
  final Uint8List mac;

  List<int> get authenticatedData => utf8.encode(
    '$protocolVersion|$messageId|$senderId|$recipientId|${sentAt.toUtc().toIso8601String()}',
  );

  Map<String, Object?> toJson() => {
    'protocol': protocolVersion,
    'messageId': messageId,
    'senderId': senderId,
    'recipientId': recipientId,
    'sentAt': sentAt.toUtc().toIso8601String(),
    'nonce': base64Encode(nonce),
    'cipherText': base64Encode(cipherText),
    'mac': base64Encode(mac),
  };

  static EncryptedRemoteEnvelope? tryFromJson(Object? value) {
    if (value is! Map<String, dynamic> ||
        value['protocol'] != protocolVersion) {
      return null;
    }
    final messageId = value['messageId'];
    final senderId = value['senderId'];
    final recipientId = value['recipientId'];
    final sentAt = DateTime.tryParse(value['sentAt']?.toString() ?? '');
    if (messageId is! String ||
        !RegExp(r'^[a-f0-9]{32}$').hasMatch(messageId) ||
        !_validDeviceId(senderId) ||
        !_validDeviceId(recipientId) ||
        sentAt == null) {
      return null;
    }
    try {
      final nonce = base64Decode(value['nonce'] as String);
      final cipherText = base64Decode(value['cipherText'] as String);
      final mac = base64Decode(value['mac'] as String);
      if (nonce.length != 12 ||
          mac.length != 16 ||
          cipherText.isEmpty ||
          cipherText.length > maximumCipherTextBytes) {
        return null;
      }
      return EncryptedRemoteEnvelope(
        messageId: messageId,
        senderId: senderId as String,
        recipientId: recipientId as String,
        sentAt: sentAt.toUtc(),
        nonce: nonce,
        cipherText: cipherText,
        mac: mac,
      );
    } on Object {
      return null;
    }
  }
}

bool _validDeviceId(Object? value) =>
    value is String && value.length >= 8 && value.length <= 128;
