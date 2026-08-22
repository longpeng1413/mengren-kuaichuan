import 'package:cryptography/cryptography.dart';
import 'package:mengren_remote_protocol/remote_protocol.dart';
import 'package:test/test.dart';

void main() {
  final crypto = RemoteCrypto(
    keyDerivation: Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: 10,
      bits: 256,
    ),
  );

  test(
    'text is authenticated and decrypts only with the family secret',
    () async {
      final envelope = await crypto.encrypt(
        payload: RemotePayload.text('郑州发来的消息'),
        familySecret: 'correct-family-secret',
        senderId: 'sender-0123456789',
        recipientId: 'recipient-0123456',
        messageId: '0123456789abcdef0123456789abcdef',
        sentAt: DateTime.utc(2026, 8, 23),
      );

      final decoded = await crypto.decrypt(
        envelope: envelope,
        familySecret: 'correct-family-secret',
      );
      expect(decoded.kind, RemotePayloadKind.text);
      expect(decoded.text, '郑州发来的消息');

      await expectLater(
        crypto.decrypt(envelope: envelope, familySecret: 'wrong-family-secret'),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
    },
  );

  test('image chunks preserve bytes and cancellation is explicit', () async {
    final payload = RemotePayload.imageChunk(
      transferId: 'fedcba9876543210fedcba9876543210',
      chunkIndex: 3,
      bytes: List<int>.generate(1024, (index) => index % 251),
    );
    final envelope = await crypto.encrypt(
      payload: payload,
      familySecret: 'correct-family-secret',
      senderId: 'sender-0123456789',
      recipientId: 'recipient-0123456',
    );
    final decoded = await crypto.decrypt(
      envelope: envelope,
      familySecret: 'correct-family-secret',
    );

    expect(decoded.kind, RemotePayloadKind.imageChunk);
    expect(decoded.chunkIndex, 3);
    expect(decoded.bytes, payload.bytes);
    expect(
      RemotePayload.cancel(transferId: payload.transferId!).kind,
      RemotePayloadKind.cancel,
    );
  });

  test('envelope parser rejects tampered metadata and oversized chunks', () {
    final start = RemotePayload.imageStart(
      transferId: '0123456789abcdef0123456789abcdef',
      fileName: '照片.jpg',
      mimeType: 'image/jpeg',
      totalBytes: 1024,
    );
    expect(RemotePayload.tryFromJson(start.toJson()), isNotNull);
    expect(
      () => RemotePayload.imageChunk(
        transferId: '0123456789abcdef0123456789abcdef',
        chunkIndex: 0,
        bytes: List<int>.filled(RemotePayload.remoteImageChunkBytes + 1, 0),
      ),
      throwsFormatException,
    );
  });
}
