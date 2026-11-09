import 'dart:io';
import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart' show kSecondaryMouseButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lan_transfer/src/chat/chat_message.dart';
import 'package:lan_transfer/src/chat/chat_page.dart';
import 'package:lan_transfer/src/chat/chat_quote.dart';
import 'package:lan_transfer/src/chat/chat_thumbnail.dart';
import 'package:lan_transfer/src/chat/clipboard_files.dart';
import 'package:lan_transfer/src/desktop/startup_launch.dart';
import 'package:lan_transfer/src/discovery/discovered_device.dart';
import 'package:lan_transfer/src/transfer/transfer_models.dart';
import 'package:path/path.dart' as p;

class _FakeClipboard implements ClipboardFileSource {
  ClipboardPeek nextPeek = ClipboardPeek.empty;
  List<String> nextFiles = const [];
  final copied = <List<String>>[];

  @override
  bool get canCopyFiles => true;

  @override
  Future<ClipboardPeek> peek() async => nextPeek;

  @override
  Future<ClipboardAttachments> read() async =>
      ClipboardAttachments(paths: nextFiles);

  @override
  Future<void> copyFiles(List<String> paths) async => copied.add(paths);
}

DiscoveredDevice _device(String id, String name, {String platform = 'android'}) =>
    DiscoveredDevice(
      deviceId: id,
      displayName: name,
      platform: platform,
      address: InternetAddress.loopbackIPv4,
      transferPort: 53318,
      lastSeen: DateTime(2026, 11, 9),
    );

ChatMessage _text(String id, String text, {bool outgoing = false}) =>
    ChatMessage(
      id: id,
      peerId: 'phone',
      peerName: '手机',
      senderId: outgoing ? 'computer' : 'phone',
      senderName: outgoing ? '我的电脑' : '华为手机',
      kind: ChatMessageKind.text,
      sentAt: DateTime(2026, 11, 9, 10, 30),
      isOutgoing: outgoing,
      text: text,
    );

ChatMessage _file(String id, String filePath, {int? size}) => ChatMessage(
  id: id,
  peerId: 'phone',
  peerName: '手机',
  senderId: 'phone',
  senderName: '华为手机',
  kind: ChatMessageKind.file,
  sentAt: DateTime(2026, 11, 9, 10, 31),
  isOutgoing: false,
  fileName: p.basename(filePath),
  filePath: filePath,
  displayLocation: filePath,
  fileSize: size,
);

void main() {
  group('quote format', () {
    test('round-trips through plain text that old clients can read', () {
      final quote = quoteFor(_text('a', '明天\n下午三点开会'));
      final text = composeQuotedText(quote, '收到');
      expect(
        text,
        '「华为手机：明天 下午三点开会」\n$quoteSeparator\n收到',
      );
      final parsed = parseQuotedText(text);
      expect(parsed.reply, '收到');
      expect(parsed.quote?.senderName, '华为手机');
      expect(parsed.quote?.snippet, '明天 下午三点开会');
    });

    test('plain text and a quote of a quote stay readable', () {
      expect(parseQuotedText('普通消息').quote, isNull);
      expect(parseQuotedText('普通消息').reply, '普通消息');
      final first = composeQuotedText(quoteFor(_text('a', '原文')), '第一次回复');
      final second = quoteFor(_text('b', first));
      // Only the reply part is quoted again, not the nested quote.
      expect(second.snippet, '第一次回复');
    });

    test('files are quoted by kind and long text is shortened', () {
      expect(quoteSnippetFor(_file('f', r'C:\x\photo.JPG')), '[图片]');
      expect(quoteSnippetFor(_file('f', r'C:\x\a.zip')), '[文件] a.zip');
      final long = quoteSnippetFor(_text('a', '字' * 100));
      expect(long.length, 61);
      expect(long.endsWith('…'), isTrue);
    });

    test('a sender name with the separator character still parses', () {
      final message = ChatMessage(
        id: 'x',
        peerId: 'p',
        peerName: 'p',
        senderId: 'p',
        senderName: '张三：的手机',
        kind: ChatMessageKind.text,
        sentAt: DateTime(2026),
        isOutgoing: false,
        text: '你好」啊',
      );
      final parsed = parseQuotedText(
        composeQuotedText(quoteFor(message), '嗯'),
      );
      expect(parsed.reply, '嗯');
      expect(parsed.quote?.senderName, '张三 的手机');
    });
  });

  group('outgoing cache', () {
    late Directory directory;

    setUp(() {
      directory = Directory.systemTemp.createTempSync('mengren_outgoing_');
    });
    tearDown(() {
      if (directory.existsSync()) directory.deleteSync(recursive: true);
    });

    File write(String name, int bytes, DateTime modified) {
      final file = File(p.join(directory.path, name))
        ..writeAsBytesSync(List.filled(bytes, 1));
      file.setLastModifiedSync(modified);
      return file;
    }

    test('removes old files, crash leftovers and the oldest over the limit',
        () async {
      final now = DateTime(2026, 11, 9, 12);
      final old = write('old.png', 10, now.subtract(const Duration(days: 31)));
      final partial = write('.copy-1.part', 10, now);
      final older = write('a.png', 40, now.subtract(const Duration(days: 3)));
      final newer = write('b.png', 40, now.subtract(const Duration(days: 1)));
      final cache = OutgoingCache.forDirectory(directory);

      final removed = await cache.cleanup(now: now, byteLimit: 50);

      expect(old.existsSync(), isFalse);
      expect(partial.existsSync(), isFalse);
      expect(older.existsSync(), isFalse, reason: 'oldest goes first');
      expect(newer.existsSync(), isTrue);
      expect(removed, 60);
      expect(await cache.size(), 40);
      expect(cache.contains(newer.path), isTrue);
      expect(cache.contains(p.join(directory.parent.path, 'b.png')), isFalse);
    });

    test('clear empties it and createFile never overwrites', () async {
      final cache = OutgoingCache.forDirectory(directory);
      final first = await cache.createFile('粘贴的图片.png');
      first.writeAsStringSync('1');
      final second = await cache.createFile('粘贴的图片.png');
      expect(p.basename(second.path), '粘贴的图片 (1).png');
      expect(await cache.clear(), 1);
      expect(directory.listSync(), isEmpty);
    });

    test('pasted picture names sort by time', () {
      expect(
        pastedImageName(DateTime(2026, 1, 2, 3, 4, 5)),
        '粘贴的图片_20260102_030405.png',
      );
    });
  });

  test('only the login entry starts silently', () {
    expect(isSilentStart(const ['--silent']), isTrue);
    expect(isSilentStart(const []), isFalse);
    expect(silentStartArgument, '--silent');
  });

  group('chat page', () {
    late Directory directory;
    late _FakeClipboard clipboard;
    late ValueNotifier<List<ChatMessage>> messages;
    late ValueNotifier<TransferProgressUpdate?> incoming;
    final sentTexts = <String>[];
    final sentFiles = <List<String>>[];
    final deleted = <String>[];
    final forwarded = <(String, String)>[];
    String? clipboardText;

    setUp(() {
      directory = Directory.systemTemp.createTempSync('mengren_chat_');
      clipboard = _FakeClipboard();
      messages = ValueNotifier(const []);
      incoming = ValueNotifier(null);
      sentTexts.clear();
      sentFiles.clear();
      deleted.clear();
      forwarded.clear();
      clipboardText = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            switch (call.method) {
              case 'Clipboard.setData':
                clipboardText = (call.arguments as Map)['text'] as String;
              case 'Clipboard.getData':
                return {'text': '粘贴的文字'};
              case 'Clipboard.hasStrings':
                return {'value': true};
            }
            return null;
          });
    });
    tearDown(() {
      debugDefaultTargetPlatformOverride = null;
      messages.dispose();
      incoming.dispose();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
      if (directory.existsSync()) directory.deleteSync(recursive: true);
    });

    Future<void> showChat(WidgetTester tester, List<ChatMessage> items) async {
      messages.value = items;
      await tester.pumpWidget(
        MaterialApp(
          home: ChatPage(
            device: _device('phone', '手机'),
            messages: messages,
            incomingProgress: incoming,
            onSendText: (text) async => sentTexts.add(text),
            onSendFiles: (paths, _, _) async =>
                sentFiles.add(paths?.toList() ?? const []),
            onClearConversation: (_) async {},
            onRemoveDevice: () async {},
            onDeleteMessage: (message) async => deleted.add(message.id),
            onForward: (message, target) async {
              forwarded.add((message.id, target.deviceId));
              return '已转发给 ${target.displayName}';
            },
            forwardTargets: () => [
              _device('phone', '手机'),
              _device('laptop', '笔记本', platform: 'windows'),
            ],
            clipboard: clipboard,
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    void windowsTest(String description, WidgetTesterCallback body) {
      testWidgets(description, (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.windows;
        try {
          await body(tester);
        } finally {
          // Restore before testWidgets verifies Flutter's debug invariants.
          debugDefaultTargetPlatformOverride = null;
        }
      });
    }

    Future<void> rightClick(WidgetTester tester, Finder finder) async {
      await tester.tapAt(
        tester.getCenter(finder),
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await tester.pumpAndSettle();
    }

    testWidgets('file bubble is compact and long press offers every action',
        (tester) async {
      final file = File(p.join(directory.path, 'report.zip'))
        ..writeAsBytesSync(List.filled(2048, 7));
      await showChat(tester, [_file('file-1', file.path, size: 2048)]);

      expect(find.text('report.zip'), findsOneWidget);
      expect(find.text('2.0 KiB'), findsOneWidget);
      expect(find.textContaining('保存位置'), findsNothing);
      expect(find.textContaining('点击打开本机文件'), findsNothing);

      await tester.longPress(find.byKey(const ValueKey('bubble_file-1')));
      await tester.pumpAndSettle();
      for (final label in ['复制', '转发', '引用', '删除']) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
      if (Platform.isWindows) {
        expect(find.text('在文件夹中显示'), findsOneWidget);
      }

      await tester.tap(find.text('复制'));
      await tester.pumpAndSettle();
      expect(clipboard.copied, [
        [file.path],
      ]);

      await tester.longPress(find.byKey(const ValueKey('bubble_file-1')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      expect(find.text('删除这条消息？'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, '删除'));
      await tester.pumpAndSettle();
      expect(deleted, ['file-1']);
      expect(file.existsSync(), isTrue, reason: '只删除聊天记录');
    });

    testWidgets('pictures show only a small thumbnail', (tester) async {
      final picture = File(p.join(directory.path, 'IMG_20261109.png'))
        ..writeAsBytesSync(List.filled(64, 0));
      await showChat(tester, [_file('pic', picture.path, size: 64)]);
      expect(find.byType(ChatImageThumbnail), findsOneWidget);
      expect(find.text('IMG_20261109.png'), findsNothing);
      expect(find.text('64 B'), findsNothing);
    });

    testWidgets('forward sends to the chosen other device', (tester) async {
      final file = File(p.join(directory.path, 'a.pdf'))..writeAsStringSync('x');
      await showChat(tester, [_file('file-2', file.path)]);
      await tester.longPress(find.byKey(const ValueKey('bubble_file-2')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('转发'));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('forward_phone')), findsNothing);
      final send = find.widgetWithText(FilledButton, '发送');
      expect(tester.widget<FilledButton>(send).onPressed, isNull);
      await tester.tap(find.byKey(const ValueKey('forward_laptop')));
      await tester.pumpAndSettle();
      await tester.tap(send);
      await tester.pumpAndSettle();

      expect(forwarded, [('file-2', 'laptop')]);
      expect(find.text('已转发给 笔记本'), findsOneWidget);
    });

    windowsTest('quote from the text menu is sent and shown WeChat style', (
      tester,
    ) async {
      await showChat(tester, [_text('t1', '明天开会')]);
      await rightClick(tester, find.byType(SelectableText));
      for (final label in ['复制', '转发', '引用', '删除']) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
      await tester.tap(find.text('引用'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('quote_bar')), findsOneWidget);
      expect(find.text('引用 华为手机：明天开会'), findsOneWidget);

      await tester.enterText(find.byType(TextField), '收到');
      await tester.tap(find.byIcon(Icons.send));
      await tester.pumpAndSettle();
      expect(sentTexts, ['「华为手机：明天开会」\n$quoteSeparator\n收到']);
      expect(find.byKey(const Key('quote_bar')), findsNothing);

      messages.value = [
        _text('t1', '明天开会'),
        _text('t2', sentTexts.single, outgoing: true),
      ];
      await tester.pumpAndSettle();
      expect(find.text('收到'), findsOneWidget);
      expect(find.byKey(const Key('quoted_block')), findsOneWidget);

      // 复制 on a reply copies only the reply.
      await rightClick(tester, find.byType(SelectableText).last);
      await tester.tap(find.text('复制'));
      await tester.pumpAndSettle();
      expect(clipboardText, '收到');
    });

    windowsTest('input menu offers 粘贴图片 and sends after confirming', (
      tester,
    ) async {
      final picture = File(p.join(directory.path, '截图.png'))
        ..writeAsBytesSync(List.filled(16, 0));
      clipboard
        ..nextPeek = const ClipboardPeek(image: true)
        ..nextFiles = [picture.path];
      await showChat(tester, const []);
      await rightClick(tester, find.byType(TextField));
      expect(find.text('粘贴图片'), findsOneWidget);
      await tester.tap(find.text('粘贴图片'));
      await tester.pumpAndSettle();
      expect(find.text('发送给 手机'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, '发送'));
      await tester.pumpAndSettle();
      expect(sentFiles, [
        [picture.path],
      ]);
    });

    windowsTest('Ctrl+V offers copied files; text still pastes as text', (
      tester,
    ) async {
      final archive = File(p.join(directory.path, '资料.zip'))
        ..writeAsStringSync('zip');
      clipboard
        ..nextPeek = const ClipboardPeek(files: true)
        ..nextFiles = [archive.path];
      await showChat(tester, const []);
      await tester.tap(find.byType(TextField));
      await tester.pumpAndSettle();

      Future<void> pressCtrlV() async {
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pumpAndSettle();
      }

      if (Platform.isWindows) {
        await pressCtrlV();
        expect(find.text('资料.zip'), findsOneWidget);
        await tester.tap(find.widgetWithText(TextButton, '取消'));
        await tester.pumpAndSettle();
        expect(sentFiles, isEmpty);
        expect(archive.existsSync(), isTrue, reason: '原文件不能被删掉');
      }

      clipboard.nextPeek = const ClipboardPeek(text: true);
      await pressCtrlV();
      expect(find.text('粘贴的文字'), findsOneWidget);
    });
  });
}
