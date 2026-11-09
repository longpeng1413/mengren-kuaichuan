import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Voice messages are ordinary WAV files (16 kHz mono, what the offline
/// recognizer reads directly) sent over the existing file transfer, so the
/// LAN/relay protocols stay unchanged. The duration travels in the name;
/// older clients just see an audio file.
///
/// `语音消息_20261109_103012_12s.wav` (a receiver may add " (1)").
final RegExp _voiceName = RegExp(
  r'^语音消息_\d{8}_\d{6}_(\d{1,3})s(?: \(\d+\))?\.wav$',
);

/// WeChat-style limit; also keeps a message under ~2 MB.
const maximumVoiceSeconds = 60;

bool isVoiceFileName(String name) => _voiceName.hasMatch(p.basename(name));

/// Seconds from the file name, or null for other files.
int? voiceSecondsFromName(String name) {
  final match = _voiceName.firstMatch(p.basename(name));
  return match == null ? null : int.parse(match.group(1)!);
}

String voiceFileName(DateTime recordedAt, int seconds) {
  final value = recordedAt.toLocal();
  String two(int number) => number.toString().padLeft(2, '0');
  final clamped = seconds.clamp(1, maximumVoiceSeconds);
  return '语音消息_${value.year}${two(value.month)}${two(value.day)}_'
      '${two(value.hour)}${two(value.minute)}${two(value.second)}_'
      '${clamped}s.wav';
}

/// Where sent and received voice messages live (not the user's download
/// folder, like WeChat). Cleaned at every start: unfinished recordings,
/// files older than [retention], then the oldest while over [maximumBytes].
class VoiceStore {
  VoiceStore._() : _fixedDirectory = null;

  VoiceStore.forDirectory(Directory directory)
    : _fixedDirectory = directory,
      _path = directory.path;

  static final VoiceStore instance = VoiceStore._();
  static const retention = Duration(days: 30);
  static const maximumBytes = 500 * 1024 * 1024;
  static const directoryName = 'voice_messages';

  /// Recordings in progress; a leftover one is from a crash.
  static const recordingSuffix = '.recording';

  final Directory? _fixedDirectory;
  String? _path;

  Future<Directory> directory() async {
    var directory = _fixedDirectory;
    if (directory == null) {
      final base = await getApplicationSupportDirectory();
      directory = Directory(p.join(base.path, directoryName));
    }
    await directory.create(recursive: true);
    _path = directory.path;
    return directory;
  }

  bool contains(String filePath) {
    final root = _path;
    return root != null && p.isWithin(root, filePath);
  }

  Future<File> newRecordingFile(DateTime startedAt) async {
    final root = await directory();
    final stamp = startedAt.microsecondsSinceEpoch;
    return File(p.join(root.path, 'rec_$stamp.wav$recordingSuffix'));
  }

  /// Gives a finished recording its final name (with the duration).
  Future<File> finishRecording(File recording, DateTime startedAt, int seconds) {
    return _moveInto(recording, voiceFileName(startedAt, seconds));
  }

  /// Moves a received voice message out of the download folder into the
  /// store, keeping its name (unique if needed).
  Future<File> adoptReceived(File received) =>
      _moveInto(received, p.basename(received.path));

  Future<File> _moveInto(File source, String name) async {
    final root = await directory();
    final stem = p.basenameWithoutExtension(name);
    final extension = p.extension(name);
    var target = File(p.join(root.path, name));
    var index = 1;
    while (await target.exists()) {
      target = File(p.join(root.path, '$stem ($index)$extension'));
      index++;
    }
    try {
      return await source.rename(target.path);
    } on FileSystemException {
      // Another drive (e.g. a custom save folder on D:): copy then remove.
      final copied = await source.copy(target.path);
      await source.delete();
      return copied;
    }
  }

  Future<int> cleanup({DateTime? now, int byteLimit = maximumBytes}) async {
    final root = await directory();
    final cutoff = (now ?? DateTime.now()).subtract(retention);
    final kept = <({File file, DateTime modified, int size})>[];
    var removed = 0;
    await for (final entity in root.list(followLinks: false)) {
      if (entity is! File) continue;
      try {
        final stat = await entity.stat();
        if (entity.path.endsWith(recordingSuffix) ||
            stat.modified.isBefore(cutoff)) {
          removed += stat.size;
          await entity.delete();
        } else {
          kept.add((file: entity, modified: stat.modified, size: stat.size));
        }
      } catch (_) {
        // In use (playing); retried at the next start.
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
    var total = 0;
    await for (final entity in root.list(followLinks: false)) {
      if (entity is File) {
        try {
          total += await entity.length();
        } catch (_) {}
      }
    }
    return total;
  }

  Future<int> clear() async {
    final root = await directory();
    var removed = 0;
    await for (final entity in root.list(followLinks: false)) {
      if (entity is! File) continue;
      try {
        final size = await entity.length();
        await entity.delete();
        removed += size;
      } catch (_) {}
    }
    return removed;
  }
}
