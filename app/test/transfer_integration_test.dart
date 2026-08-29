import 'dart:io';

import 'package:lan_transfer/src/discovery/discovered_device.dart';
import 'package:lan_transfer/src/transfer/transfer_client.dart';
import 'package:lan_transfer/src/transfer/transfer_models.dart';
import 'package:lan_transfer/src/transfer/transfer_server.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

void main() {
  test('streams a file after the receiver accepts it', () async {
    final temporaryRoot = await Directory.systemTemp.createTemp(
      'lan-transfer-test-',
    );
    final receiveDirectory = Directory(
      path.join(temporaryRoot.path, 'receive'),
    );
    final source = File(path.join(temporaryRoot.path, '示例.txt'));
    await source.writeAsString('hello from the local network');

    final server = TransferServer(port: 0);
    await server.start();
    final incomingSubscription = server.incoming.listen(
      (request) => request.accept(receiveDirectory),
    );
    final receiveProgress = server.incomingProgress.firstWhere(
      (progress) => progress.transferredBytes == progress.totalBytes,
    );

    try {
      final receiver = DiscoveredDevice(
        deviceId: 'receiver0123456789',
        displayName: '测试接收机',
        platform: 'windows',
        address: InternetAddress.loopbackIPv4,
        transferPort: server.actualPort!,
        lastSeen: DateTime.now(),
      );

      var sentBytes = -1;
      var totalBytes = -1;
      final result = await const TransferClient().sendFile(
        receiver: receiver,
        senderId: 'sender012345678901',
        senderName: '测试发送机',
        file: source,
        onProgress: (sent, total) {
          sentBytes = sent;
          totalBytes = total;
        },
      );

      final received = File(
        path.join(receiveDirectory.path, result.savedFileName),
      );
      expect(await received.exists(), isTrue);
      expect(await received.readAsString(), 'hello from the local network');
      expect(sentBytes, totalBytes);
      expect(totalBytes, await source.length());
      final receivedProgress = await receiveProgress;
      expect(receivedProgress.fileName, '示例.txt');
      expect(receivedProgress.transferredBytes, await source.length());
    } finally {
      await incomingSubscription.cancel();
      await server.dispose();
      await temporaryRoot.delete(recursive: true);
    }
  });

  test('delivers a text message and confirms it to the sender', () async {
    final server = TransferServer(port: 0);
    await server.start();
    final received = server.messages.first;
    try {
      final receiver = DiscoveredDevice(
        deviceId: 'receiver0123456789',
        displayName: '测试接收机',
        platform: 'windows',
        address: InternetAddress.loopbackIPv4,
        transferPort: server.actualPort!,
        lastSeen: DateTime.now(),
      );
      final messageId = await const TransferClient().sendText(
        receiver: receiver,
        senderId: 'sender012345678901',
        senderName: '测试发送机',
        text: 'https://example.com/docs/intro',
      );
      final message = await received;
      expect(message.messageId, messageId);
      expect(message.senderName, '测试发送机');
      expect(message.text, 'https://example.com/docs/intro');
    } finally {
      await server.dispose();
    }
  });

  test('sender can cancel while waiting for receiver confirmation', () async {
    final temporaryRoot = await Directory.systemTemp.createTemp(
      'lan-transfer-cancel-test-',
    );
    final source = File(path.join(temporaryRoot.path, '等待取消.bin'));
    await source.writeAsBytes(List<int>.filled(1024, 7));
    final server = TransferServer(port: 0);
    await server.start();
    final incoming = server.incoming.first;
    final cancellation = TransferCancellationToken();
    try {
      final receiver = DiscoveredDevice(
        deviceId: 'receiver0123456789',
        displayName: '测试接收机',
        platform: 'windows',
        address: InternetAddress.loopbackIPv4,
        transferPort: server.actualPort!,
        lastSeen: DateTime.now(),
      );
      final sending = const TransferClient().sendFile(
        receiver: receiver,
        senderId: 'sender012345678901',
        senderName: '测试发送机',
        file: source,
        cancellation: cancellation,
      );
      final request = await incoming;
      cancellation.cancel();

      await expectLater(sending, throwsA(isA<TransferCancelledException>()));
      await request.cancelled.timeout(const Duration(seconds: 3));
      expect(request.isResolved, isTrue);
    } finally {
      await server.dispose();
      await temporaryRoot.delete(recursive: true);
    }
  });

  test('sanitizes unsafe file names', () {
    expect(sanitizeFileName(r'..\secret/报告?.txt'), '.._secret_报告_.txt');
    expect(sanitizeFileName('   '), '未命名文件');
  });
}
