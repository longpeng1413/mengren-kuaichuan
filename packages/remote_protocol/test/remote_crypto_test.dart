import 'dart:async';

import 'package:cryptography/cryptography.dart';
import 'package:mengren_remote_protocol/remote_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('relay acknowledgements tolerate slow long-haul links', () async {
    final client = RemoteRelayClient();
    addTearDown(client.dispose);
    expect(client.ackTimeout, RemoteRelayClient.defaultAckTimeout);
    expect(client.ackTimeout, const Duration(seconds: 90));
  });

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

      final decoded = await RemoteCrypto(
        keyDerivation: Pbkdf2(
          macAlgorithm: Hmac.sha256(),
          iterations: 10,
          bits: 256,
        ),
      ).decrypt(envelope: envelope, familySecret: 'correct-family-secret');
      expect(decoded.kind, RemotePayloadKind.text);
      expect(decoded.text, '郑州发来的消息');
      expect(
        envelope.toJson()['protocol'],
        EncryptedRemoteEnvelope.protocolVersion,
      );

      await expectLater(
        crypto.decrypt(envelope: envelope, familySecret: 'wrong-family-secret'),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
    },
  );

  test('file chunks preserve bytes and cancellation is explicit', () async {
    final payload = RemotePayload.fileChunk(
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

    expect(decoded.kind, RemotePayloadKind.fileChunk);
    expect(decoded.chunkIndex, 3);
    expect(decoded.bytes, payload.bytes);
    expect(
      RemotePayload.cancel(transferId: payload.transferId!).kind,
      RemotePayloadKind.cancel,
    );
  });

  test(
    'file metadata accepts APKs up to 200 MiB and rejects oversized chunks',
    () {
      final start = RemotePayload.fileStart(
        transferId: '0123456789abcdef0123456789abcdef',
        fileName: '猛人快传.apk',
        mimeType: 'application/vnd.android.package-archive',
        totalBytes: RemotePayload.maxRemoteFileBytes,
      );
      expect(RemotePayload.tryFromJson(start.toJson()), isNotNull);
      expect(
        () => RemotePayload.fileChunk(
          transferId: '0123456789abcdef0123456789abcdef',
          chunkIndex: 0,
          bytes: List<int>.filled(RemotePayload.remoteFileChunkBytes + 1, 0),
        ),
        throwsFormatException,
      );
      expect(
        () => RemotePayload.fileStart(
          transferId: '0123456789abcdef0123456789abcdef',
          fileName: '太大.zip',
          mimeType: 'application/zip',
          totalBytes: RemotePayload.maxRemoteFileBytes + 1,
        ),
        throwsFormatException,
      );
    },
  );

  test('background crypto worker preserves file chunks', () async {
    final worker = RemoteCryptoWorker();
    addTearDown(worker.dispose);
    var eventLoopTicks = 0;
    final heartbeat = Timer.periodic(
      const Duration(milliseconds: 5),
      (_) => eventLoopTicks += 1,
    );
    addTearDown(heartbeat.cancel);
    final payload = RemotePayload.fileChunk(
      transferId: 'abcdef0123456789abcdef0123456789',
      chunkIndex: 7,
      bytes: List<int>.generate(256 * 1024, (index) => index % 251),
    );

    final envelope = await worker.encrypt(
      payload: payload,
      familySecret: 'worker-family-secret',
      senderId: 'sender-0123456789',
      recipientId: 'recipient-0123456',
    );
    final decoded = await worker.decrypt(
      envelope: envelope,
      familySecret: 'worker-family-secret',
    );

    expect(decoded.kind, RemotePayloadKind.fileChunk);
    expect(decoded.chunkIndex, 7);
    expect(decoded.bytes, payload.bytes);
    expect(eventLoopTicks, greaterThan(0));
  }, timeout: const Timeout(Duration(seconds: 30)));
}
