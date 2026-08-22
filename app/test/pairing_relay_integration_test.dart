import 'dart:async';
import 'dart:io';

import 'package:lan_transfer/src/device/device_identity.dart';
import 'package:lan_transfer/src/pairing/pairing_endpoint.dart';
import 'package:lan_transfer/src/pairing/pairing_relay.dart';
import 'package:lan_transfer/src/transfer/transfer_server.dart';
import 'package:lan_transfer/src/transfer/transfer_models.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

void main() {
  test('simultaneous reconnects converge on the same paired channel', () async {
    const computer = DeviceIdentity(
      deviceId: 'computer-concurrent-0123456789',
      displayName: '并发测试电脑',
      platform: 'windows',
    );
    const phone = DeviceIdentity(
      deviceId: 'phone-concurrent-0123456789012',
      displayName: '并发测试手机',
      platform: 'android',
    );
    final computerRelay = PairingRelay(
      identity: computer,
      pairingCode: '12345678',
    );
    final phoneRelay = PairingRelay(identity: phone, pairingCode: '87654321');
    final computerServer = TransferServer(port: 0, pairingRelay: computerRelay);
    final phoneServer = TransferServer(port: 0, pairingRelay: phoneRelay);
    try {
      await Future.wait([computerServer.start(), phoneServer.start()]);
      final computerMessage = computerRelay.messages.first;
      final phoneMessage = phoneRelay.messages.first;

      await Future.wait([
        computerRelay.connect(
          PairingEndpoint(
            host: InternetAddress.loopbackIPv4.address,
            port: phoneServer.actualPort!,
            code: '87654321',
          ),
        ),
        phoneRelay.connect(
          PairingEndpoint(
            host: InternetAddress.loopbackIPv4.address,
            port: computerServer.actualPort!,
            code: '12345678',
          ),
        ),
      ]);
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(computerRelay.hasSession(phone.deviceId), isTrue);
      expect(phoneRelay.hasSession(computer.deviceId), isTrue);
      await Future.wait([
        computerRelay.sendText(receiverId: phone.deviceId, text: '电脑仍在线'),
        phoneRelay.sendText(receiverId: computer.deviceId, text: '手机仍在线'),
      ]);
      expect((await computerMessage).text, '手机仍在线');
      expect((await phoneMessage).text, '电脑仍在线');
    } finally {
      await computerServer.dispose();
      await phoneServer.dispose();
    }
  });

  test('paired relay transfers files in both directions', () async {
    final temporaryRoot = await Directory.systemTemp.createTemp(
      'mengren-pairing-test-',
    );
    final computerReceive = Directory(
      path.join(temporaryRoot.path, 'computer-receive'),
    );
    final phoneReceive = Directory(
      path.join(temporaryRoot.path, 'phone-receive'),
    );
    final fromComputer = File(path.join(temporaryRoot.path, '电脑文件.txt'));
    final fromPhone = File(path.join(temporaryRoot.path, '手机文件.txt'));
    final largeVideo = File(path.join(temporaryRoot.path, '大视频.bin'));
    await fromComputer.writeAsString('from computer through paired relay');
    await fromPhone.writeAsString('from phone through paired relay');
    final largeHandle = await largeVideo.open(mode: FileMode.write);
    await largeHandle.truncate(8 * 1024 * 1024);
    await largeHandle.close();

    const computer = DeviceIdentity(
      deviceId: 'computer0123456789012345678901',
      displayName: '测试电脑',
      platform: 'windows',
    );
    const phone = DeviceIdentity(
      deviceId: 'phone01234567890123456789012345',
      displayName: '测试手机',
      platform: 'android',
    );
    final computerRelay = PairingRelay(
      identity: computer,
      pairingCode: '12345678',
    );
    final phoneRelay = PairingRelay(identity: phone, pairingCode: '87654321');
    final computerServer = TransferServer(port: 0, pairingRelay: computerRelay);

    final computerIncoming = computerRelay.incoming.listen(
      (request) => request.accept(computerReceive),
    );
    final phoneIncoming = phoneRelay.incoming.listen(
      (request) => request.accept(phoneReceive),
    );
    final computerSawPhone = computerRelay.devices.firstWhere(
      (devices) => devices.any((device) => device.deviceId == phone.deviceId),
    );
    final phoneSawComputer = phoneRelay.devices.firstWhere(
      (devices) =>
          devices.any((device) => device.deviceId == computer.deviceId),
    );
    final computerReceivedMessage = computerRelay.messages.first;
    final phoneReceivedMessage = phoneRelay.messages.first;
    final computerReceiveProgress = computerRelay.incomingProgress.firstWhere(
      (progress) => progress.transferredBytes == progress.totalBytes,
    );
    final phoneReceiveProgress = phoneRelay.incomingProgress.firstWhere(
      (progress) => progress.transferredBytes == progress.totalBytes,
    );

    try {
      await computerServer.start();
      await phoneRelay.connect(
        PairingEndpoint(
          host: InternetAddress.loopbackIPv4.address,
          port: computerServer.actualPort!,
          code: '12345678',
        ),
      );
      await Future.wait([computerSawPhone, phoneSawComputer]);

      var phoneFileProgress = -1;
      var phoneFileTotal = -1;
      await phoneRelay.sendFile(
        receiverId: computer.deviceId,
        file: fromPhone,
        onProgress: (sent, total) {
          phoneFileProgress = sent;
          phoneFileTotal = total;
        },
      );
      await computerRelay.sendFile(
        receiverId: phone.deviceId,
        file: fromComputer,
      );
      await phoneRelay.sendText(receiverId: computer.deviceId, text: '手机发来的文字');
      await computerRelay.sendText(
        receiverId: phone.deviceId,
        text: 'https://example.com',
      );

      final largeReceiveProgress = computerRelay.incomingProgress.firstWhere(
        (progress) =>
            progress.fileName == '大视频.bin' &&
            progress.transferredBytes == progress.totalBytes,
      );
      var eventLoopTicks = 0;
      final heartbeat = Timer.periodic(
        const Duration(milliseconds: 1),
        (_) => eventLoopTicks++,
      );
      await phoneRelay.sendFile(
        receiverId: computer.deviceId,
        file: largeVideo,
      );
      heartbeat.cancel();

      expect(
        await File(path.join(computerReceive.path, '手机文件.txt')).readAsString(),
        'from phone through paired relay',
      );
      expect(
        await File(path.join(phoneReceive.path, '电脑文件.txt')).readAsString(),
        'from computer through paired relay',
      );
      expect(phoneFileProgress, phoneFileTotal);
      expect(phoneFileTotal, await fromPhone.length());
      expect(
        (await computerReceiveProgress).transferredBytes,
        await fromPhone.length(),
      );
      expect(
        (await phoneReceiveProgress).transferredBytes,
        await fromComputer.length(),
      );
      expect((await computerReceivedMessage).text, '手机发来的文字');
      expect((await phoneReceivedMessage).text, 'https://example.com');
      expect((await largeReceiveProgress).transferredBytes, 8 * 1024 * 1024);
      expect(
        await File(path.join(computerReceive.path, '大视频.bin')).length(),
        8 * 1024 * 1024,
      );
      expect(eventLoopTicks, greaterThan(0));
    } finally {
      await computerIncoming.cancel();
      await phoneIncoming.cancel();
      await computerServer.dispose();
      await phoneRelay.dispose();
      await temporaryRoot.delete(recursive: true);
    }
  });

  test('paired sender can cancel while waiting for confirmation', () async {
    final temporaryRoot = await Directory.systemTemp.createTemp(
      'mengren-paired-cancel-',
    );
    final source = File(path.join(temporaryRoot.path, '取消测试.bin'));
    await source.writeAsBytes(List<int>.filled(1024, 3));
    const computer = DeviceIdentity(
      deviceId: 'computer-cancel-0123456789012',
      displayName: '取消测试电脑',
      platform: 'windows',
    );
    const phone = DeviceIdentity(
      deviceId: 'phone-cancel-012345678901234',
      displayName: '取消测试手机',
      platform: 'android',
    );
    final computerRelay = PairingRelay(
      identity: computer,
      pairingCode: '12345678',
    );
    final phoneRelay = PairingRelay(identity: phone, pairingCode: '87654321');
    final computerServer = TransferServer(port: 0, pairingRelay: computerRelay);
    final cancellation = TransferCancellationToken();
    try {
      await computerServer.start();
      await phoneRelay.connect(
        PairingEndpoint(
          host: InternetAddress.loopbackIPv4.address,
          port: computerServer.actualPort!,
          code: '12345678',
        ),
      );
      final incoming = computerRelay.incoming.first;
      final sending = phoneRelay.sendFile(
        receiverId: computer.deviceId,
        file: source,
        cancellation: cancellation,
      );
      final request = await incoming;
      cancellation.cancel();

      await expectLater(sending, throwsA(isA<TransferCancelledException>()));
      await request.cancelled.timeout(const Duration(seconds: 3));
      expect(request.isResolved, isTrue);
    } finally {
      await computerServer.dispose();
      await phoneRelay.dispose();
      await temporaryRoot.delete(recursive: true);
    }
  });
}
