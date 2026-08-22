import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

class DiagnosticLogInfo {
  const DiagnosticLogInfo({required this.bytes, required this.fileCount});

  final int bytes;
  final int fileCount;
}

class DiagnosticLogService {
  DiagnosticLogService._();

  static final DiagnosticLogService instance = DiagnosticLogService._();
  static const _channel = MethodChannel(
    'com.personal.lantransfer.lan_transfer/files',
  );
  static const _maxFileBytes = 1024 * 1024;
  static const _retention = Duration(days: 7);

  Future<void> _writeQueue = Future<void>.value();
  Directory? _directory;

  Future<void> initialize() async {
    final support = await getApplicationSupportDirectory();
    _directory = Directory(path.join(support.path, 'diagnostics'));
    await _directory!.create(recursive: true);
    await _removeExpiredFiles();
  }

  Future<void> log(String event, {Object? error, StackTrace? stackTrace}) {
    final completer = Completer<void>();
    _writeQueue = _writeQueue.then((_) async {
      try {
        await _write(event, error: error, stackTrace: stackTrace);
        completer.complete();
      } catch (_) {
        // Diagnostics must never become a new application failure.
        completer.complete();
      }
    });
    return completer.future;
  }

  Future<DiagnosticLogInfo> info() async {
    await _writeQueue;
    if (Platform.isAndroid) {
      try {
        final result = await _channel.invokeMapMethod<String, dynamic>(
          'diagnosticInfo',
        );
        return DiagnosticLogInfo(
          bytes: (result?['bytes'] as num?)?.toInt() ?? 0,
          fileCount: (result?['fileCount'] as num?)?.toInt() ?? 0,
        );
      } on PlatformException {
        // Fall back to the Dart-owned files below.
      }
    }
    final files = await _diagnosticFiles();
    var bytes = 0;
    for (final file in files) {
      bytes += await file.length();
    }
    return DiagnosticLogInfo(bytes: bytes, fileCount: files.length);
  }

  Future<String> export() async {
    await _writeQueue;
    if (!Platform.isAndroid) {
      throw const FileSystemException('诊断日志导出目前仅用于 Android');
    }
    final result = await _channel.invokeMapMethod<String, dynamic>(
      'exportDiagnostics',
    );
    final location = result?['location'];
    if (location is! String || location.isEmpty) {
      throw const FileSystemException('系统没有返回日志保存位置');
    }
    return location;
  }

  Future<void> clear() async {
    await _writeQueue;
    if (Platform.isAndroid) {
      await _channel.invokeMethod<void>('clearDiagnostics');
      return;
    }
    for (final file in await _diagnosticFiles()) {
      await file.delete();
    }
  }

  Future<void> _write(
    String event, {
    Object? error,
    StackTrace? stackTrace,
  }) async {
    if (_directory == null) await initialize();
    final current = File(path.join(_directory!.path, 'app-diagnostic.log'));
    if (await current.exists() && await current.length() >= _maxFileBytes) {
      final previous = File(
        path.join(_directory!.path, 'app-diagnostic.previous.log'),
      );
      if (await previous.exists()) await previous.delete();
      await current.rename(previous.path);
    }
    final timestamp = DateTime.now().toUtc().toIso8601String();
    final safeEvent = _singleLine(event, 4000);
    final safeError = error == null
        ? ''
        : ' error=${_singleLine('$error', 6000)}';
    final safeStack = stackTrace == null
        ? ''
        : ' stack=${_singleLine('$stackTrace', 10000)}';
    await current.writeAsString(
      '$timestamp [dart] $safeEvent$safeError$safeStack\n',
      mode: FileMode.append,
      flush: false,
    );
  }

  Future<List<File>> _diagnosticFiles() async {
    final directory = _directory;
    if (directory == null || !await directory.exists()) return const [];
    return directory
        .list()
        .where((entry) => entry is File && entry.path.endsWith('.log'))
        .cast<File>()
        .toList();
  }

  Future<void> _removeExpiredFiles() async {
    final cutoff = DateTime.now().subtract(_retention);
    for (final file in await _diagnosticFiles()) {
      if ((await file.lastModified()).isBefore(cutoff)) await file.delete();
    }
  }
}

String _singleLine(String value, int maxLength) {
  final line = value.replaceAll(RegExp(r'[\r\n]+'), ' | ').trim();
  return line.length <= maxLength ? line : '${line.substring(0, maxLength)}…';
}
