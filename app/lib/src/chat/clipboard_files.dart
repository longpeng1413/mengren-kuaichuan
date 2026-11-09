import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// What the system clipboard holds right now, checked without reading the
/// content (Android only shows its "pasted from clipboard" notice on a read).
class ClipboardPeek {
  const ClipboardPeek({
    this.files = false,
    this.image = false,
    this.text = false,
  });

  static const empty = ClipboardPeek();

  /// Files copied in Explorer / a file manager, or content URIs on Android.
  final bool files;

  /// A bitmap without a file, e.g. a screenshot or "copy image".
  final bool image;
  final bool text;

  bool get hasAttachment => files || image;
}

class ClipboardAttachments {
  const ClipboardAttachments({
    required this.paths,
    this.skippedFolders = 0,
  });

  static const empty = ClipboardAttachments(paths: []);

  final List<String> paths;

  /// Folders copied in Explorer cannot be sent and are left out.
  final int skippedFolders;
}

abstract class ClipboardFileSource {
  Future<ClipboardPeek> peek();

  /// Files from the clipboard, ready to send. A bitmap or an Android content
  /// URI is written into [OutgoingCache] first.
  Future<ClipboardAttachments> read();

  /// Whether [copyFiles] is available. Windows puts CF_HDROP (+ CF_DIB for
  /// a picture) on the clipboard; Android puts content URIs, which WeChat and
  /// other apps paste as the picture/file.
  bool get canCopyFiles;

  /// [items] are local paths; on Android an item may also be a `content://`
  /// URI (files saved through 系统下载).
  Future<void> copyFiles(List<String> items);
}

class PlatformClipboardFiles implements ClipboardFileSource {
  PlatformClipboardFiles._();

  static final PlatformClipboardFiles instance = PlatformClipboardFiles._();
  static const _channel = MethodChannel(
    'com.personal.lantransfer.lan_transfer/files',
  );

  @override
  bool get canCopyFiles => Platform.isWindows || Platform.isAndroid;

  @override
  Future<ClipboardPeek> peek() async {
    if (!Platform.isWindows && !Platform.isAndroid) return ClipboardPeek.empty;
    try {
      final result = await _channel.invokeMapMethod<String, dynamic>(
        'clipboardPeek',
      );
      if (result == null) return ClipboardPeek.empty;
      return ClipboardPeek(
        files: result['files'] == true,
        image: result['image'] == true,
        text: result['text'] == true,
      );
    } on PlatformException {
      return ClipboardPeek.empty;
    } on MissingPluginException {
      return ClipboardPeek.empty;
    }
  }

  @override
  Future<ClipboardAttachments> read() async {
    if (Platform.isAndroid) {
      final directory = await OutgoingCache.instance.directory();
      final paths = await _channel.invokeListMethod<String>(
        'clipboardFiles',
        {'directory': directory.path},
      );
      return ClipboardAttachments(paths: paths ?? const []);
    }
    if (!Platform.isWindows) return ClipboardAttachments.empty;
    final result = await _channel.invokeMapMethod<String, dynamic>(
      'clipboardFiles',
    );
    final files = (result?['files'] as List?)?.whereType<String>().toList();
    final skipped = result?['skippedFolders'] as int? ?? 0;
    if (files != null && files.isNotEmpty) {
      return ClipboardAttachments(paths: files, skippedFolders: skipped);
    }
    final png = await _channel.invokeMethod<Uint8List>('clipboardImagePng');
    if (png == null || png.isEmpty) {
      return ClipboardAttachments(paths: const [], skippedFolders: skipped);
    }
    final file = await OutgoingCache.instance.createFile(pastedImageName());
    await file.writeAsBytes(png, flush: true);
    return ClipboardAttachments(paths: [file.path], skippedFolders: skipped);
  }

  @override
  Future<void> copyFiles(List<String> items) async {
    if (!canCopyFiles) {
      throw UnsupportedError('这个系统不支持把文件复制到剪贴板');
    }
    final ok = await _channel.invokeMethod<bool>('copyFilesToClipboard', {
      'paths': items,
    });
    if (ok != true) {
      throw FileSystemException(
        Platform.isWindows ? '剪贴板被其他程序占用，请重试' : '无法把文件放进剪贴板',
      );
    }
  }

  /// Android: copies a content URI (a file saved to 系统下载) into the
  /// outgoing cache so it can be forwarded like any local file.
  Future<String> copyContentUriToCache(String uri) async {
    final directory = await OutgoingCache.instance.directory();
    final copied = await _channel.invokeMethod<String>('copyUriToCache', {
      'uri': uri,
      'directory': directory.path,
    });
    if (copied == null) throw const FileSystemException('无法读取这个文件');
    return copied;
  }
}

String pastedImageName([DateTime? now]) {
  final value = (now ?? DateTime.now()).toLocal();
  String two(int number) => number.toString().padLeft(2, '0');
  return '粘贴的图片_${value.year}${two(value.month)}${two(value.day)}_'
      '${two(value.hour)}${two(value.minute)}${two(value.second)}.png';
}

/// Files the app creates only to send them: pasted screenshots/bitmaps,
/// clipboard files on Android and forwarded copies of files saved through
/// Android's 系统下载. Kept for a while so sent pictures still show their
/// thumbnail and queued items can go out later; cleaned at every start.
class OutgoingCache {
  OutgoingCache._() : _fixedDirectory = null;

  OutgoingCache.forDirectory(Directory directory)
    : _fixedDirectory = directory,
      _path = directory.path;

  static final OutgoingCache instance = OutgoingCache._();
  static const retention = Duration(days: 30);
  static const maximumBytes = 1024 * 1024 * 1024;
  static const directoryName = 'outgoing_cache';

  final Directory? _fixedDirectory;
  String? _path;

  Future<Directory> directory() async {
    var directory = _fixedDirectory;
    if (directory == null) {
      // Same placement as update_cache: Android's cache directory, and on
      // Windows next to the app's settings instead of the shared %TEMP%.
      final base = Platform.isAndroid
          ? await getTemporaryDirectory()
          : await getApplicationSupportDirectory();
      directory = Directory(p.join(base.path, directoryName));
    }
    await directory.create(recursive: true);
    _path = directory.path;
    return directory;
  }

  /// Synchronous check used when recording a sent message: a file in this
  /// cache is marked `isCache`, so deleting the message or clearing the
  /// conversation removes it.
  bool contains(String filePath) {
    final root = _path;
    return root != null && p.isWithin(root, filePath);
  }

  Future<File> createFile(String name) async {
    final root = await directory();
    final safe = name.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_');
    final stem = p.basenameWithoutExtension(safe);
    final extension = p.extension(safe);
    var candidate = File(p.join(root.path, safe));
    var index = 1;
    while (await candidate.exists()) {
      candidate = File(p.join(root.path, '$stem ($index)$extension'));
      index++;
    }
    return candidate;
  }

  /// Removes unfinished copies (`.part`, left by a crash), files older than
  /// [retention], then the oldest files while over [byteLimit].
  Future<int> cleanup({DateTime? now, int byteLimit = maximumBytes}) async {
    final root = await directory();
    final cutoff = (now ?? DateTime.now()).subtract(retention);
    final kept = <({File file, DateTime modified, int size})>[];
    var removed = 0;
    await for (final entity in root.list(followLinks: false)) {
      try {
        if (entity is Directory) {
          removed += await _sizeOf(entity);
          await entity.delete(recursive: true);
          continue;
        }
        if (entity is! File) continue;
        final stat = await entity.stat();
        if (entity.path.endsWith('.part') || stat.modified.isBefore(cutoff)) {
          removed += stat.size;
          await entity.delete();
        } else {
          kept.add((file: entity, modified: stat.modified, size: stat.size));
        }
      } catch (_) {
        // A file still open elsewhere is retried at the next start.
      }
    }
    var total = kept.fold<int>(0, (sum, item) => sum + item.size);
    kept.sort((left, right) => left.modified.compareTo(right.modified));
    for (final item in kept) {
      if (total <= byteLimit) break;
      try {
        await item.file.delete();
        total -= item.size;
        removed += item.size;
      } catch (_) {}
    }
    return removed;
  }

  Future<int> size() async {
    final root = await directory();
    return _sizeOf(root);
  }

  Future<int> clear() async {
    final root = await directory();
    var removed = 0;
    await for (final entity in root.list(followLinks: false)) {
      try {
        final size = entity is File
            ? await entity.length()
            : entity is Directory
            ? await _sizeOf(entity)
            : 0;
        await entity.delete(recursive: true);
        removed += size;
      } catch (_) {}
    }
    return removed;
  }

  static Future<int> _sizeOf(Directory directory) async {
    var total = 0;
    await for (final entity in directory.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is File) {
        try {
          total += await entity.length();
        } catch (_) {}
      }
    }
    return total;
  }
}
