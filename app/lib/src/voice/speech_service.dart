import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import '../diagnostics/diagnostic_log_service.dart';
import '../update/app_update_service.dart';

class SpeechException implements Exception {
  const SpeechException(this.message);

  final String message;

  @override
  String toString() => message;
}

class SpeechDownloadCancelled implements Exception {
  const SpeechDownloadCancelled();
}

/// Lets the download dialog stop a running download.
class SpeechDownloadToken {
  bool _cancelled = false;
  HttpClient? _client;

  bool get isCancelled => _cancelled;

  void cancel() {
    _cancelled = true;
    _client?.close(force: true);
  }
}

class SpeechModelFile {
  const SpeechModelFile(this.name, this.size, this.sha256);

  final String name;
  final int size;
  final String sha256;
}

/// The offline recognizer model (SenseVoice Small int8, from
/// k2-fsa/sherpa-onnx), mirrored on this project's GitHub release page and
/// downloaded on first use. Files are verified against the hashes below.
class SpeechModel {
  SpeechModel._()
    : _fixedRoot = null,
      _downloadClient = null,
      _baseUrl = _releaseBase,
      files = defaultFiles;

  /// Tests: a fixed folder, a plain client and (optionally) small files.
  SpeechModel.forTesting(
    Directory root, {
    required Future<HttpClient> Function() client,
    Uri? baseUrl,
    this.files = defaultFiles,
  }) : _fixedRoot = root,
       _downloadClient = client,
       _baseUrl = baseUrl ?? _releaseBase;

  static final SpeechModel instance = SpeechModel._();

  static const releaseTag = 'asr-model-sensevoice-2024-07-17';
  static final Uri _releaseBase = Uri.parse(
    'https://github.com/longpeng1413/mengren-kuaichuan/releases/download/'
    '$releaseTag/',
  );
  static const folderName = 'sensevoice-int8-2024-07-17';
  static const _verifiedMarker = '.verified';

  /// A partial download older than this is not resumed but removed.
  static const partialRetention = Duration(days: 7);

  static const defaultFiles = [
    SpeechModelFile(
      'model.int8.onnx',
      239233841,
      'c71f0ce00bec95b07744e116345e33d8cbbe08cef896382cf907bf4b51a2cd51',
    ),
    SpeechModelFile(
      'tokens.txt',
      315894,
      'f449eb28dc567533d7fa59be34e2abca8784f771850c78a47fb731a31429a1dc',
    ),
  ];

  /// Download size of the published model.
  static int get totalBytes =>
      defaultFiles.fold<int>(0, (sum, file) => sum + file.size);

  final List<SpeechModelFile> files;

  int get _filesBytes => files.fold<int>(0, (sum, file) => sum + file.size);

  final Directory? _fixedRoot;
  final Future<HttpClient> Function()? _downloadClient;
  final Uri _baseUrl;
  bool _downloading = false;

  bool get isDownloading => _downloading;

  Future<Directory> _root() async {
    final fixed = _fixedRoot;
    if (fixed != null) return fixed;
    final base = await getApplicationSupportDirectory();
    return Directory(p.join(base.path, 'asr_model'));
  }

  Future<Directory> directory() async {
    final directory = Directory(p.join((await _root()).path, folderName));
    await directory.create(recursive: true);
    return directory;
  }

  Future<String> modelPath() async =>
      p.join((await directory()).path, files[0].name);

  Future<String> tokensPath() async =>
      p.join((await directory()).path, files[1].name);

  Future<bool> isInstalled() async {
    final folder = await directory();
    if (!await File(p.join(folder.path, _verifiedMarker)).exists()) {
      return false;
    }
    for (final file in files) {
      final local = File(p.join(folder.path, file.name));
      if (!await local.exists() || await local.length() != file.size) {
        return false;
      }
    }
    return true;
  }

  /// Bytes on disk, including an unfinished download.
  Future<int> size() async {
    final root = await _root();
    if (!await root.exists()) return 0;
    var total = 0;
    await for (final entity in root.list(recursive: true)) {
      if (entity is File) {
        try {
          total += await entity.length();
        } catch (_) {}
      }
    }
    return total;
  }

  Future<void> delete() async {
    if (_downloading) throw const SpeechException('模型正在下载，请先取消下载');
    await SpeechRecognizerService.instance.shutdown();
    // The worker may still hold the files open for a moment on Windows.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final root = await _root();
    if (await root.exists()) await root.delete(recursive: true);
  }

  /// At startup: drops stale partial downloads and other model versions.
  Future<void> cleanup({DateTime? now}) async {
    final root = await _root();
    if (!await root.exists()) return;
    final cutoff = (now ?? DateTime.now()).subtract(partialRetention);
    await for (final entity in root.list()) {
      try {
        if (entity is Directory && p.basename(entity.path) != folderName) {
          await entity.delete(recursive: true);
        }
      } catch (_) {}
    }
    final folder = Directory(p.join(root.path, folderName));
    if (!await folder.exists()) return;
    await for (final entity in folder.list()) {
      if (entity is! File || !entity.path.endsWith('.part')) continue;
      try {
        if ((await entity.stat()).modified.isBefore(cutoff)) {
          await entity.delete();
        }
      } catch (_) {}
    }
  }

  /// Downloads missing files (resuming a partial one), verifies SHA-256 and
  /// marks the model ready. [onProgress] gets bytes done out of [totalBytes].
  Future<void> download({
    void Function(int received, int total)? onProgress,
    SpeechDownloadToken? token,
  }) async {
    if (_downloading) throw const SpeechException('模型已经在下载');
    _downloading = true;
    final diagnostics = DiagnosticLogService.instance;
    try {
      if (await isInstalled()) return;
      final folder = await directory();
      final marker = File(p.join(folder.path, _verifiedMarker));
      if (await marker.exists()) await marker.delete();
      var done = 0;
      await diagnostics.log('speech_model_download_started');
      for (final file in files) {
        final target = File(p.join(folder.path, file.name));
        if (await target.exists() && await target.length() == file.size) {
          done += file.size;
          onProgress?.call(done, _filesBytes);
          continue;
        }
        final base = done;
        await _downloadFile(
          file,
          target,
          token: token,
          onBytes: (bytes) => onProgress?.call(base + bytes, _filesBytes),
        );
        done += file.size;
      }
      await File(p.join(folder.path, _verifiedMarker)).writeAsString('ok');
      await diagnostics.log('speech_model_download_verified');
    } on SpeechDownloadCancelled {
      await diagnostics.log('speech_model_download_cancelled');
      rethrow;
    } catch (error) {
      await diagnostics.log('speech_model_download_failed', error: error);
      rethrow;
    } finally {
      _downloading = false;
    }
  }

  Future<void> _downloadFile(
    SpeechModelFile file,
    File target, {
    required void Function(int bytes) onBytes,
    SpeechDownloadToken? token,
  }) async {
    final partial = File('${target.path}.part');
    var offset = await partial.exists() ? await partial.length() : 0;
    if (offset > file.size) {
      await partial.delete();
      offset = 0;
    }
    final client = await (_downloadClient ??
        AppUpdateService.instance.createDownloadClient)();
    token?._client = client;
    try {
      if (token?.isCancelled ?? false) throw const SpeechDownloadCancelled();
      if (offset < file.size) {
        final request = await client.getUrl(_baseUrl.resolve(file.name));
        if (offset > 0) {
          request.headers.set(HttpHeaders.rangeHeader, 'bytes=$offset-');
        }
        final response = await request.close();
        if (response.statusCode == HttpStatus.ok) {
          offset = 0; // The server ignored the range: start over.
        } else if (response.statusCode != HttpStatus.partialContent) {
          await response.drain<void>();
          throw SpeechException('下载失败（HTTP ${response.statusCode}）');
        }
        final sink = partial.openWrite(
          mode: offset == 0 ? FileMode.writeOnly : FileMode.append,
        );
        var received = offset;
        onBytes(received);
        try {
          await for (final chunk in response.timeout(
            const Duration(seconds: 30),
            onTimeout: (events) => events.addError(
              const SpeechException('下载 30 秒没有进展，请检查网络或代理'),
            ),
          )) {
            if (token?.isCancelled ?? false) {
              throw const SpeechDownloadCancelled();
            }
            sink.add(chunk);
            received += chunk.length;
            onBytes(received);
          }
        } finally {
          await sink.close();
        }
      }
      if (await partial.length() != file.size) {
        throw const SpeechException('下载不完整，请重试（会从断点继续）');
      }
      final digest = await sha256.bind(partial.openRead()).first;
      if (digest.toString() != file.sha256) {
        await partial.delete();
        throw const SpeechException('模型文件校验失败，已删除，请重新下载');
      }
      if (await target.exists()) await target.delete();
      await partial.rename(target.path);
    } on SocketException catch (error) {
      if (token?.isCancelled ?? false) throw const SpeechDownloadCancelled();
      throw SpeechException('无法连接 GitHub：${error.message}；国内网络请先打开代理');
    } on HttpException catch (error) {
      if (token?.isCancelled ?? false) throw const SpeechDownloadCancelled();
      throw SpeechException('下载中断：${error.message}；再试一次会从断点继续');
    } finally {
      token?._client = null;
      client.close(force: true);
    }
  }
}

/// Runs the recognizer in a background isolate so the UI stays smooth. The
/// model (~240 MB) is loaded once and released after [idleTimeout].
class SpeechRecognizerService {
  SpeechRecognizerService({SpeechModel? model, this.libraryDirectory})
    // ignore: prefer_initializing_formals
    : _model = model;

  static final SpeechRecognizerService instance = SpeechRecognizerService();

  final SpeechModel? _model;

  /// Tests only: where sherpa-onnx-c-api.dll / onnxruntime.dll live. The app
  /// itself loads them from its own folder.
  final String? libraryDirectory;

  SpeechModel get model => _model ?? SpeechModel.instance;
  static const idleTimeout = Duration(minutes: 3);

  Isolate? _isolate;
  SendPort? _worker;
  Future<void>? _starting;
  Timer? _idle;
  Future<void> _queue = Future.value();

  Future<String> transcribe(String wavPath) {
    final result = _queue.then((_) => _transcribe(wavPath));
    _queue = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<String> _transcribe(String wavPath) async {
    _idle?.cancel();
    if (!await model.isInstalled()) {
      throw const SpeechException('还没有下载语音识别模型');
    }
    await (_starting ??= _start());
    final reply = ReceivePort();
    _worker!.send([wavPath, reply.sendPort]);
    final result = await reply.first;
    reply.close();
    _idle = Timer(idleTimeout, () => unawaited(shutdown()));
    if (result is String) return result.trim();
    throw SpeechException('识别失败：$result');
  }

  Future<void> _start() async {
    final ready = ReceivePort();
    final threads = Platform.numberOfProcessors.clamp(1, 4);
    try {
      _isolate = await Isolate.spawn(_speechWorker, [
        ready.sendPort,
        await model.modelPath(),
        await model.tokensPath(),
        threads,
        libraryDirectory,
      ], debugName: 'speech-recognizer');
      final first = await ready.first.timeout(const Duration(seconds: 60));
      if (first is! SendPort) {
        throw SpeechException('识别引擎启动失败：$first');
      }
      _worker = first;
      await DiagnosticLogService.instance.log(
        'speech_worker_started threads=$threads',
      );
    } catch (error) {
      _isolate?.kill(priority: Isolate.immediate);
      _isolate = null;
      _starting = null;
      await DiagnosticLogService.instance.log(
        'speech_worker_start_failed',
        error: error,
      );
      rethrow;
    } finally {
      ready.close();
    }
  }

  Future<void> shutdown() async {
    _idle?.cancel();
    _worker?.send('stop');
    _worker = null;
    final isolate = _isolate;
    _isolate = null;
    _starting = null;
    if (isolate != null) {
      // The worker frees the recognizer on 'stop'; give it a moment.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      isolate.kill();
    }
  }
}

void _speechWorker(List<Object?> arguments) {
  final main = arguments[0]! as SendPort;
  final sherpa.OfflineRecognizer recognizer;
  try {
    final library = arguments.length > 4 ? arguments[4] as String? : null;
    if (Platform.isWindows) {
      // Windows 11 ships an older onnxruntime.dll in System32; make sure the
      // one next to the program (or the given test folder) is used.
      final folder = library ?? p.dirname(Platform.resolvedExecutable);
      final bundled = File(p.join(folder, 'onnxruntime.dll'));
      if (bundled.existsSync()) DynamicLibrary.open(bundled.path);
    }
    sherpa.initBindings(library);
    recognizer = sherpa.OfflineRecognizer(
      sherpa.OfflineRecognizerConfig(
        model: sherpa.OfflineModelConfig(
          senseVoice: sherpa.OfflineSenseVoiceModelConfig(
            model: arguments[1]! as String,
            useInverseTextNormalization: true,
          ),
          tokens: arguments[2]! as String,
          numThreads: arguments[3]! as int,
          debug: false,
        ),
      ),
    );
  } catch (error) {
    main.send('$error');
    return;
  }
  final port = ReceivePort();
  main.send(port.sendPort);
  port.listen((message) {
    if (message == 'stop') {
      recognizer.free();
      port.close();
      return;
    }
    final request = message as List<Object?>;
    final reply = request[1]! as SendPort;
    try {
      final wave = sherpa.readWave(request[0]! as String);
      if (wave.samples.isEmpty) {
        reply.send('');
        return;
      }
      final stream = recognizer.createStream();
      stream.acceptWaveform(samples: wave.samples, sampleRate: wave.sampleRate);
      recognizer.decode(stream);
      final text = recognizer.getResult(stream).text;
      stream.free();
      reply.send(text);
    } catch (error) {
      reply.send(['$error']);
    }
  });
}

/// What the chat page needs from speech recognition; tests pass a fake.
abstract class SpeechEngine {
  Future<bool> isModelInstalled();

  Future<void> downloadModel({
    void Function(int received, int total)? onProgress,
    SpeechDownloadToken? token,
  });

  Future<String> transcribe(String wavPath);
}

class PlatformSpeechEngine implements SpeechEngine {
  const PlatformSpeechEngine();

  @override
  Future<bool> isModelInstalled() => SpeechModel.instance.isInstalled();

  @override
  Future<void> downloadModel({
    void Function(int received, int total)? onProgress,
    SpeechDownloadToken? token,
  }) => SpeechModel.instance.download(onProgress: onProgress, token: token);

  @override
  Future<String> transcribe(String wavPath) =>
      SpeechRecognizerService.instance.transcribe(wavPath);
}
