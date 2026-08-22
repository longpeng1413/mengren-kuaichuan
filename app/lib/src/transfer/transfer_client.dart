import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as path;

import '../discovery/discovered_device.dart';
import 'transfer_models.dart';

class TransferClient {
  const TransferClient();

  Future<String> sendText({
    required DiscoveredDevice receiver,
    required String senderId,
    required String senderName,
    required String text,
  }) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) throw const TransferException('消息不能为空');
    if (trimmed.length > 16000) {
      throw const TransferException('单条消息不能超过 16000 个字符');
    }
    final messageId = _randomClientId();
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      final uri = Uri(
        scheme: 'http',
        host: receiver.address.address,
        port: receiver.transferPort,
        path: '/v1/messages',
      );
      final request = await client.postUrl(uri);
      request.headers.contentType = ContentType.json;
      request.write(
        jsonEncode({
          'messageId': messageId,
          'senderId': senderId,
          'senderName': senderName,
          'text': trimmed,
          'sentAt': DateTime.now().toUtc().toIso8601String(),
        }),
      );
      final response = await request.close();
      final body = await utf8.decoder.bind(response).join();
      if (response.statusCode != HttpStatus.created) {
        throw TransferException(_readError(body, response.statusCode));
      }
      return messageId;
    } on SocketException catch (error) {
      throw TransferException('无法连接接收设备：${error.message}');
    } on HttpException catch (error) {
      throw TransferException('消息连接中断：${error.message}');
    } finally {
      client.close(force: true);
    }
  }

  Future<TransferResult> sendFile({
    required DiscoveredDevice receiver,
    required String senderId,
    required String senderName,
    required File file,
    TransferProgress? onProgress,
    TransferCancellationToken? cancellation,
  }) async {
    final transferId = _randomClientId();
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    final removeCancellationListener = cancellation?.addListener(() {
      unawaited(_cancelRemoteTransfer(receiver, transferId));
      client.close(force: true);
    });
    final fileSize = await file.length();
    final fileName = path.basename(file.path);
    try {
      cancellation?.throwIfCancelled();
      final createUri = Uri(
        scheme: 'http',
        host: receiver.address.address,
        port: receiver.transferPort,
        path: '/v1/transfers',
      );
      final createRequest = await client.postUrl(createUri);
      createRequest.headers.contentType = ContentType.json;
      createRequest.write(
        jsonEncode({
          'senderId': senderId,
          'senderName': senderName,
          'fileName': fileName,
          'fileSize': fileSize,
          'transferId': transferId,
        }),
      );
      final createResponse = await createRequest.close();
      cancellation?.throwIfCancelled();
      final createBody = await utf8.decoder.bind(createResponse).join();
      if (createResponse.statusCode != HttpStatus.created) {
        throw TransferException(
          _readError(createBody, createResponse.statusCode),
        );
      }

      final createJson = jsonDecode(createBody);
      if (createJson is! Map<String, dynamic> ||
          createJson['transferId'] is! String) {
        throw const TransferException('接收方返回了无效响应');
      }
      final acceptedTransferId = createJson['transferId'] as String;
      if (acceptedTransferId != transferId) {
        throw const TransferException('接收方返回了错误的传输编号');
      }

      final contentUri = Uri(
        scheme: 'http',
        host: receiver.address.address,
        port: receiver.transferPort,
        path: '/v1/transfers/$acceptedTransferId/content',
      );
      final contentRequest = await client.putUrl(contentUri);
      contentRequest.contentLength = fileSize;
      onProgress?.call(0, fileSize);
      await contentRequest.addStream(
        _fileChunksWithProgress(file, fileSize, onProgress, cancellation),
      );
      cancellation?.throwIfCancelled();
      final contentResponse = await contentRequest.close();
      final contentBody = await utf8.decoder.bind(contentResponse).join();
      if (contentResponse.statusCode != HttpStatus.ok) {
        throw TransferException(
          _readError(contentBody, contentResponse.statusCode),
        );
      }

      final contentJson = jsonDecode(contentBody);
      if (contentJson is! Map<String, dynamic> ||
          contentJson['savedFileName'] is! String) {
        throw const TransferException('接收方未确认文件保存结果');
      }
      return TransferResult(
        fileName: fileName,
        savedFileName: contentJson['savedFileName'] as String,
      );
    } on SocketException catch (error) {
      if (cancellation?.isCancelled ?? false) {
        throw const TransferCancelledException();
      }
      throw TransferException('无法连接接收设备：${error.message}');
    } on HttpException catch (error) {
      if (cancellation?.isCancelled ?? false) {
        throw const TransferCancelledException();
      }
      throw TransferException('传输连接中断：${error.message}');
    } on FormatException {
      throw const TransferException('接收方返回了无法识别的数据');
    } catch (_) {
      if (cancellation?.isCancelled ?? false) {
        throw const TransferCancelledException();
      }
      rethrow;
    } finally {
      removeCancellationListener?.call();
      client.close(force: true);
    }
  }

  static String _readError(String body, int statusCode) {
    try {
      final value = jsonDecode(body);
      final error = value is Map<String, dynamic> ? value['error'] : null;
      switch (error) {
        case 'rejected':
          return '接收方拒绝了文件';
        case 'confirmation_timeout':
          return '等待接收方确认超时';
        case 'file_size_mismatch':
          return '文件大小校验失败';
        case 'file_too_large':
          return '发送的数据超过声明大小';
        case 'write_failed':
          return '接收方保存文件失败';
        case 'cancelled':
          return '发送已取消';
      }
    } on FormatException {
      // Fall through to the generic status message.
    }
    return '传输失败（HTTP $statusCode）';
  }
}

Future<void> _cancelRemoteTransfer(
  DiscoveredDevice receiver,
  String transferId,
) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
  try {
    final request = await client.deleteUrl(
      Uri(
        scheme: 'http',
        host: receiver.address.address,
        port: receiver.transferPort,
        path: '/v1/transfers/$transferId',
      ),
    );
    final response = await request.close();
    await response.drain<void>();
  } catch (_) {
    // Closing the primary upload still stops the sender. The receiver also
    // removes a short/incomplete body if this best-effort signal cannot arrive.
  } finally {
    client.close(force: true);
  }
}

Stream<List<int>> _fileChunksWithProgress(
  File file,
  int total,
  TransferProgress? onProgress,
  TransferCancellationToken? cancellation,
) async* {
  var transferred = 0;
  DateTime? lastProgressAt;
  final input = await file.open();
  try {
    while (transferred < total) {
      cancellation?.throwIfCancelled();
      final chunk = await input.read(min(1024 * 1024, total - transferred));
      if (chunk.isEmpty) break;
      transferred += chunk.length;
      final now = DateTime.now();
      if (transferred == total ||
          lastProgressAt == null ||
          now.difference(lastProgressAt) >= const Duration(milliseconds: 100)) {
        lastProgressAt = now;
        onProgress?.call(transferred, total);
      }
      yield chunk;
    }
  } finally {
    await input.close();
  }
}

String _randomClientId() {
  final random = Random.secure();
  return List.generate(
    16,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
}

class TransferException implements Exception {
  const TransferException(this.message);

  final String message;

  @override
  String toString() => message;
}
