import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lan_transfer/src/chat/chat_message.dart';
import 'package:lan_transfer/src/chat/chat_page.dart';
import 'package:lan_transfer/src/chat/image_viewer.dart';
import 'package:lan_transfer/src/discovery/discovered_device.dart';
import 'package:lan_transfer/src/settings/app_settings.dart';
import 'package:lan_transfer/src/settings/settings_page.dart';
import 'package:lan_transfer/src/transfer/transfer_models.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory directory;
  late ValueNotifier<List<ChatMessage>> messages;
  late ValueNotifier<TransferProgressUpdate?> incoming;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('mengren_viewer_');
    messages = ValueNotifier(const []);
    incoming = ValueNotifier(null);
  });
  tearDown(() {
    messages.dispose();
    incoming.dispose();
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });

  ChatMessage picture(String id, String name) {
    final file = File(p.join(directory.path, name))..writeAsBytesSync([0]);
    return ChatMessage(
      id: id,
      peerId: 'phone',
      peerName: '手机',
      senderId: 'phone',
      senderName: '华为手机',
      kind: ChatMessageKind.file,
      sentAt: DateTime.now(),
      isOutgoing: false,
      fileName: name,
      filePath: file.path,
    );
  }

  Future<void> showChat(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ChatPage(
          device: DiscoveredDevice(
            deviceId: 'phone',
            displayName: '手机',
            platform: 'android',
            address: InternetAddress.loopbackIPv4,
            transferPort: 53318,
            lastSeen: DateTime(2026, 11, 11),
          ),
          messages: messages,
          incomingProgress: incoming,
          onSendText: (_) async {},
          onSendFiles: (_, _, _) async {},
          onClearConversation: (_) async {},
          onRemoveDevice: () async {},
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  // The viewer shows a spinner while decoding, so settle with fixed pumps.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  testWidgets('tapping a picture opens one in-app viewer, not one per tap', (
    tester,
  ) async {
    messages.value = [picture('a', 'a.png')];
    await showChat(tester);

    // Two quick taps before the viewer appears.
    await tester.tap(find.byKey(const ValueKey('bubble_a')));
    await tester.tap(find.byKey(const ValueKey('bubble_a')), warnIfMissed: false);
    await settle(tester);
    expect(find.byType(ChatImageViewer), findsOneWidget);
    expect(find.byKey(const Key('viewer_counter')), findsOneWidget);
    expect(find.text('1 / 1'), findsNothing, reason: '只有一张时不显示计数');

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);
    expect(find.byType(ChatImageViewer), findsNothing);

    // After closing, the same picture opens again (once).
    await tester.tap(find.byKey(const ValueKey('bubble_a')));
    await settle(tester);
    expect(find.byType(ChatImageViewer), findsOneWidget);
  });

  testWidgets('arrow keys browse the conversation pictures', (tester) async {
    messages.value = [
      picture('a', 'a.png'),
      picture('b', 'b.jpg'),
      // A picture whose file is gone is left out of the viewer.
      ChatMessage(
        id: 'gone',
        peerId: 'phone',
        peerName: '手机',
        senderId: 'phone',
        senderName: '华为手机',
        kind: ChatMessageKind.file,
        sentAt: DateTime.now(),
        isOutgoing: false,
        fileName: 'gone.png',
        filePath: p.join(directory.path, 'gone.png'),
      ),
    ];
    await showChat(tester);
    await tester.tap(find.byKey(const ValueKey('bubble_a')));
    await settle(tester);
    expect(find.text('1 / 2'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await settle(tester);
    expect(find.text('2 / 2'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await settle(tester);
    expect(find.text('2 / 2'), findsOneWidget, reason: '最后一张不再往后');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await settle(tester);
    expect(find.text('1 / 2'), findsOneWidget);
  });

  testWidgets('settings shows version, author and project link at the top', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SettingsPage(
          initialSettings: const AppSettings(),
          saveSettings: (_) async {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    // Visible without scrolling, above the first group.
    expect(find.byKey(const Key('about_author')).hitTestable(), findsOneWidget);
    expect(find.byKey(const Key('about_github')).hitTestable(), findsOneWidget);
    expect(
      tester.getTopLeft(find.byKey(const Key('about_header'))).dy,
      lessThan(tester.getTopLeft(find.text('外观')).dy),
    );
  });
}
