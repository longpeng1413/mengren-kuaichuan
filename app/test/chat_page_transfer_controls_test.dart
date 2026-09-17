import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lan_transfer/src/app.dart' show remoteFileDeliveryWindow;
import 'package:lan_transfer/src/chat/chat_message.dart';
import 'package:lan_transfer/src/chat/chat_page.dart';
import 'package:lan_transfer/src/discovery/discovered_device.dart';
import 'package:lan_transfer/src/transfer/transfer_models.dart';
import 'package:lan_transfer/src/transfer/transfer_client.dart';

void main() {
  test('remote file pipeline covers long-haul acknowledgement latency', () {
    expect(remoteFileDeliveryWindow, greaterThanOrEqualTo(16));
  });

  testWidgets('remote receiver can stop an incoming file', (tester) async {
    final messages = ValueNotifier<List<ChatMessage>>(const []);
    final incoming = ValueNotifier<TransferProgressUpdate?>(
      const TransferProgressUpdate(
        transferId: '0123456789abcdef0123456789abcdef',
        peerId: 'remote-device-012345',
        peerName: '远程手机',
        fileName: '测试书籍.pdf',
        transferredBytes: 40 * 1024 * 1024,
        totalBytes: 120 * 1024 * 1024,
      ),
    );
    addTearDown(messages.dispose);
    addTearDown(incoming.dispose);
    String? cancelledTransferId;

    await tester.pumpWidget(
      MaterialApp(
        home: ChatPage(
          device: DiscoveredDevice(
            deviceId: 'remote-device-012345',
            displayName: '远程手机',
            platform: 'android',
            address: InternetAddress.loopbackIPv4,
            transferPort: 0,
            lastSeen: DateTime(2026, 8, 28),
            connectionMode: DeviceConnectionMode.remote,
          ),
          messages: messages,
          incomingProgress: incoming,
          onSendText: (_) async {},
          onSendFiles: (_, _, _) async {},
          onClearConversation: (_) async {},
          onRemoveDevice: () async {},
          onCancelIncomingTransfer: (transferId) async {
            cancelledTransferId = transferId;
            incoming.value = null;
          },
        ),
      ),
    );

    expect(find.text('33%'), findsOneWidget);
    expect(find.textContaining('40.0 MiB / 120.0 MiB'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.stop_circle_outlined));
    await tester.pump();

    expect(cancelledTransferId, '0123456789abcdef0123456789abcdef');
    expect(find.text('33%'), findsNothing);
  });

  testWidgets('Windows connection failure explains firewall setup', (
    tester,
  ) async {
    final messages = ValueNotifier<List<ChatMessage>>(const []);
    final incoming = ValueNotifier<TransferProgressUpdate?>(null);
    addTearDown(messages.dispose);
    addTearDown(incoming.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: ChatPage(
          device: DiscoveredDevice(
            deviceId: 'windows-device-012345',
            displayName: '笔记本',
            platform: 'windows',
            address: InternetAddress('192.168.3.22'),
            transferPort: 53318,
            lastSeen: DateTime(2026, 9, 17),
          ),
          messages: messages,
          incomingProgress: incoming,
          onSendText: (_) async {},
          onSendFiles: (_, _, _) async {
            throw const TransferException('无法连接接收设备：Connection timed out');
          },
          onClearConversation: (_) async {},
          onRemoveDevice: () async {},
        ),
      ),
    );

    await tester.tap(find.byIcon(Icons.attach_file));
    await tester.pump();

    expect(find.textContaining('enable_lan_access.cmd'), findsOneWidget);
  });
}
