import 'dart:io';

import 'package:flutter/services.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as path;

import '../settings/app_settings.dart';

class AndroidDirectorySelection {
  const AndroidDirectorySelection({required this.uri, required this.label});

  final String uri;
  final String label;
}

class StoredReceivedFile {
  const StoredReceivedFile({
    required this.displayLocation,
    this.filePath,
    this.contentUri,
    this.isCache = false,
  });

  final String displayLocation;
  final String? filePath;
  final String? contentUri;
  final bool isCache;
}

class ReceivedFileService {
  factory ReceivedFileService() => _instance;

  ReceivedFileService._() {
    if (Platform.isAndroid) {
      _channel.setMethodCallHandler((call) async {
        if (call.method == 'sharedFilesAvailable') {
          try {
            final files = await takeSharedFiles();
            if (files.isNotEmpty) _sharedFilesListener?.call(files);
          } on PlatformException {
            // A provider may revoke its URI while Android is resuming the app.
            // Keep the Flutter UI alive; a later launch scans completed imports.
          }
        }
      });
    }
  }

  static final ReceivedFileService _instance = ReceivedFileService._();
  static const _channel = MethodChannel(
    'com.personal.lantransfer.lan_transfer/files',
  );
  void Function(List<String> paths)? _sharedFilesListener;

  void setSharedFilesListener(void Function(List<String> paths)? listener) {
    _sharedFilesListener = listener;
  }

  Future<List<String>> takeSharedFiles() async {
    if (!Platform.isAndroid) return const [];
    try {
      final files = await _channel.invokeListMethod<String>('takeSharedFiles');
      return files ?? const [];
    } on PlatformException {
      return const [];
    }
  }

  Future<AndroidDirectorySelection?> pickAndroidDirectory() async {
    if (!Platform.isAndroid) return null;
    final result = await _channel.invokeMapMethod<String, dynamic>(
      'pickDirectory',
    );
    final uri = result?['uri'];
    final label = result?['label'];
    if (uri is! String || label is! String) return null;
    return AndroidDirectorySelection(uri: uri, label: label);
  }

  Future<StoredReceivedFile> finalizeReceivedFile(
    File source,
    AppSettings settings,
  ) async {
    if (!Platform.isAndroid) {
      return StoredReceivedFile(
        filePath: source.path,
        displayLocation: source.path,
      );
    }

    try {
      final result = await _channel.invokeMapMethod<String, dynamic>(
        'exportFile',
        {
          'sourcePath': source.path,
          'fileName': path.basename(source.path),
          'mimeType': _mimeTypeFor(source.path),
          'treeUri': settings.androidTreeUri,
          'locationLabel': settings.androidSaveLabel,
        },
      );
      final uri = result?['uri'];
      final location = result?['location'];
      if (uri is! String || location is! String) {
        throw const FileSystemException('系统没有返回保存结果');
      }
      if (await source.exists()) await source.delete();
      return StoredReceivedFile(contentUri: uri, displayLocation: location);
    } catch (_) {
      return StoredReceivedFile(
        filePath: source.path,
        displayLocation: source.path,
        isCache: true,
      );
    }
  }

  Future<void> openFile({String? filePath, String? contentUri}) async {
    if (Platform.isAndroid && contentUri != null) {
      await _channel.invokeMethod<void>('openUri', {'uri': contentUri});
      return;
    }
    if (filePath == null) throw const FileSystemException('文件地址不存在');
    final result = await OpenFilex.open(filePath);
    if (result.type != ResultType.done) {
      throw FileSystemException(result.message, filePath);
    }
  }

  static String _mimeTypeFor(String filePath) {
    switch (path.extension(filePath).toLowerCase()) {
      case '.jpg':
      case '.jpeg':
        return 'image/jpeg';
      case '.png':
        return 'image/png';
      case '.gif':
        return 'image/gif';
      case '.webp':
        return 'image/webp';
      case '.mp4':
        return 'video/mp4';
      case '.mkv':
        return 'video/x-matroska';
      case '.mp3':
        return 'audio/mpeg';
      case '.wav':
        return 'audio/wav';
      case '.pdf':
        return 'application/pdf';
      case '.txt':
        return 'text/plain';
      default:
        return 'application/octet-stream';
    }
  }
}
