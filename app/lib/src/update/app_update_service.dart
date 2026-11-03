import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app_version.dart';
import '../diagnostics/diagnostic_log_service.dart';
import 'windows_update_script.dart';

/// Official releases only come from this repository. Forks must change it
/// together with the brand (see BRAND_POLICY.md).
const officialUpdateRepository = 'longpeng1413/mengren-kuaichuan';
final officialUpdateFeed = Uri.parse(
  'https://api.github.com/repos/$officialUpdateRepository/releases/latest',
);
const windowsLauncherName = '猛人快传.exe';
const _updateChannel = MethodChannel(
  'com.personal.lantransfer.lan_transfer/update',
);
const _resultFileName = 'update_result.json';
const _scriptFileName = 'apply_update.ps1';
const _startedFileName = 'apply_started.txt';

/// Quotes one argument the way Windows programs (CommandLineToArgvW) split
/// a command line: backslashes are doubled only before a quote.
String quoteWindowsArgument(String value) {
  final buffer = StringBuffer('"');
  var backslashes = 0;
  for (final char in value.split('')) {
    if (char == r'\') {
      backslashes++;
      continue;
    }
    if (char == '"') {
      buffer
        ..write(r'\' * (backslashes * 2 + 1))
        ..write('"');
    } else {
      buffer
        ..write(r'\' * backslashes)
        ..write(char);
    }
    backslashes = 0;
  }
  buffer
    ..write(r'\' * (backslashes * 2))
    ..write('"');
  return buffer.toString();
}

enum UpdatePlatform { android, windows }

class UpdateException implements Exception {
  const UpdateException(this.message);

  final String message;

  @override
  String toString() => message;
}

class UpdateCancelledException extends UpdateException {
  const UpdateCancelledException() : super('已取消下载');
}

/// Plain major.minor.patch versions. Pre-release tags such as `v1.7.7-rc.2`
/// return null so they are never offered as updates.
class AppSemVersion implements Comparable<AppSemVersion> {
  const AppSemVersion(this.major, this.minor, this.patch);

  final int major;
  final int minor;
  final int patch;

  static AppSemVersion? tryParse(String raw) {
    var value = raw.trim();
    if (value.startsWith('v') || value.startsWith('V')) {
      value = value.substring(1);
    }
    final plus = value.indexOf('+');
    if (plus >= 0) value = value.substring(0, plus);
    final match = RegExp(r'^(\d+)\.(\d+)\.(\d+)$').firstMatch(value);
    if (match == null) return null;
    return AppSemVersion(
      int.parse(match.group(1)!),
      int.parse(match.group(2)!),
      int.parse(match.group(3)!),
    );
  }

  @override
  int compareTo(AppSemVersion other) {
    if (major != other.major) return major.compareTo(other.major);
    if (minor != other.minor) return minor.compareTo(other.minor);
    return patch.compareTo(other.patch);
  }

  bool operator >(AppSemVersion other) => compareTo(other) > 0;

  @override
  bool operator ==(Object other) =>
      other is AppSemVersion && compareTo(other) == 0;

  @override
  int get hashCode => Object.hash(major, minor, patch);

  @override
  String toString() => '$major.$minor.$patch';
}

class UpdateAsset {
  const UpdateAsset({
    required this.name,
    required this.size,
    required this.downloadUrl,
    this.sha256,
  });

  final String name;
  final int size;
  final Uri downloadUrl;

  /// Lower-case hex digest reported by GitHub for the uploaded asset.
  final String? sha256;
}

class AvailableUpdate {
  const AvailableUpdate({
    required this.version,
    required this.title,
    required this.notes,
    required this.pageUrl,
    required this.asset,
    this.checksumAsset,
  });

  final String version;
  final String title;
  final String notes;
  final Uri? pageUrl;
  final UpdateAsset asset;
  final UpdateAsset? checksumAsset;
}

sealed class UpdateCheckResult {
  const UpdateCheckResult();
}

class UpdateUpToDate extends UpdateCheckResult {
  const UpdateUpToDate(this.latestVersion);

  final String? latestVersion;
}

class UpdateFound extends UpdateCheckResult {
  const UpdateFound(this.update);

  final AvailableUpdate update;
}

/// A newer release exists but has no installer for this platform.
class UpdateWithoutInstaller extends UpdateCheckResult {
  const UpdateWithoutInstaller(this.version, this.pageUrl);

  final String version;
  final Uri? pageUrl;
}

/// Outcome written by the Windows apply script before it restarts the app.
class WindowsUpdateOutcome {
  const WindowsUpdateOutcome({
    required this.succeeded,
    required this.version,
    required this.message,
  });

  final bool succeeded;
  final String version;
  final String message;
}

class UpdateCancelToken {
  bool _cancelled = false;
  final List<void Function()> _listeners = [];

  bool get isCancelled => _cancelled;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    for (final listener in List.of(_listeners)) {
      listener();
    }
  }

  void _onCancel(void Function() listener) {
    if (_cancelled) {
      listener();
    } else {
      _listeners.add(listener);
    }
  }
}

UpdateCheckResult parseLatestRelease(
  Map<String, Object?> release, {
  required String currentVersion,
  required UpdatePlatform platform,
}) {
  final tag = release['tag_name'];
  if (release['draft'] == true || release['prerelease'] == true) {
    return const UpdateUpToDate(null);
  }
  final latest = tag is String ? AppSemVersion.tryParse(tag) : null;
  final current = AppSemVersion.tryParse(currentVersion);
  if (latest == null || current == null || !(latest > current)) {
    return UpdateUpToDate(latest?.toString());
  }
  final version = latest.toString();
  final assets = <UpdateAsset>[];
  final rawAssets = release['assets'];
  if (rawAssets is List) {
    for (final raw in rawAssets) {
      final asset = _parseAsset(raw);
      if (asset != null) assets.add(asset);
    }
  }
  final pageValue = release['html_url'];
  final pageUrl = pageValue is String ? Uri.tryParse(pageValue) : null;
  final installer = _pickInstaller(assets, version, platform);
  if (installer == null) return UpdateWithoutInstaller(version, pageUrl);
  final checksum = assets
      .where((asset) => asset.name == 'SHA256SUMS-v$version.txt')
      .firstOrNull;
  final name = release['name'];
  final body = release['body'];
  return UpdateFound(
    AvailableUpdate(
      version: version,
      title: name is String && name.trim().isNotEmpty
          ? name.trim()
          : '猛人快传 v$version',
      notes: body is String ? plainReleaseNotes(body) : '',
      pageUrl: pageUrl,
      asset: installer,
      checksumAsset: checksum,
    ),
  );
}

UpdateAsset? _parseAsset(Object? raw) {
  if (raw is! Map) return null;
  final name = raw['name'];
  final url = raw['browser_download_url'];
  final size = raw['size'];
  if (name is! String || url is! String) return null;
  final downloadUrl = Uri.tryParse(url);
  if (downloadUrl == null) return null;
  final digest = raw['digest'];
  String? sha;
  if (digest is String && digest.toLowerCase().startsWith('sha256:')) {
    final hex = digest.substring(7).toLowerCase();
    if (RegExp(r'^[0-9a-f]{64}$').hasMatch(hex)) sha = hex;
  }
  return UpdateAsset(
    name: name,
    size: size is int ? size : 0,
    downloadUrl: downloadUrl,
    sha256: sha,
  );
}

UpdateAsset? _pickInstaller(
  List<UpdateAsset> assets,
  String version,
  UpdatePlatform platform,
) {
  // GitHub rewrites non-ASCII asset names, so releases use the pinyin repo
  // name from v1.8.1; releases up to v1.8.0 used `mengren-transfer`.
  final exactNames = switch (platform) {
    UpdatePlatform.android => [
      'mengren-kuaichuan-android-v$version.apk',
      'mengren-transfer-android-v$version.apk',
    ],
    UpdatePlatform.windows => [
      'mengren-kuaichuan-windows-x64-v$version.zip',
      'mengren-transfer-windows-x64-v$version.zip',
    ],
  };
  for (final exactName in exactNames) {
    final exact = assets.where((asset) => asset.name == exactName).firstOrNull;
    if (exact != null) return exact;
  }
  final fallback = assets.where((asset) {
    final name = asset.name.toLowerCase();
    return switch (platform) {
      UpdatePlatform.android => name.endsWith('.apk'),
      UpdatePlatform.windows =>
        name.endsWith('.zip') && name.contains('windows'),
    };
  }).toList();
  return fallback.length == 1 ? fallback.single : null;
}

/// Parses `HEX  name` lines; a leading `*` (binary mode) is ignored.
Map<String, String> parseSha256Sums(String text) {
  final result = <String, String>{};
  for (final line in const LineSplitter().convert(text)) {
    final match = RegExp(
      r'^\s*([0-9a-fA-F]{64})\s+\*?(.+?)\s*$',
    ).firstMatch(line);
    if (match != null) {
      result[match.group(2)!] = match.group(1)!.toLowerCase();
    }
  }
  return result;
}

/// Both GitHub's own digest and the published SHA256SUMS file are trusted
/// sources; at least one must exist and, if both exist, they must agree.
String resolveExpectedSha256({
  required String? assetDigest,
  required String? checksumFileDigest,
}) {
  if (assetDigest != null &&
      checksumFileDigest != null &&
      assetDigest != checksumFileDigest) {
    throw const UpdateException('发布页上的两份校验值不一致，已停止更新');
  }
  final expected = assetDigest ?? checksumFileDigest;
  if (expected == null) {
    throw const UpdateException('发布页缺少安装包校验值，已停止更新');
  }
  return expected;
}

/// GitHub release notes are Markdown; the dialog shows plain text.
String plainReleaseNotes(String markdown) {
  final lines = const LineSplitter().convert(markdown).map((line) {
    return line
        .replaceFirst(RegExp(r'^\s{0,3}#{1,6}\s*'), '')
        .replaceAll('**', '')
        .replaceAll('`', '')
        .replaceAllMapped(
          RegExp(r'\[([^\]]+)\]\([^)]+\)'),
          (match) => match.group(1)!,
        );
  });
  return lines.join('\n').replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
}

class AppUpdateService {
  AppUpdateService({
    Uri? feedUrl,
    String? currentVersion,
    UpdatePlatform? platform,
    Future<Directory> Function()? cacheDirectory,
    this.allowInsecureHttpForTesting = false,
    DiagnosticLogService? diagnostics,
  }) : feedUrl = feedUrl ?? officialUpdateFeed,
       currentVersion =
           currentVersion ??
           (isUpdateTestBuild ? updateTestCurrentVersion : appVersion),
       platform =
           platform ??
           (Platform.isAndroid ? UpdatePlatform.android : UpdatePlatform.windows),
       _cacheDirectory = cacheDirectory ?? _defaultCacheDirectory,
       _diagnostics = diagnostics ?? DiagnosticLogService.instance;

  static final AppUpdateService instance = AppUpdateService();

  static const autoCheckInterval = Duration(hours: 24);
  static const _lastCheckKey = 'update_last_check_ms';
  static const _skippedVersionKey = 'update_skipped_version';

  final Uri feedUrl;
  final String currentVersion;
  final UpdatePlatform platform;
  final bool allowInsecureHttpForTesting;
  final Future<Directory> Function() _cacheDirectory;
  final DiagnosticLogService _diagnostics;
  final StreamController<AndroidInstallStatus> _installStatus =
      StreamController.broadcast();
  bool _channelReady = false;
  bool _busy = false;
  WindowsUpdateOutcome? _pendingOutcome;

  static bool get isSupportedPlatform => Platform.isAndroid || Platform.isWindows;

  /// True while a download or install is running; cache clearing waits.
  bool get isBusy => _busy;

  Stream<AndroidInstallStatus> get androidInstallStatus {
    _ensureChannel();
    return _installStatus.stream;
  }

  static Future<Directory> _defaultCacheDirectory() async {
    // Android's cache directory may also be trimmed by the system; Windows
    // keeps it next to the app's settings instead of the shared %TEMP%.
    final base = Platform.isAndroid
        ? await getTemporaryDirectory()
        : await getApplicationSupportDirectory();
    return Directory(p.join(base.path, 'update_cache'));
  }

  Future<Directory> cacheDirectory() async {
    final directory = await _cacheDirectory();
    await directory.create(recursive: true);
    return directory;
  }

  /// Called once at startup, before anything can be downloading: reads the
  /// previous Windows apply result and removes every leftover download,
  /// partial file, extracted copy and backup.
  Future<void> cleanupOnStartup() async {
    final directory = await cacheDirectory();
    final resultFile = File(p.join(directory.path, _resultFileName));
    if (await resultFile.exists()) {
      try {
        final decoded = jsonDecode(await resultFile.readAsString());
        if (decoded is Map) {
          _pendingOutcome = WindowsUpdateOutcome(
            succeeded: decoded['ok'] == true,
            version: '${decoded['version'] ?? ''}',
            message: '${decoded['message'] ?? ''}',
          );
          await _diagnostics.log(
            'update_previous_result ok=${_pendingOutcome!.succeeded} '
            'message=${_pendingOutcome!.message} '
            'version=${_pendingOutcome!.version}',
          );
        }
      } catch (_) {
        // A truncated result file is simply discarded below.
      }
    }
    final removed = await _clearDirectory(directory);
    if (removed > 0) {
      await _diagnostics.log('update_cache_cleaned bytes=$removed');
    }
  }

  /// Returns the previous Windows update result once, then forgets it.
  WindowsUpdateOutcome? takePreviousOutcome() {
    final outcome = _pendingOutcome;
    _pendingOutcome = null;
    return outcome;
  }

  Future<int> cacheSize() async {
    final directory = await _cacheDirectory();
    if (!await directory.exists()) return 0;
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

  Future<int> clearCache() async {
    if (_busy) throw const UpdateException('正在更新，完成后再清空');
    final directory = await _cacheDirectory();
    if (!await directory.exists()) return 0;
    return _clearDirectory(directory);
  }

  Future<int> _clearDirectory(Directory directory) async {
    var removed = 0;
    await for (final entity in directory.list(followLinks: false)) {
      try {
        if (entity is File) {
          removed += await entity.length();
          await entity.delete();
        } else if (entity is Directory) {
          await for (final child in entity.list(
            recursive: true,
            followLinks: false,
          )) {
            if (child is File) {
              try {
                removed += await child.length();
              } catch (_) {}
            }
          }
          await entity.delete(recursive: true);
        } else {
          await entity.delete();
        }
      } catch (_) {
        // Locked files (for example a finishing apply script) are retried on
        // the next startup.
      }
    }
    return removed;
  }

  Future<bool> shouldAutoCheck({DateTime? now}) async {
    final preferences = await SharedPreferences.getInstance();
    final last = preferences.getInt(_lastCheckKey);
    if (last == null) return true;
    final elapsed = (now ?? DateTime.now()).difference(
      DateTime.fromMillisecondsSinceEpoch(last),
    );
    return elapsed >= autoCheckInterval || elapsed.isNegative;
  }

  Future<String?> skippedVersion() async {
    final preferences = await SharedPreferences.getInstance();
    return preferences.getString(_skippedVersionKey);
  }

  Future<void> skipVersion(String version) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_skippedVersionKey, version);
    await _diagnostics.log('update_version_skipped version=$version');
  }

  Future<UpdateCheckResult> check() async {
    await _diagnostics.log(
      'update_check_started current=$currentVersion platform=${platform.name}',
    );
    final client = await _createClient();
    try {
      final request = await client.getUrl(feedUrl);
      request.headers
        ..set(HttpHeaders.acceptHeader, 'application/vnd.github+json')
        ..set('X-GitHub-Api-Version', '2022-11-28');
      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      _ensureSecureRedirects(response);
      final body = await utf8.decodeStream(response).timeout(
        const Duration(seconds: 30),
      );
      if (response.statusCode == HttpStatus.notFound) {
        return const UpdateUpToDate(null);
      }
      if (response.statusCode == HttpStatus.forbidden ||
          response.statusCode == HttpStatus.tooManyRequests) {
        throw const UpdateException('GitHub 暂时限制了查询次数，请过一小时再试');
      }
      if (response.statusCode != HttpStatus.ok) {
        throw UpdateException('查询更新失败（GitHub 返回 ${response.statusCode}）');
      }
      final decoded = jsonDecode(body);
      if (decoded is! Map<String, Object?>) {
        throw const UpdateException('GitHub 返回的数据无法识别');
      }
      final result = parseLatestRelease(
        decoded,
        currentVersion: currentVersion,
        platform: platform,
      );
      final preferences = await SharedPreferences.getInstance();
      await preferences.setInt(
        _lastCheckKey,
        DateTime.now().millisecondsSinceEpoch,
      );
      await _diagnostics.log('update_check_result ${_describe(result)}');
      return result;
    } on UpdateException catch (error) {
      await _diagnostics.log('update_check_failed reason=${error.message}');
      rethrow;
    } on TimeoutException {
      await _diagnostics.log('update_check_failed reason=timeout');
      throw const UpdateException('连接 GitHub 超时，请检查网络后再试');
    } on SocketException catch (error) {
      await _diagnostics.log('update_check_failed reason=socket', error: error);
      throw const UpdateException('无法连接 GitHub，请检查网络后再试');
    } on HandshakeException catch (error) {
      await _diagnostics.log('update_check_failed reason=tls', error: error);
      throw const UpdateException('与 GitHub 的安全连接失败，请检查网络或代理');
    } on FormatException {
      throw const UpdateException('GitHub 返回的数据无法识别');
    } finally {
      client.close(force: true);
    }
  }

  String _describe(UpdateCheckResult result) => switch (result) {
    UpdateUpToDate(:final latestVersion) => 'up_to_date latest=$latestVersion',
    UpdateFound(:final update) =>
      'found version=${update.version} asset=${update.asset.name}',
    UpdateWithoutInstaller(:final version) => 'no_installer version=$version',
  };

  /// Downloads the installer into the update cache and verifies its SHA-256
  /// before returning. Partial or mismatching files are always deleted.
  Future<File> download(
    AvailableUpdate update, {
    void Function(int received, int total)? onProgress,
    UpdateCancelToken? cancelToken,
  }) async {
    if (_busy) throw const UpdateException('已有更新正在进行');
    _busy = true;
    try {
      return await _download(
        update,
        onProgress: onProgress,
        cancelToken: cancelToken,
      );
    } finally {
      _busy = false;
    }
  }

  Future<File> _download(
    AvailableUpdate update, {
    void Function(int received, int total)? onProgress,
    UpdateCancelToken? cancelToken,
  }) async {
    if (p.basename(update.asset.name) != update.asset.name ||
        update.asset.name.contains('..')) {
      throw const UpdateException('安装包文件名异常，已停止更新');
    }
    final directory = await cacheDirectory();
    final target = File(p.join(directory.path, update.asset.name));
    final partial = File('${target.path}.part');
    final client = await _createClient();
    StreamSubscription<List<int>>? subscription;
    IOSink? sink;
    try {
      final checksumDigest = await _checksumFileDigest(client, update);
      final expected = resolveExpectedSha256(
        assetDigest: update.asset.sha256,
        checksumFileDigest: checksumDigest,
      );
      if (await target.exists() && await _sha256Of(target) == expected) {
        onProgress?.call(update.asset.size, update.asset.size);
        return target;
      }
      await _deleteQuietly(target);
      await _deleteQuietly(partial);
      if (cancelToken?.isCancelled ?? false) {
        throw const UpdateCancelledException();
      }
      await _diagnostics.log(
        'update_download_started version=${update.version} '
        'bytes=${update.asset.size}',
      );
      final request = await client.getUrl(update.asset.downloadUrl);
      cancelToken?._onCancel(() {
        try {
          request.abort(const UpdateCancelledException());
        } catch (_) {}
      });
      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      _ensureSecureRedirects(response);
      if (response.statusCode != HttpStatus.ok) {
        throw UpdateException('下载失败（服务器返回 ${response.statusCode}）');
      }
      final total = update.asset.size > 0
          ? update.asset.size
          : response.contentLength;
      final digestCapture = _DigestCapture();
      final hasher = sha256.startChunkedConversion(digestCapture);
      sink = partial.openWrite();
      var received = 0;
      var lastReport = DateTime.fromMillisecondsSinceEpoch(0);
      final done = Completer<void>();
      // An idle connection for 60 seconds counts as a failed download.
      subscription = response
          .timeout(const Duration(seconds: 60))
          .listen(
            (chunk) {
              received += chunk.length;
              if (total > 0 && received > total) {
                if (!done.isCompleted) {
                  done.completeError(
                    const UpdateException('下载的文件比发布页记录的大，已停止'),
                  );
                }
                return;
              }
              hasher.add(chunk);
              sink!.add(chunk);
              final now = DateTime.now();
              if (now.difference(lastReport) >=
                  const Duration(milliseconds: 150)) {
                lastReport = now;
                onProgress?.call(received, total);
              }
            },
            onError: (Object error) {
              if (!done.isCompleted) done.completeError(error);
            },
            onDone: () {
              if (!done.isCompleted) done.complete();
            },
            cancelOnError: true,
          );
      cancelToken?._onCancel(() {
        if (!done.isCompleted) {
          done.completeError(const UpdateCancelledException());
        }
      });
      await done.future;
      await sink.flush();
      await sink.close();
      sink = null;
      hasher.close();
      onProgress?.call(received, total);
      if (total > 0 && received != total) {
        throw const UpdateException('下载不完整，请重试');
      }
      final actual = digestCapture.value.toString();
      if (actual != expected) {
        await _diagnostics.log('update_download_hash_mismatch');
        throw const UpdateException('安装包校验不通过（文件可能损坏或被改动），已删除');
      }
      await partial.rename(target.path);
      await _diagnostics.log('update_download_verified version=${update.version}');
      return target;
    } on UpdateException catch (error) {
      await _diagnostics.log('update_download_failed reason=${error.message}');
      await _cleanupFailedDownload(sink, subscription, partial);
      rethrow;
    } catch (error) {
      await _cleanupFailedDownload(sink, subscription, partial);
      if (cancelToken?.isCancelled ?? false) {
        throw const UpdateCancelledException();
      }
      await _diagnostics.log('update_download_failed', error: error);
      // github.com downloads often need a proxy in mainland China. A user
      // whose phone proxy was per-app hit this: browsers were proxied, this
      // app was not.
      if (error is TimeoutException) {
        throw const UpdateException(
          'GitHub 下载服务器长时间没有响应。国内访问 GitHub 常常需要代理：'
          '请确认代理已开启；如果代理软件设置了“分应用代理”，要把猛人快传加入走代理的应用。'
          '也可以点“去网页手动下载”，或用电脑把安装包发到手机。',
        );
      }
      if (error is SocketException || error is HttpException) {
        throw const UpdateException(
          '连不上 GitHub 下载服务器或下载中断。请确认代理已开启；'
          '如果代理软件设置了“分应用代理”，要把猛人快传加入走代理的应用。'
          '也可以点“去网页手动下载”。',
        );
      }
      if (error is HandshakeException) {
        throw const UpdateException('与下载服务器的安全连接失败，请检查网络或代理');
      }
      throw UpdateException('下载失败：$error');
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _cleanupFailedDownload(
    IOSink? sink,
    StreamSubscription<List<int>>? subscription,
    File partial,
  ) async {
    await subscription?.cancel();
    try {
      await sink?.close();
    } catch (_) {}
    await _deleteQuietly(partial);
  }

  Future<String?> _checksumFileDigest(
    HttpClient client,
    AvailableUpdate update,
  ) async {
    final checksumAsset = update.checksumAsset;
    if (checksumAsset == null) return null;
    try {
      final request = await client.getUrl(checksumAsset.downloadUrl);
      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      _ensureSecureRedirects(response);
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        return null;
      }
      final text = await utf8.decodeStream(response).timeout(
        const Duration(seconds: 30),
      );
      return parseSha256Sums(text)[update.asset.name];
    } on UpdateException {
      rethrow;
    } catch (_) {
      // GitHub's own digest still protects the download; resolveExpected
      // refuses to continue if neither source is available.
      return null;
    }
  }

  void _ensureSecureRedirects(HttpClientResponse response) {
    if (allowInsecureHttpForTesting) return;
    for (final redirect in response.redirects) {
      if (redirect.location.hasScheme && redirect.location.scheme != 'https') {
        throw const UpdateException('更新地址被重定向到不安全的连接，已停止');
      }
    }
  }

  Future<HttpClient> _createClient() async {
    if (!allowInsecureHttpForTesting && feedUrl.scheme != 'https') {
      throw const UpdateException('更新地址必须使用 HTTPS');
    }
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20)
      ..idleTimeout = const Duration(seconds: 15)
      ..userAgent = 'MengrenKuaichuan/$appVersion';
    final proxy = await _systemProxy();
    if (proxy != _loggedProxy) {
      _loggedProxy = proxy;
      await _diagnostics.log('update_network proxy=${proxy ?? 'none'}');
    }
    client.findProxy = (uri) {
      final fromEnvironment = HttpClient.findProxyFromEnvironment(uri);
      if (fromEnvironment != 'DIRECT') return fromEnvironment;
      return proxy == null ? 'DIRECT' : 'PROXY $proxy; DIRECT';
    };
    return client;
  }

  String? _loggedProxy = '';

  /// Dart's HttpClient ignores the system proxy on both Windows and Android,
  /// but many users in mainland China can only reach github.com through a
  /// local proxy (browsers use it, so downloads there are fast).
  Future<String?> _systemProxy() async {
    if (allowInsecureHttpForTesting) return null;
    if (Platform.isAndroid) {
      try {
        final proxy = await _updateChannel
            .invokeMethod<String>('systemProxy')
            .timeout(const Duration(seconds: 5));
        return proxy == null || proxy.trim().isEmpty ? null : proxy.trim();
      } catch (_) {
        return null;
      }
    }
    if (!Platform.isWindows) return null;
    try {
      const key =
          r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings';
      final enabled = await Process.run('reg', [
        'query',
        key,
        '/v',
        'ProxyEnable',
      ]).timeout(const Duration(seconds: 5));
      if (!RegExp(r'ProxyEnable\s+REG_DWORD\s+0x0*1\b')
          .hasMatch('${enabled.stdout}')) {
        return null;
      }
      final server = await Process.run('reg', [
        'query',
        key,
        '/v',
        'ProxyServer',
      ]).timeout(const Duration(seconds: 5));
      final match = RegExp(
        r'ProxyServer\s+REG_SZ\s+(\S+)',
      ).firstMatch('${server.stdout}');
      return match == null ? null : parseWindowsProxyServer(match.group(1)!);
    } catch (_) {
      return null;
    }
  }

  // ---------------------------------------------------------------- Android

  void _ensureChannel() {
    if (_channelReady || !Platform.isAndroid) return;
    _channelReady = true;
    _updateChannel.setMethodCallHandler((call) async {
      if (call.method != 'installStatus') return null;
      final arguments = call.arguments;
      if (arguments is! Map) return null;
      final status = AndroidInstallStatus.fromNative(
        '${arguments['status']}',
        arguments['code'] is int ? arguments['code'] as int : null,
        arguments['message'] as String?,
      );
      await _diagnostics.log(
        'update_install_status status=${status.kind.name} '
        'code=${status.code}',
      );
      _installStatus.add(status);
      return null;
    });
  }

  Future<bool> canInstallPackages() async {
    _ensureChannel();
    return await _updateChannel.invokeMethod<bool>('canInstallPackages') ??
        false;
  }

  Future<void> openInstallPermissionSettings() async {
    _ensureChannel();
    await _updateChannel.invokeMethod<void>('openInstallPermissionSettings');
  }

  /// Hands the verified APK to Android's PackageInstaller. The system then
  /// shows its own confirmation; Android refuses an APK with another signature.
  Future<void> installAndroidApk(File apk, String expectedName) async {
    _ensureChannel();
    if (p.basename(apk.path) != expectedName || !await apk.exists()) {
      throw const UpdateException('更新安装包不存在，请重新下载');
    }
    await _diagnostics.log('update_install_requested');
    try {
      await _updateChannel.invokeMethod<void>('installApk', {
        'path': apk.path,
      });
    } on PlatformException catch (error) {
      throw UpdateException('无法启动安装：${error.message ?? error.code}');
    }
  }

  // ---------------------------------------------------------------- Windows

  /// Prepares the new files while the app is still running, so most failures
  /// are reported here instead of after the app has closed.
  Future<WindowsUpdatePlan> prepareWindowsUpdate(
    File zip,
    AvailableUpdate update, {
    String? executablePath,
  }) async {
    final executable = File(executablePath ?? Platform.resolvedExecutable);
    final installDirectory = executable.parent;
    if (p.basename(executable.path).toLowerCase() !=
        windowsLauncherName.toLowerCase()) {
      throw const UpdateException(
        '当前程序不是安装包里的“猛人快传.exe”，无法自动替换，请手动下载更新',
      );
    }
    final probe = File(
      p.join(installDirectory.path, '.mengren-update-probe-$pid'),
    );
    try {
      await probe.writeAsString('probe', flush: true);
      await probe.delete();
    } catch (_) {
      throw const UpdateException(
        '程序所在文件夹不允许写入（例如放在 Program Files 里），请手动下载更新',
      );
    }
    _busy = true;
    try {
      final directory = await cacheDirectory();
      final script = File(p.join(directory.path, _scriptFileName));
      await script.writeAsString(windowsUpdateScript, flush: true);
      final staging = Directory(p.join(directory.path, 'staging-${update.version}'));
      final extract = await Process.run('powershell.exe', [
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        script.path,
        '-Mode',
        'extract',
        '-Zip',
        zip.path,
        '-Staging',
        staging.path,
      ]).timeout(const Duration(minutes: 3));
      if (extract.exitCode != 0) {
        await _diagnostics.log(
          'update_extract_failed code=${extract.exitCode} '
          'stderr=${'${extract.stderr}'.trim()}',
        );
        throw const UpdateException('解压更新包失败，请手动下载更新');
      }
      for (final required in [windowsLauncherName, p.join('data', 'app.so')]) {
        if (!await File(p.join(staging.path, required)).exists()) {
          throw UpdateException('更新包内容不完整（缺少 $required），已停止更新');
        }
      }
      await _diagnostics.log('update_prepared version=${update.version}');
      return WindowsUpdatePlan(
        script: script,
        staging: staging,
        installDirectory: installDirectory,
        executableName: p.basename(executable.path),
        backup: Directory(p.join(directory.path, 'backup')),
        resultFile: File(p.join(directory.path, _resultFileName)),
        startedFile: File(p.join(directory.path, _startedFileName)),
        version: update.version,
      );
    } catch (_) {
      _busy = false;
      rethrow;
    }
  }

  /// Starts the apply script as an independent hidden process and waits until
  /// it reports that it is running. The caller must exit the app right after;
  /// the script waits for this process to end before copying.
  ///
  /// Windows PowerShell 5.1 started with ProcessStartMode.detached (no
  /// console) exits at once without running anything, so a short-lived
  /// PowerShell relays the launch through Start-Process instead.
  Future<void> launchWindowsApply(
    WindowsUpdatePlan plan, {
    int? processId,
    bool restart = true,
    Duration startTimeout = const Duration(seconds: 15),
  }) async {
    try {
      await _deleteQuietly(plan.startedFile);
      await _deleteQuietly(plan.resultFile);
      final argumentLine = plan
          .applyArguments(processId: processId ?? pid, restart: restart)
          .map(quoteWindowsArgument)
          .join(' ')
          .replaceAll("'", "''");
      final relay = await Process.run('powershell.exe', [
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'Bypass',
        '-Command',
        "Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden "
            "-WorkingDirectory '${plan.staging.parent.path.replaceAll("'", "''")}' "
            "-ArgumentList '$argumentLine'",
      ]).timeout(const Duration(seconds: 30));
      if (relay.exitCode != 0) {
        throw StateError(
          'relay exit=${relay.exitCode} ${'${relay.stderr}'.trim()}',
        );
      }
      final deadline = DateTime.now().add(startTimeout);
      while (!await plan.startedFile.exists()) {
        if (DateTime.now().isAfter(deadline)) {
          throw StateError('apply script did not report start');
        }
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    } catch (error) {
      _busy = false;
      await _diagnostics.log('update_apply_launch_failed', error: error);
      throw const UpdateException('更新程序没能启动，猛人快传不会关闭；请去网页手动下载更新');
    }
    await _diagnostics.log('update_apply_launched version=${plan.version}');
  }

  Future<void> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }
}

class WindowsUpdatePlan {
  const WindowsUpdatePlan({
    required this.script,
    required this.staging,
    required this.installDirectory,
    required this.executableName,
    required this.backup,
    required this.resultFile,
    required this.startedFile,
    required this.version,
  });

  final File script;
  final Directory staging;
  final Directory installDirectory;
  final String executableName;
  final Directory backup;
  final File resultFile;
  final File startedFile;
  final String version;

  List<String> applyArguments({
    required int processId,
    bool restart = true,
    int retries = 10,
  }) => [
    '-NoProfile',
    '-NonInteractive',
    '-ExecutionPolicy',
    'Bypass',
    '-File',
    script.path,
    '-Mode',
    'apply',
    '-ProcessId',
    '$processId',
    '-Staging',
    staging.path,
    '-Target',
    installDirectory.path,
    '-ExeName',
    executableName,
    '-Backup',
    backup.path,
    '-ResultFile',
    resultFile.path,
    '-StartedFile',
    startedFile.path,
    '-Version',
    version,
    '-Retries',
    '$retries',
    if (!restart) '-NoRestart',
  ];
}

enum AndroidInstallStatusKind { pendingUserAction, success, cancelled, failure }

class AndroidInstallStatus {
  const AndroidInstallStatus(this.kind, this.code, this.message);

  factory AndroidInstallStatus.fromNative(
    String status,
    int? code,
    String? message,
  ) {
    final kind = switch (status) {
      'pending_user_action' => AndroidInstallStatusKind.pendingUserAction,
      'success' => AndroidInstallStatusKind.success,
      'cancelled' => AndroidInstallStatusKind.cancelled,
      _ => AndroidInstallStatusKind.failure,
    };
    return AndroidInstallStatus(kind, code, message);
  }

  final AndroidInstallStatusKind kind;
  final int? code;
  final String? message;

  /// Readable explanation of Android PackageInstaller failure codes.
  String get description => switch (kind) {
    AndroidInstallStatusKind.pendingUserAction => '等待你在系统窗口里确认安装',
    AndroidInstallStatusKind.success => '安装完成',
    AndroidInstallStatusKind.cancelled => '已取消安装，可以稍后在设置里重新更新',
    AndroidInstallStatusKind.failure => switch (code) {
      2 => '安装被系统或手机管家拦截，请允许后重试，或手动安装',
      4 => '安装包无效，请重新下载',
      5 => '安装包签名与已安装版本不同，系统拒绝覆盖（为了防止被冒充）',
      6 => '手机存储空间不足，清理后再试',
      7 => '这台手机不兼容新版本',
      _ => '安装失败${message == null || message!.isEmpty ? '' : '：$message'}',
    },
  };
}

/// Accepts `host:port` or the per-protocol form `http=h:p;https=h:p`.
String? parseWindowsProxyServer(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) return null;
  if (!trimmed.contains('=')) {
    return trimmed.replaceFirst(RegExp(r'^https?://'), '');
  }
  final entries = <String, String>{};
  for (final part in trimmed.split(';')) {
    final index = part.indexOf('=');
    if (index <= 0) continue;
    entries[part.substring(0, index).trim().toLowerCase()] = part
        .substring(index + 1)
        .trim()
        .replaceFirst(RegExp(r'^https?://'), '');
  }
  final chosen = entries['https'] ?? entries['http'];
  return chosen == null || chosen.isEmpty ? null : chosen;
}

Future<String> _sha256Of(File file) async {
  final capture = _DigestCapture();
  final hasher = sha256.startChunkedConversion(capture);
  await for (final chunk in file.openRead()) {
    hasher.add(chunk);
  }
  hasher.close();
  return capture.value.toString();
}

class _DigestCapture implements Sink<Digest> {
  Digest? _value;

  Digest get value => _value!;

  @override
  void add(Digest data) => _value = data;

  @override
  void close() {}
}
