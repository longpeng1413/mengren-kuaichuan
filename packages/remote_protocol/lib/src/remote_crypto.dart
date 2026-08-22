import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'encrypted_remote_envelope.dart';
import 'remote_payload.dart';

class RemoteCrypto {
  RemoteCrypto({Cipher? cipher, KdfAlgorithm? keyDerivation})
    : _cipher = cipher ?? AesGcm.with256bits(),
      _keyDerivation =
          keyDerivation ??
          Pbkdf2(macAlgorithm: Hmac.sha256(), iterations: 210000, bits: 256);

  final Cipher _cipher;
  final KdfAlgorithm _keyDerivation;
  final Map<String, Future<SecretKey>> _keyCache = {};

  Future<EncryptedRemoteEnvelope> encrypt({
    required RemotePayload payload,
    required String familySecret,
    required String senderId,
    required String recipientId,
    String? messageId,
    DateTime? sentAt,
  }) async {
    _validateFamilySecret(familySecret);
    final envelopeMessageId = messageId ?? randomRemoteId();
    final envelopeSentAt = (sentAt ?? DateTime.now()).toUtc();
    final shell = EncryptedRemoteEnvelope(
      messageId: envelopeMessageId,
      senderId: senderId,
      recipientId: recipientId,
      sentAt: envelopeSentAt,
      nonce: Uint8List(0),
      cipherText: Uint8List(0),
      mac: Uint8List(0),
    );
    final key = await _deriveKey(familySecret, senderId, recipientId);
    final clearText = utf8.encode(jsonEncode(payload.toJson()));
    final secretBox = await _cipher.encrypt(
      clearText,
      secretKey: key,
      aad: shell.authenticatedData,
    );
    return EncryptedRemoteEnvelope(
      messageId: envelopeMessageId,
      senderId: senderId,
      recipientId: recipientId,
      sentAt: envelopeSentAt,
      nonce: Uint8List.fromList(secretBox.nonce),
      cipherText: Uint8List.fromList(secretBox.cipherText),
      mac: Uint8List.fromList(secretBox.mac.bytes),
    );
  }

  Future<RemotePayload> decrypt({
    required EncryptedRemoteEnvelope envelope,
    required String familySecret,
  }) async {
    _validateFamilySecret(familySecret);
    final key = await _deriveKey(
      familySecret,
      envelope.senderId,
      envelope.recipientId,
    );
    final clearText = await _cipher.decrypt(
      SecretBox(
        envelope.cipherText,
        nonce: envelope.nonce,
        mac: Mac(envelope.mac),
      ),
      secretKey: key,
      aad: envelope.authenticatedData,
    );
    final decoded = jsonDecode(utf8.decode(clearText));
    final payload = RemotePayload.tryFromJson(decoded);
    if (payload == null) throw const FormatException('invalid remote payload');
    return payload;
  }

  Future<SecretKey> _deriveKey(
    String familySecret,
    String senderId,
    String recipientId,
  ) {
    final pair = [senderId, recipientId]..sort();
    final cacheKey = '$familySecret\u0000${pair[0]}\u0000${pair[1]}';
    if (!_keyCache.containsKey(cacheKey) && _keyCache.length >= 8) {
      _keyCache.remove(_keyCache.keys.first);
    }
    return _keyCache.putIfAbsent(
      cacheKey,
      () => _keyDerivation.deriveKeyFromPassword(
        password: familySecret,
        nonce: utf8.encode('mengren-remote-v1|${pair[0]}|${pair[1]}'),
      ),
    );
  }
}

void _validateFamilySecret(String value) {
  if (value.length < 12 || value.length > 256) {
    throw const FormatException('family secret must be 12-256 characters');
  }
}

String randomRemoteId() {
  final random = Random.secure();
  return List.generate(
    16,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
}
