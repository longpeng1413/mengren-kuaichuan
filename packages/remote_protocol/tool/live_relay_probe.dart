import 'dart:async';
import 'dart:io';

import 'package:mengren_remote_protocol/remote_protocol.dart';

Future<void> main() async {
  final relayUriText = Platform.environment['MQT_RELAY_URI'];
  if (relayUriText == null || relayUriText.isEmpty) {
    stderr.writeln('MQT_RELAY_URI is required.');
    exitCode = 2;
    return;
  }
  final relayUri = Uri.parse(relayUriText);
  final token = Platform.environment['MQT_RELAY_TOKEN'];
  if (token == null || token.isEmpty) {
    stderr.writeln('MQT_RELAY_TOKEN is required.');
    exitCode = 2;
    return;
  }

  final suffix = DateTime.now().microsecondsSinceEpoch.toRadixString(16);
  final senderId = 'probe-sender-$suffix';
  final receiverId = 'probe-receiver-$suffix';
  const familySecret = 'probe-family-secret-not-used-by-the-app';
  final sender = RemoteRelayClient();
  final receiver = RemoteRelayClient();
  final stopwatch = Stopwatch()..start();

  try {
    await sender.connect(
      relayUri: relayUri,
      accessToken: token,
      deviceId: senderId,
      displayName: 'Relay probe sender',
      platform: 'windows',
    );
    stdout.writeln('sender connected (${stopwatch.elapsedMilliseconds} ms)');

    final peerVisible = sender.peerUpdates.firstWhere(
      (peers) => peers.any((peer) => peer.deviceId == receiverId),
    );
    await receiver.connect(
      relayUri: relayUri,
      accessToken: token,
      deviceId: receiverId,
      displayName: 'Relay probe receiver',
      platform: 'android',
    );
    await peerVisible.timeout(const Duration(seconds: 10));
    stdout.writeln('receiver connected and discovered');

    final incoming = receiver.envelopes.first.timeout(
      const Duration(seconds: 20),
    );
    final envelope = await RemoteCrypto().encrypt(
      payload: RemotePayload.text('relay probe'),
      familySecret: familySecret,
      senderId: senderId,
      recipientId: receiverId,
    );
    stdout.writeln('encrypted (${stopwatch.elapsedMilliseconds} ms)');
    final delivery = sender.sendEnvelope(envelope);
    final received = await incoming;
    stdout.writeln(
      'receiver got envelope (${stopwatch.elapsedMilliseconds} ms)',
    );
    final payload = await RemoteCrypto().decrypt(
      envelope: received,
      familySecret: familySecret,
    );
    if (payload.kind != RemotePayloadKind.text ||
        payload.text != 'relay probe') {
      throw StateError('decrypted payload does not match');
    }
    await receiver.acknowledgeEnvelope(received.messageId);
    await delivery;
    stdout.writeln(
      'receiver decrypted and confirmed payload '
      '(${stopwatch.elapsedMilliseconds} ms)',
    );

    const transferId = '0123456789abcdef0123456789abcdef';
    final filePayloads = <RemotePayload>[
      RemotePayload.fileStart(
        transferId: transferId,
        fileName: 'relay-probe.apk',
        mimeType: 'application/vnd.android.package-archive',
        totalBytes: 4,
      ),
      RemotePayload.fileChunk(
        transferId: transferId,
        chunkIndex: 0,
        bytes: const [0x50, 0x4b, 0x03, 0x04],
      ),
      RemotePayload.fileEnd(transferId: transferId),
    ];
    for (final expected in filePayloads) {
      final incomingFileEnvelope = receiver.envelopes.first.timeout(
        const Duration(seconds: 20),
      );
      final encrypted = await RemoteCrypto().encrypt(
        payload: expected,
        familySecret: familySecret,
        senderId: senderId,
        recipientId: receiverId,
      );
      final fileDelivery = sender.sendEnvelope(encrypted);
      final fileEnvelope = await incomingFileEnvelope;
      final actual = await RemoteCrypto().decrypt(
        envelope: fileEnvelope,
        familySecret: familySecret,
      );
      if (actual.kind != expected.kind || actual.transferId != transferId) {
        throw StateError('relayed file payload does not match');
      }
      await receiver.acknowledgeEnvelope(fileEnvelope.messageId);
      await fileDelivery;
    }
    stdout.writeln(
      'receiver confirmed APK lifecycle '
      '(${stopwatch.elapsedMilliseconds} ms)',
    );
  } finally {
    await sender.dispose();
    await receiver.dispose();
  }
}
