import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:record/record.dart';

/// Microphone recording; abstract so widget tests can use a fake.
abstract class VoiceRecorder {
  /// False when the user (or Windows privacy settings) denies the microphone.
  Future<bool> ensurePermission();

  /// Records 16 kHz mono 16-bit WAV into [path].
  Future<void> start(String path);

  /// Stops and returns the recorded file path.
  Future<String?> stop();

  Future<void> cancel();
}

class PlatformVoiceRecorder implements VoiceRecorder {
  AudioRecorder? _recorder;

  AudioRecorder get _active => _recorder ??= AudioRecorder();

  @override
  Future<bool> ensurePermission() => _active.hasPermission();

  @override
  Future<void> start(String path) => _active.start(
    const RecordConfig(
      encoder: AudioEncoder.wav,
      sampleRate: 16000,
      numChannels: 1,
      // Phones: cleaner speech for both the listener and the recognizer.
      noiseSuppress: true,
      autoGain: true,
    ),
    path: path,
  );

  @override
  Future<String?> stop() async {
    final recorder = _recorder;
    if (recorder == null) return null;
    final path = await recorder.stop();
    await recorder.dispose();
    _recorder = null;
    return path;
  }

  @override
  Future<void> cancel() async {
    final recorder = _recorder;
    if (recorder == null) return;
    await recorder.cancel();
    await recorder.dispose();
    _recorder = null;
  }
}

/// Plays one voice message at a time, like WeChat; [playingId] drives the
/// bubbles' play/stop icon.
class VoicePlayer {
  VoicePlayer._();

  static final VoicePlayer instance = VoicePlayer._();

  final ValueNotifier<String?> playingId = ValueNotifier(null);
  AudioPlayer? _player;
  StreamSubscription<void>? _completion;

  Future<void> toggle(String messageId, String filePath) async {
    if (playingId.value == messageId) {
      await stop();
      return;
    }
    await stop();
    if (!await File(filePath).exists()) {
      throw const FileSystemException('语音已过期或被删除');
    }
    final player = _player ??= AudioPlayer();
    _completion ??= player.onPlayerComplete.listen((_) {
      playingId.value = null;
    });
    playingId.value = messageId;
    try {
      await player.play(DeviceFileSource(filePath));
    } catch (_) {
      playingId.value = null;
      rethrow;
    }
  }

  Future<void> stop() async {
    if (playingId.value == null) return;
    playingId.value = null;
    try {
      await _player?.stop();
    } catch (_) {}
  }
}
