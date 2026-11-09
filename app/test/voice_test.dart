import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lan_transfer/src/chat/chat_message.dart';
import 'package:lan_transfer/src/chat/chat_page.dart';
import 'package:lan_transfer/src/chat/chat_quote.dart';
import 'package:lan_transfer/src/discovery/discovered_device.dart';
import 'package:lan_transfer/src/transfer/transfer_models.dart';
import 'package:lan_transfer/src/voice/speech_service.dart';
import 'package:lan_transfer/src/voice/voice_audio.dart';
import 'package:lan_transfer/src/voice/voice_store.dart';
import 'package:path/path.dart' as p;

class _FakeSpeech implements SpeechEngine {
  _FakeSpeech({this.installed = true});

  bool installed;
  final transcribed = <String>[];

  @override
  Future<bool> isModelInstalled() async => installed;

  @override
  Future<void> downloadModel({
    void Function(int received, int total)? onProgress,
    SpeechDownloadToken? token,
  }) async {}

  @override
  Future<String> transcribe(String wavPath) async {
    transcribed.add(wavPath);
    return '今晚七点开会';
  }
}

class _FakeRecorder implements VoiceRecorder {
  @override
  Future<bool> ensurePermission() async => true;

  @override
  Future<void> start(String path) async {}

  @override
  Future<String?> stop() async => null;

  @override
  Future<void> cancel() async {}
}

void main() {
  group('voice file names', () {
    test('carry the length and survive a receiver renaming them', () {
      final name = voiceFileName(DateTime(2026, 11, 9, 10, 30, 12), 12);
      expect(name, '语音消息_20261109_103012_12s.wav');
      expect(voiceSecondsFromName(name), 12);
      expect(voiceSecondsFromName(r'C:\x\语音消息_20261109_103012_12s (1).wav'), 12);
      expect(isVoiceFileName('录音.wav'), isFalse);
      expect(isVoiceFileName('语音消息_20261109_103012_12s.mp3'), isFalse);
      expect(voiceFileName(DateTime(2026), 200), endsWith('_60s.wav'));
    });

    test('quotes show [语音] and the length', () {
      final message = ChatMessage(
        id: 'v',
        peerId: 'p',
        peerName: 'p',
        senderId: 'p',
        senderName: '华为手机',
        kind: ChatMessageKind.file,
        sentAt: DateTime(2026),
        isOutgoing: false,
        fileName: '语音消息_20261109_103012_8s.wav',
      );
      expect(quoteSnippetFor(message), '[语音] 8″');
    });

    test('transcripts are stored and old records still load', () {
      final message = ChatMessage(
        id: 'v',
        peerId: 'p',
        peerName: 'p',
        senderId: 'p',
        senderName: 'p',
        kind: ChatMessageKind.file,
        sentAt: DateTime(2026),
        isOutgoing: false,
      ).withTranscript('你好');
      final json = jsonDecode(jsonEncode(message.toJson()));
      expect(ChatMessage.tryFromJson(json)!.transcript, '你好');
      (json as Map<String, dynamic>).remove('transcript');
      expect(ChatMessage.tryFromJson(json)!.transcript, isNull);
      expect(message.withDelivery(null).transcript, '你好');
    });
  });

  group('voice store', () {
    late Directory directory;

    setUp(() => directory = Directory.systemTemp.createTempSync('mengren_v_'));
    tearDown(() {
      if (directory.existsSync()) directory.deleteSync(recursive: true);
    });

    test('names finished recordings and adopts received ones', () async {
      final store = VoiceStore.forDirectory(directory);
      final startedAt = DateTime(2026, 11, 9, 8, 0, 1);
      final recording = await store.newRecordingFile(startedAt);
      await recording.writeAsBytes([1, 2, 3]);
      final voice = await store.finishRecording(recording, startedAt, 5);
      expect(p.basename(voice.path), '语音消息_20261109_080001_5s.wav');
      expect(store.contains(voice.path), isTrue);

      final download = Directory.systemTemp.createTempSync('mengren_dl_');
      addTearDown(() => download.deleteSync(recursive: true));
      final received = File(p.join(download.path, p.basename(voice.path)))
        ..writeAsBytesSync([4]);
      final adopted = await store.adoptReceived(received);
      expect(p.basename(adopted.path), '语音消息_20261109_080001_5s (1).wav');
      expect(received.existsSync(), isFalse);
    });

    test('cleans crash leftovers, old voice and the oldest over the cap',
        () async {
      final now = DateTime(2026, 11, 9, 12);
      File write(String name, int bytes, Duration age) {
        final file = File(p.join(directory.path, name))
          ..writeAsBytesSync(List.filled(bytes, 1));
        file.setLastModifiedSync(now.subtract(age));
        return file;
      }

      final leftover = write('rec_1.wav.recording', 10, Duration.zero);
      final old = write('a.wav', 10, const Duration(days: 31));
      final older = write('b.wav', 40, const Duration(days: 2));
      final newer = write('c.wav', 40, const Duration(days: 1));
      final store = VoiceStore.forDirectory(directory);
      expect(await store.cleanup(now: now, byteLimit: 50), 60);
      expect(leftover.existsSync(), isFalse);
      expect(old.existsSync(), isFalse);
      expect(older.existsSync(), isFalse);
      expect(newer.existsSync(), isTrue);
      expect(await store.clear(), 40);
    });
  });

  group('speech model download', () {
    late Directory directory;
    late HttpServer server;
    final content = {
      'model.int8.onnx': utf8.encode('模型' * 4000),
      'tokens.txt': utf8.encode('tokens'),
    };
    var corrupt = false;
    final ranges = <String?>[];

    List<SpeechModelFile> files() => [
      for (final entry in content.entries)
        SpeechModelFile(
          entry.key,
          entry.value.length,
          sha256.convert(entry.value).toString(),
        ),
    ];

    HttpOverrides? previousOverrides;

    setUp(() async {
      // The widget-test binding answers every HttpClient request with 400;
      // these tests talk to a real local server.
      previousOverrides = HttpOverrides.current;
      HttpOverrides.global = null;
      directory = Directory.systemTemp.createTempSync('mengren_asr_');
      corrupt = false;
      ranges.clear();
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        final name = request.uri.pathSegments.last;
        List<int> bytes = content[name]!;
        if (corrupt) bytes = List<int>.filled(bytes.length, 0);
        final range = request.headers.value(HttpHeaders.rangeHeader);
        ranges.add(range);
        if (range != null) {
          final start = int.parse(range.substring(6, range.length - 1));
          request.response.statusCode = HttpStatus.partialContent;
          request.response.add(bytes.sublist(start));
        } else {
          request.response.add(bytes);
        }
        await request.response.close();
      });
    });
    tearDown(() async {
      HttpOverrides.global = previousOverrides;
      await server.close(force: true);
      if (directory.existsSync()) directory.deleteSync(recursive: true);
    });

    SpeechModel model() => SpeechModel.forTesting(
      directory,
      client: () async => HttpClient(),
      baseUrl: Uri.parse('http://127.0.0.1:${server.port}/files/'),
      files: files(),
    );

    test('downloads, verifies and reports progress', () async {
      final speech = model();
      expect(await speech.isInstalled(), isFalse);
      var last = 0;
      await speech.download(onProgress: (received, total) => last = received);
      expect(await speech.isInstalled(), isTrue);
      expect(last, content.values.fold<int>(0, (s, v) => s + v.length));
      expect(await speech.size(), greaterThanOrEqualTo(last));
      await speech.delete();
      expect(await speech.isInstalled(), isFalse);
    });

    test('resumes a partial download from where it stopped', () async {
      final speech = model();
      final folder = await speech.directory();
      final bytes = content['model.int8.onnx']!;
      File(p.join(folder.path, 'model.int8.onnx.part'))
          .writeAsBytesSync(bytes.sublist(0, 1000));
      await speech.download();
      expect(ranges.first, 'bytes=1000-');
      expect(await speech.isInstalled(), isTrue);
    });

    test('a file that fails the checksum is removed', () async {
      corrupt = true;
      final speech = model();
      await expectLater(speech.download(), throwsA(isA<SpeechException>()));
      expect(await speech.isInstalled(), isFalse);
      final folder = await speech.directory();
      expect(
        folder.listSync().whereType<File>().where(
          (file) => file.path.endsWith('.part'),
        ),
        isEmpty,
      );
    });
  });

  group('chat page voice', () {
    late Directory directory;
    late ValueNotifier<List<ChatMessage>> messages;
    late ValueNotifier<TransferProgressUpdate?> incoming;

    setUp(() {
      directory = Directory.systemTemp.createTempSync('mengren_vc_');
      messages = ValueNotifier(const []);
      incoming = ValueNotifier(null);
    });
    tearDown(() {
      messages.dispose();
      incoming.dispose();
      if (directory.existsSync()) directory.deleteSync(recursive: true);
    });

    Future<List<(String, String?)>> show(
      WidgetTester tester,
      _FakeSpeech speech,
    ) async {
      final saved = <(String, String?)>[];
      await tester.pumpWidget(
        MaterialApp(
          home: ChatPage(
            device: DiscoveredDevice(
              deviceId: 'phone',
              displayName: '手机',
              platform: 'android',
              address: InternetAddress.loopbackIPv4,
              transferPort: 53318,
              lastSeen: DateTime(2026, 11, 9),
            ),
            messages: messages,
            incomingProgress: incoming,
            onSendText: (_) async {},
            onSendFiles: (_, _, _) async {},
            onClearConversation: (_) async {},
            onRemoveDevice: () async {},
            onTranscribed: (message, text) async {
              saved.add((message.id, text));
              messages.value = [
                for (final item in messages.value)
                  item.id == message.id ? item.withTranscript(text) : item,
              ];
            },
            speech: speech,
            voiceRecorder: _FakeRecorder(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return saved;
    }

    ChatMessage voice(String path) => ChatMessage(
      id: 'voice-1',
      peerId: 'phone',
      peerName: '手机',
      senderId: 'phone',
      senderName: '华为手机',
      kind: ChatMessageKind.file,
      sentAt: DateTime.now(),
      isOutgoing: false,
      fileName: p.basename(path),
      filePath: path,
      isCache: true,
    );

    testWidgets('a voice message is a ▶ 12″ bar and can be transcribed', (
      tester,
    ) async {
      final file = File(
        p.join(directory.path, '语音消息_20261109_103012_12s.wav'),
      )..writeAsBytesSync([0]);
      messages.value = [voice(file.path)];
      final speech = _FakeSpeech();
      final saved = await show(tester, speech);

      expect(find.byKey(const Key('voice_voice-1')), findsOneWidget);
      expect(find.text('12″'), findsOneWidget);
      expect(find.textContaining('语音消息_'), findsNothing);

      await tester.longPress(find.byKey(const ValueKey('bubble_voice-1')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('转文字'));
      await tester.pumpAndSettle();
      expect(speech.transcribed, [file.path]);
      expect(saved, [('voice-1', '今晚七点开会')]);
      expect(find.byKey(const Key('transcript_block')), findsOneWidget);
      expect(find.text('今晚七点开会'), findsOneWidget);

      await tester.longPress(find.byKey(const ValueKey('bubble_voice-1')));
      await tester.pumpAndSettle();
      expect(find.text('转文字'), findsNothing);
      await tester.tap(find.text('隐藏文字'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('transcript_block')), findsNothing);
    });

    testWidgets('a deleted voice file shows as expired', (tester) async {
      messages.value = [
        voice(p.join(directory.path, '语音消息_20261109_103012_3s.wav')),
      ];
      await show(tester, _FakeSpeech());
      expect(find.text('3″ 已过期'), findsOneWidget);
    });

    testWidgets('dictation asks to download the model first', (tester) async {
      await show(tester, _FakeSpeech(installed: false));
      await tester.tap(find.byKey(const Key('mic_button')));
      await tester.pumpAndSettle();
      expect(find.text('下载语音识别模型'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, '取消'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('recording_bar')), findsNothing);
    });
  });

  test('voice player and services are wired', () {
    expect(VoicePlayer.instance.playingId.value, isNull);
    expect(SpeechModel.totalBytes, greaterThan(200 * 1024 * 1024));
    expect(HapticFeedback.mediumImpact, isNotNull);
  });
}
