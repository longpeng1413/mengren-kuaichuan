import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lan_transfer/src/chat/chat_dates.dart';
import 'package:lan_transfer/src/discovery/discovered_device.dart';
import 'package:lan_transfer/src/transfer/transfer_client.dart';
import 'package:lan_transfer/src/transfer/transfer_models.dart';
import 'package:path/path.dart' as p;

void main() {
  group('day separators', () {
    final now = DateTime(2026, 11, 9, 10, 30); // 星期一

    test('labels follow WeChat', () {
      expect(chatDayLabel(DateTime(2026, 11, 9, 0, 1), now: now), '今天');
      expect(chatDayLabel(DateTime(2026, 11, 8, 23, 59), now: now), '昨天');
      expect(chatDayLabel(DateTime(2026, 11, 5, 12), now: now), '星期四');
      expect(chatDayLabel(DateTime(2026, 11, 3, 12), now: now), '星期二');
      expect(chatDayLabel(DateTime(2026, 11, 2, 12), now: now), '11月2日');
      expect(chatDayLabel(DateTime(2025, 12, 31, 12), now: now), '2025年12月31日');
    });

    test('a new day starts at local midnight', () {
      expect(startsNewDay(null, DateTime(2026, 11, 9)), isTrue);
      expect(
        startsNewDay(DateTime(2026, 11, 9, 0, 1), DateTime(2026, 11, 9, 23)),
        isFalse,
      );
      expect(
        startsNewDay(DateTime(2026, 11, 8, 23, 59), DateTime(2026, 11, 9)),
        isTrue,
      );
    });
  });

  group('connection cut without an answer', () {
    late Directory directory;
    late File file;

    setUp(() {
      directory = Directory.systemTemp.createTempSync('mengren_drop_');
      file = File(p.join(directory.path, 'video.mp4'))
        ..writeAsBytesSync(List.filled(256 * 1024, 3));
    });
    tearDown(() {
      if (directory.existsSync()) directory.deleteSync(recursive: true);
    });

    DiscoveredDevice receiverAt(int port) => DiscoveredDevice(
      deviceId: 'laptop',
      displayName: '笔记本',
      platform: 'windows',
      address: InternetAddress.loopbackIPv4,
      transferPort: port,
      lastSeen: DateTime(2026, 11, 9),
    );

    Future<TransferResult> send(int port) => const TransferClient(
      retryDelay: Duration.zero,
    ).sendFile(
      receiver: receiverAt(port),
      senderId: 'computer-0001',
      senderName: '电脑',
      file: file,
    );

    test('an offer cut before any data is retried, then explained', () async {
      // Like a filtering proxy: accepts the connection, closes it unanswered.
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      var connections = 0;
      server.listen((socket) {
        connections++;
        socket.listen((_) => socket.destroy(), onError: (_) {});
      });
      addTearDown(server.close);

      final error = await send(server.port).then<Object?>(
        (_) => null,
        onError: (Object error) => error,
      );
      expect(error, isA<TransferException>());
      final message = (error! as TransferException).message;
      expect(message, contains('文件还没有发出'));
      expect(message, contains('AdGuard'));
      expect((error as TransferException).unreachable, isFalse);
      expect(connections, 3, reason: '最初一次 + 自动重试 2 次');
    });

    test('a retry that gets through sends the file', () async {
      var offers = 0;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        if (request.method == 'POST') {
          offers++;
          final body = jsonDecode(await utf8.decodeStream(request));
          if (offers == 1) {
            final socket = await request.response.detachSocket(
              writeHeaders: false,
            );
            socket.destroy();
            return;
          }
          request.response
            ..statusCode = HttpStatus.created
            ..write(jsonEncode({'transferId': body['transferId']}));
          await request.response.close();
          return;
        }
        await request.drain<void>();
        request.response.write(jsonEncode({'savedFileName': 'video.mp4'}));
        await request.response.close();
      });

      final result = await send(server.port);
      expect(result.savedFileName, 'video.mp4');
      expect(offers, 2);
    });

    test('a cut after the whole file says it may have arrived', () async {
      var offers = 0;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        if (request.method == 'POST') {
          offers++;
          final body = jsonDecode(await utf8.decodeStream(request));
          request.response
            ..statusCode = HttpStatus.created
            ..write(jsonEncode({'transferId': body['transferId']}));
          await request.response.close();
          return;
        }
        // Receives everything, then the answer never makes it back.
        await request.drain<void>();
        final socket = await request.response.detachSocket(
          writeHeaders: false,
        );
        socket.destroy();
      });

      final error = await send(server.port).then<Object?>(
        (_) => null,
        onError: (Object error) => error,
      );
      expect(error, isA<TransferException>());
      expect((error! as TransferException).message, contains('对方可能已经收到'));
      expect(offers, 1, reason: '文件已发出时不能自动重发');
    });
  });
}
