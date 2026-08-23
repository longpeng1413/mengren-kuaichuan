import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:mengren_relay_server/relay_server.dart';
import 'package:mengren_remote_protocol/remote_protocol.dart';
import 'package:test/test.dart';

void main() {
  test(
    'relays only valid encrypted envelopes to an online recipient',
    () async {
      const token = 'test-token-with-at-least-24-characters';
      final server = RelayServer(accessToken: token);
      await server.start(port: 0);
      WebSocket? alice;
      WebSocket? bob;
      try {
        final uri = 'ws://127.0.0.1:${server.port}/v1/relay';
        alice = await WebSocket.connect(
          uri,
          headers: {HttpHeaders.authorizationHeader: 'Bearer $token'},
        );
        bob = await WebSocket.connect(
          uri,
          headers: {HttpHeaders.authorizationHeader: 'Bearer $token'},
        );
        final aliceEvents = alice.asBroadcastStream();
        final bobEvents = bob.asBroadcastStream();
        final aliceHelloAck = _eventOfType(aliceEvents, 'helloAck');
        alice.add(
          jsonEncode({
            'type': 'hello',
            'protocol': EncryptedRemoteEnvelope.protocolVersion,
            'deviceId': 'alice-device-012345',
            'displayName': '郑州手机',
            'platform': 'android',
          }),
        );
        await aliceHelloAck;
        final bobHelloAck = _eventOfType(bobEvents, 'helloAck');
        final alicePeerOnline = _eventOfType(aliceEvents, 'peerOnline');
        bob.add(
          jsonEncode({
            'type': 'hello',
            'protocol': EncryptedRemoteEnvelope.protocolVersion,
            'deviceId': 'bob-device-01234567',
            'displayName': '安徽手机',
            'platform': 'android',
          }),
        );
        await bobHelloAck;
        await alicePeerOnline;

        final envelope = await RemoteCrypto(keyDerivation: _fastKdf()).encrypt(
          payload: RemotePayload.text('到家了吗？'),
          familySecret: 'test-family-secret',
          senderId: 'alice-device-012345',
          recipientId: 'bob-device-01234567',
        );
        final bobRelay = _eventOfType(bobEvents, 'relay');
        final aliceRelayed = _eventOfType(aliceEvents, 'relayed');
        alice.add(jsonEncode({'type': 'relay', 'envelope': envelope.toJson()}));

        final relayed = await bobRelay;
        final received = EncryptedRemoteEnvelope.tryFromJson(
          relayed['envelope'],
        );
        expect(received, isNotNull);
        final payload = await RemoteCrypto(keyDerivation: _fastKdf())
            .decrypt(envelope: received!, familySecret: 'test-family-secret');
        expect(payload.text, '到家了吗？');
        expect((await aliceRelayed)['messageId'], envelope.messageId);
        final aliceDelivered = _eventOfType(aliceEvents, 'delivered');
        bob.add(
          jsonEncode({
            'type': 'receipt',
            'messageId': envelope.messageId,
            'status': 'delivered',
          }),
        );
        expect((await aliceDelivered)['messageId'], envelope.messageId);
      } finally {
        await alice?.close();
        await bob?.close();
        await server.close();
      }
    },
  );

  test('rejects clients with the wrong access token', () async {
    final server = RelayServer(
      accessToken: 'test-token-with-at-least-24-characters',
    );
    await server.start(port: 0);
    try {
      await expectLater(
        WebSocket.connect(
          'ws://127.0.0.1:${server.port}/v1/relay',
          headers: {HttpHeaders.authorizationHeader: 'Bearer wrong'},
        ),
        throwsA(isA<WebSocketException>()),
      );
    } finally {
      await server.close();
    }
  });

  test('remote clients wait for the receiving app delivery receipt', () async {
    const token = 'test-token-with-at-least-24-characters';
    final server = RelayServer(accessToken: token);
    await server.start(port: 0);
    final alice = RemoteRelayClient();
    final bob = RemoteRelayClient();
    try {
      final uri = Uri.parse('ws://127.0.0.1:${server.port}/v1/relay');
      await alice.connect(
        relayUri: uri,
        accessToken: token,
        deviceId: 'alice-device-012345',
        displayName: '郑州手机',
        platform: 'android',
      );
      final aliceSeesBob = alice.peerUpdates.firstWhere(
        (peers) => peers.any((peer) => peer.deviceId == 'bob-device-01234567'),
      );
      await bob.connect(
        relayUri: uri,
        accessToken: token,
        deviceId: 'bob-device-01234567',
        displayName: '安徽手机',
        platform: 'android',
      );
      await aliceSeesBob;

      final incoming = bob.envelopes.first;
      final envelope = await RemoteCrypto(keyDerivation: _fastKdf()).encrypt(
        payload: RemotePayload.link('https://example.com/family'),
        familySecret: 'test-family-secret',
        senderId: 'alice-device-012345',
        recipientId: 'bob-device-01234567',
      );
      final delivery = alice.sendEnvelope(envelope);
      final received = await incoming;
      final payload = await RemoteCrypto(keyDerivation: _fastKdf())
          .decrypt(envelope: received, familySecret: 'test-family-secret');
      await bob.acknowledgeEnvelope(received.messageId);
      await delivery;
      expect(payload.kind, RemotePayloadKind.link);
      expect(payload.text, 'https://example.com/family');
      expect(alice.status, RemoteRelayStatus.connected);
    } finally {
      await alice.dispose();
      await bob.dispose();
      await server.close();
    }
  });

  test('receiving app can reject a message that cannot be decrypted', () async {
    const token = 'test-token-with-at-least-24-characters';
    final server = RelayServer(accessToken: token);
    await server.start(port: 0);
    final alice = RemoteRelayClient();
    final bob = RemoteRelayClient();
    try {
      final uri = Uri.parse('ws://127.0.0.1:${server.port}/v1/relay');
      await alice.connect(
        relayUri: uri,
        accessToken: token,
        deviceId: 'alice-device-012345',
        displayName: '郑州手机',
        platform: 'android',
      );
      await bob.connect(
        relayUri: uri,
        accessToken: token,
        deviceId: 'bob-device-01234567',
        displayName: '安徽手机',
        platform: 'android',
      );
      final incoming = bob.envelopes.first;
      final envelope = await RemoteCrypto(keyDerivation: _fastKdf()).encrypt(
        payload: RemotePayload.text('口令检查'),
        familySecret: 'test-family-secret',
        senderId: 'alice-device-012345',
        recipientId: 'bob-device-01234567',
      );
      final delivery = alice.sendEnvelope(envelope);
      final received = await incoming;
      await bob.acknowledgeEnvelope(
        received.messageId,
        failureCode: 'decrypt_failed',
      );
      await expectLater(
        delivery,
        throwsA(
          isA<RemoteRelayException>().having(
            (error) => error.code,
            'code',
            'decrypt_failed',
          ),
        ),
      );
    } finally {
      await alice.dispose();
      await bob.dispose();
      await server.close();
    }
  });

  test('remote clients relay an arbitrary file lifecycle', () async {
    const token = 'test-token-with-at-least-24-characters';
    const secret = 'test-family-secret';
    final server = RelayServer(accessToken: token);
    await server.start(port: 0);
    final alice = RemoteRelayClient();
    final bob = RemoteRelayClient();
    final crypto = RemoteCrypto(keyDerivation: _fastKdf());
    try {
      final uri = Uri.parse('ws://127.0.0.1:${server.port}/v1/relay');
      await alice.connect(
        relayUri: uri,
        accessToken: token,
        deviceId: 'alice-device-012345',
        displayName: '郑州手机',
        platform: 'android',
      );
      await bob.connect(
        relayUri: uri,
        accessToken: token,
        deviceId: 'bob-device-01234567',
        displayName: '安徽手机',
        platform: 'android',
      );
      const transferId = '0123456789abcdef0123456789abcdef';
      final payloads = [
        RemotePayload.fileStart(
          transferId: transferId,
          fileName: '猛人快传.apk',
          mimeType: 'application/vnd.android.package-archive',
          totalBytes: 4,
        ),
        RemotePayload.fileChunk(
          transferId: transferId,
          chunkIndex: 0,
          bytes: const [1, 2, 3, 4],
        ),
        RemotePayload.fileEnd(transferId: transferId),
      ];
      final receivedKinds = <RemotePayloadKind>[];
      for (final payload in payloads) {
        final incoming = bob.envelopes.first;
        final envelope = await crypto.encrypt(
          payload: payload,
          familySecret: secret,
          senderId: 'alice-device-012345',
          recipientId: 'bob-device-01234567',
        );
        final delivery = alice.sendEnvelope(envelope);
        final received = await incoming;
        final decoded = await crypto.decrypt(
          envelope: received,
          familySecret: secret,
        );
        receivedKinds.add(decoded.kind);
        await bob.acknowledgeEnvelope(received.messageId);
        await delivery;
      }
      expect(receivedKinds, [
        RemotePayloadKind.fileStart,
        RemotePayloadKind.fileChunk,
        RemotePayloadKind.fileEnd,
      ]);
    } finally {
      await alice.dispose();
      await bob.dispose();
      await server.close();
    }
  });

  test('remote client reports an offline recipient without queueing', () async {
    const token = 'test-token-with-at-least-24-characters';
    final server = RelayServer(accessToken: token);
    await server.start(port: 0);
    final alice = RemoteRelayClient();
    try {
      await alice.connect(
        relayUri: Uri.parse('ws://127.0.0.1:${server.port}/v1/relay'),
        accessToken: token,
        deviceId: 'alice-device-012345',
        displayName: '郑州手机',
        platform: 'android',
      );
      final envelope = await RemoteCrypto(keyDerivation: _fastKdf()).encrypt(
        payload: RemotePayload.text('稍后再发'),
        familySecret: 'test-family-secret',
        senderId: 'alice-device-012345',
        recipientId: 'offline-device-0001',
      );
      await expectLater(
        alice.sendEnvelope(envelope),
        throwsA(
          isA<RemoteRelayException>().having(
            (error) => error.code,
            'code',
            'recipient_offline',
          ),
        ),
      );
    } finally {
      await alice.dispose();
      await server.close();
    }
  });
}

Future<Map<String, dynamic>> _eventOfType(
  Stream<dynamic> events,
  String type,
) async {
  return events
      .where((event) => event is String)
      .map((event) => jsonDecode(event as String) as Map<String, dynamic>)
      .firstWhere((event) => event['type'] == type)
      .timeout(const Duration(seconds: 5));
}

KdfAlgorithm _fastKdf() =>
    Pbkdf2(macAlgorithm: Hmac.sha256(), iterations: 10, bits: 256);
