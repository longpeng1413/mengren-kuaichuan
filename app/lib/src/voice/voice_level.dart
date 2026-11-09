import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

/// Loudness of a 16-bit PCM WAV, in dBFS (0 = full scale).
class VoiceLevel {
  const VoiceLevel({required this.peakDb, required this.rmsDb});

  final double peakDb;
  final double rmsDb;
}

/// Where the samples of a 16-bit PCM WAV are, or null for other formats.
({int offset, int length})? _pcm16Data(Uint8List bytes) {
  if (bytes.length < 44) return null;
  final view = ByteData.sublistView(bytes);
  String tag(int at) => String.fromCharCodes(bytes.sublist(at, at + 4));
  if (tag(0) != 'RIFF' || tag(8) != 'WAVE') return null;
  var position = 12;
  var pcm16 = false;
  while (position + 8 <= bytes.length) {
    final id = tag(position);
    final size = view.getUint32(position + 4, Endian.little);
    final body = position + 8;
    if (id == 'fmt ' && body + 16 <= bytes.length) {
      final format = view.getUint16(body, Endian.little);
      final bits = view.getUint16(body + 14, Endian.little);
      // 1 = PCM, 0xFFFE = extensible (PCM inside for what we record).
      pcm16 = (format == 1 || format == 0xFFFE) && bits == 16;
    } else if (id == 'data') {
      if (!pcm16) return null;
      // Some writers leave the size at 0 or too big when interrupted.
      final available = bytes.length - body;
      final length = size == 0 || size > available ? available : size;
      return (offset: body, length: length - length % 2);
    }
    // Chunks are word aligned (e.g. the JUNK chunk Windows writes).
    position = body + size + (size.isOdd ? 1 : 0);
  }
  return null;
}

double _db(double amplitude) =>
    amplitude <= 0 ? -120 : 20 * math.log(amplitude / 32768) / math.ln10;

VoiceLevel? measureVoiceLevel(Uint8List bytes) {
  final data = _pcm16Data(bytes);
  if (data == null || data.length < 2) return null;
  final view = ByteData.sublistView(bytes, data.offset, data.offset + data.length);
  var peak = 0;
  var sum = 0.0;
  final count = data.length ~/ 2;
  for (var i = 0; i < count; i++) {
    final sample = view.getInt16(i * 2, Endian.little);
    final magnitude = sample.abs();
    if (magnitude > peak) peak = magnitude;
    sum += sample * sample;
  }
  return VoiceLevel(
    peakDb: _db(peak.toDouble()),
    rmsDb: _db(math.sqrt(sum / count)),
  );
}

/// Makes a quiet voice recording as loud as normal speech, WeChat style:
/// raises the average level toward [targetRmsDb] but never lets the peak
/// pass [maxPeakDb] (so nothing clips) and never boosts by more than
/// [maxGainDb] (so background noise of an empty recording stays low).
/// Returns new bytes, or null when the file is not 16-bit PCM WAV or is
/// already loud enough.
Uint8List? normalizeVoiceBytes(
  Uint8List bytes, {
  double targetRmsDb = -20,
  double maxPeakDb = -1,
  double maxGainDb = 24,
}) {
  final data = _pcm16Data(bytes);
  final level = measureVoiceLevel(bytes);
  if (data == null || level == null || level.peakDb <= -119) return null;
  final gainDb = math.min(
    maxGainDb,
    math.min(targetRmsDb - level.rmsDb, maxPeakDb - level.peakDb),
  );
  if (gainDb < 1) return null; // Already fine; leave the file untouched.
  final gain = math.pow(10, gainDb / 20).toDouble();
  final output = Uint8List.fromList(bytes);
  final view = ByteData.sublistView(
    output,
    data.offset,
    data.offset + data.length,
  );
  for (var i = 0; i < data.length ~/ 2; i++) {
    final scaled = (view.getInt16(i * 2, Endian.little) * gain).round();
    view.setInt16(i * 2, scaled.clamp(-32768, 32767), Endian.little);
  }
  return output;
}

/// Normalizes [file] in place; returns the gain applied in dB (0 = none).
Future<double> normalizeVoiceFile(File file) async {
  final bytes = await file.readAsBytes();
  final before = measureVoiceLevel(bytes);
  final normalized = normalizeVoiceBytes(bytes);
  if (normalized == null || before == null) return 0;
  await file.writeAsBytes(normalized, flush: true);
  final after = measureVoiceLevel(normalized)!;
  return after.rmsDb - before.rmsDb;
}
