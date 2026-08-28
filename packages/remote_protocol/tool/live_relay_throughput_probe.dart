import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:mengren_remote_protocol/remote_protocol.dart';

Future<void> main(List<String> arguments) async {
  final relayUri = Uri.parse(
    Platform.environment['MQT_RELAY_URI'] ??
        'wss://relay.meng1314.de5.net/v1/relay',
  );
  final token = Platform.environment['MQT_RELAY_TOKEN'];
  if (token == null || token.isEmpty) {
    stderr.writeln('MQT_RELAY_TOKEN is required.');
    exitCode = 2;
    return;
  }
  final requestedMiB = arguments.isEmpty ? 8 : int.tryParse(arguments.first);
  if (requestedMiB == null || requestedMiB < 1 || requestedMiB > 64) {
    stderr.writeln('Probe size must be between 1 and 64 MiB.');
    exitCode = 2;
    return;
  }
  final requestedWindow = arguments.length < 2
      ? 16
      : int.tryParse(arguments[1]);
  if (requestedWindow == null || requestedWindow < 1 || requestedWindow > 32) {
    stderr.writeln('Probe window must be between 1 and 32 chunks.');
    exitCode = 2;
    return;
  }

  final totalBytes = requestedMiB * 1024 * 1024;
  final suffix = DateTime.now().microsecondsSinceEpoch.toRadixString(16);
  final senderId = 'speed-sender-$suffix';
  final receiverId = 'speed-receiver-$suffix';
  const familySecret = 'isolated-throughput-probe-secret';
  const transferId = '0123456789abcdef0123456789abcdef';
  final window = requestedWindow;
  final sender = RemoteRelayClient();
  final receiver = RemoteRelayClient();
  final senderCrypto = RemoteCrypto();
  final receiverCrypto = RemoteCrypto();
  StreamSubscription<void>? receiverSubscription;
  var nextReceivedChunk = 0;

  try {
    await sender.connect(
      relayUri: relayUri,
      accessToken: token,
      deviceId: senderId,
      displayName: 'Throughput probe sender',
      platform: 'windows',
    );
    final peerVisible = sender.peerUpdates.firstWhere(
      (peers) => peers.any((peer) => peer.deviceId == receiverId),
    );
    await receiver.connect(
      relayUri: relayUri,
      accessToken: token,
      deviceId: receiverId,
      displayName: 'Throughput probe receiver',
      platform: 'windows',
    );
    await peerVisible.timeout(const Duration(seconds: 10));

    receiverSubscription = receiver.envelopes
        .asyncMap((envelope) async {
          final payload = await receiverCrypto.decrypt(
            envelope: envelope,
            familySecret: familySecret,
          );
          if (payload.kind == RemotePayloadKind.fileChunk) {
            if (payload.chunkIndex != nextReceivedChunk) {
              throw StateError('received chunks out of order');
            }
            nextReceivedChunk += 1;
          }
          await receiver.acknowledgeEnvelope(envelope.messageId);
        })
        .listen((_) {});

    Future<void> send(RemotePayload payload) async {
      final envelope = await senderCrypto.encrypt(
        payload: payload,
        familySecret: familySecret,
        senderId: senderId,
        recipientId: receiverId,
      );
      await sender.sendEnvelope(envelope);
    }

    await send(
      RemotePayload.fileStart(
        transferId: transferId,
        fileName: 'throughput-probe.bin',
        mimeType: 'application/octet-stream',
        totalBytes: totalBytes,
      ),
    );

    final sample = Uint8List.fromList(
      List<int>.generate(
        RemotePayload.remoteFileChunkBytes,
        (index) => (index * 31 + 17) & 0xff,
      ),
    );
    final pending = <Future<void>>[];
    var sentBytes = 0;
    var chunkIndex = 0;
    final stopwatch = Stopwatch()..start();
    while (sentBytes < totalBytes) {
      final remaining = totalBytes - sentBytes;
      final bytes = remaining >= sample.length
          ? sample
          : Uint8List.sublistView(sample, 0, remaining);
      final envelope = await senderCrypto.encrypt(
        payload: RemotePayload.fileChunk(
          transferId: transferId,
          chunkIndex: chunkIndex,
          bytes: bytes,
        ),
        familySecret: familySecret,
        senderId: senderId,
        recipientId: receiverId,
      );
      pending.add(sender.sendEnvelope(envelope));
      sentBytes += bytes.length;
      chunkIndex += 1;
      if (pending.length >= window) await pending.removeAt(0);
    }
    await Future.wait(pending);
    stopwatch.stop();
    await send(RemotePayload.fileEnd(transferId: transferId));

    final seconds = stopwatch.elapsedMicroseconds / 1000000;
    final mebibytesPerSecond = totalBytes / 1024 / 1024 / seconds;
    stdout.writeln(
      'probe_bytes=$totalBytes elapsed_ms=${stopwatch.elapsedMilliseconds} '
      'raw_mib_s=${mebibytesPerSecond.toStringAsFixed(2)} '
      'chunks=$chunkIndex window=$window',
    );
  } finally {
    await receiverSubscription?.cancel();
    await sender.dispose();
    await receiver.dispose();
  }
}
