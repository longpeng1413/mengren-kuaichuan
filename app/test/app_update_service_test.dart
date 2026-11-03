import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lan_transfer/src/update/app_update_service.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('release rules', () {
    test('compares versions and rejects pre-release tags', () {
      final current = AppSemVersion.tryParse('1.7.8+26')!;
      expect(AppSemVersion.tryParse('v1.8.0')! > current, isTrue);
      expect(AppSemVersion.tryParse('v1.10.0')! > AppSemVersion.tryParse('1.9.9')!, isTrue);
      expect(AppSemVersion.tryParse('v1.7.8'), current);
      expect(AppSemVersion.tryParse('v1.7.7-rc.2'), isNull);
      expect(AppSemVersion.tryParse('latest'), isNull);
    });

    test('picks the installer for each platform', () {
      final release = _release('v1.8.1');
      final android = parseLatestRelease(
        release,
        currentVersion: '1.8.0',
        platform: UpdatePlatform.android,
      );
      final windows = parseLatestRelease(
        release,
        currentVersion: '1.8.0',
        platform: UpdatePlatform.windows,
      );
      expect(android, isA<UpdateFound>());
      expect(
        (android as UpdateFound).update.asset.name,
        'mengren-transfer-android-v1.8.1.apk',
      );
      expect(android.update.asset.sha256, 'a' * 64);
      expect(android.update.checksumAsset?.name, 'SHA256SUMS-v1.8.1.txt');
      expect(android.update.notes, '新功能\n- 一键更新');
      expect(
        (windows as UpdateFound).update.asset.name,
        'mengren-transfer-windows-x64-v1.8.1.zip',
      );
    });

    test('pinyin asset names from v1.8.1 are found, legacy names still work', () {
      Map<String, Object?> asset(String name) => {
        'name': name,
        'size': 10,
        'browser_download_url': 'https://example.com/$name',
        'digest': 'sha256:${'b' * 64}',
      };
      String? picked(List<String> names, UpdatePlatform platform) {
        final result = parseLatestRelease(
          {
            ..._release('v1.8.1'),
            'assets': [for (final name in names) asset(name)],
          },
          currentVersion: '1.8.0',
          platform: platform,
        );
        return result is UpdateFound ? result.update.asset.name : null;
      }

      const pinyinApk = 'mengren-kuaichuan-android-v1.8.1.apk';
      const pinyinZip = 'mengren-kuaichuan-windows-x64-v1.8.1.zip';
      expect(picked([pinyinApk, pinyinZip], UpdatePlatform.android), pinyinApk);
      expect(picked([pinyinApk, pinyinZip], UpdatePlatform.windows), pinyinZip);
      expect(
        picked([
          'mengren-transfer-android-v1.8.1.apk',
          pinyinApk,
        ], UpdatePlatform.android),
        pinyinApk,
      );
      // A lone installer with an unexpected name is still picked.
      expect(picked(['other.apk'], UpdatePlatform.android), 'other.apk');
    });

    test('same, older, draft and pre-release releases are not offered', () {
      for (final release in [
        _release('v1.8.0'),
        _release('v1.7.9'),
        {..._release('v1.9.0'), 'prerelease': true},
        {..._release('v1.9.0'), 'draft': true},
        _release('v1.9.0-rc.1'),
      ]) {
        expect(
          parseLatestRelease(
            release,
            currentVersion: '1.8.0',
            platform: UpdatePlatform.android,
          ),
          isA<UpdateUpToDate>(),
        );
      }
    });

    test('a newer release without this platform installer is reported', () {
      final release = {..._release('v1.8.1'), 'assets': <Object>[]};
      expect(
        parseLatestRelease(
          release,
          currentVersion: '1.8.0',
          platform: UpdatePlatform.windows,
        ),
        isA<UpdateWithoutInstaller>(),
      );
    });

    test('checksum file parsing and digest agreement', () {
      final sums = parseSha256Sums(
        '${'A' * 64}  mengren-transfer-android-v1.8.1.apk\n'
        '${'b' * 64} *猛人快传.exe\n'
        'not a checksum line\n',
      );
      expect(sums['mengren-transfer-android-v1.8.1.apk'], 'a' * 64);
      expect(sums['猛人快传.exe'], 'b' * 64);

      expect(
        resolveExpectedSha256(assetDigest: 'a' * 64, checksumFileDigest: null),
        'a' * 64,
      );
      expect(
        resolveExpectedSha256(assetDigest: null, checksumFileDigest: 'b' * 64),
        'b' * 64,
      );
      expect(
        () => resolveExpectedSha256(
          assetDigest: 'a' * 64,
          checksumFileDigest: 'b' * 64,
        ),
        throwsA(isA<UpdateException>()),
      );
      expect(
        () => resolveExpectedSha256(assetDigest: null, checksumFileDigest: null),
        throwsA(isA<UpdateException>()),
      );
    });

    test('Windows proxy settings and Android failure messages', () {
      expect(parseWindowsProxyServer('127.0.0.1:7890'), '127.0.0.1:7890');
      expect(
        parseWindowsProxyServer('http=127.0.0.1:7890;https=127.0.0.1:7891'),
        '127.0.0.1:7891',
      );
      expect(parseWindowsProxyServer('socks=127.0.0.1:1080'), isNull);
      expect(
        AndroidInstallStatus.fromNative('failure', 5, null).description,
        contains('签名'),
      );
      expect(
        AndroidInstallStatus.fromNative('cancelled', 3, null).kind,
        AndroidInstallStatusKind.cancelled,
      );
    });
  });

  group('download against a local release server', () {
    late Directory cache;
    late _FakeReleaseServer server;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      cache = await Directory.systemTemp.createTemp('mengren_update_test_');
      server = await _FakeReleaseServer.start();
    });

    tearDown(() async {
      await server.close();
      if (await cache.exists()) await cache.delete(recursive: true);
    });

    AppUpdateService service() => AppUpdateService(
      feedUrl: server.uri('/feed'),
      currentVersion: '1.8.0',
      platform: UpdatePlatform.android,
      cacheDirectory: () async => cache,
      allowInsecureHttpForTesting: true,
    );

    test('checks, follows the redirect and verifies the file', () async {
      final updater = service();
      final result = await updater.check();
      expect(result, isA<UpdateFound>());
      final progress = <int>[];
      final file = await updater.download(
        (result as UpdateFound).update,
        onProgress: (received, total) => progress.add(received),
      );
      expect(await file.readAsBytes(), server.payload);
      expect(progress.last, server.payload.length);
      expect(_names(cache), ['mengren-transfer-android-v1.8.1.apk']);
      expect(await updater.shouldAutoCheck(), isFalse);
      expect(
        await updater.shouldAutoCheck(
          now: DateTime.now().add(const Duration(hours: 25)),
        ),
        isTrue,
      );
    });

    test('a tampered download is rejected and deleted', () async {
      server.tamper = true;
      final updater = service();
      final update = (await updater.check() as UpdateFound).update;
      await expectLater(
        updater.download(update),
        throwsA(
          isA<UpdateException>().having(
            (error) => error.message,
            'message',
            contains('校验不通过'),
          ),
        ),
      );
      expect(_names(cache), isEmpty);
      expect(updater.isBusy, isFalse);
    });

    test('conflicting checksum sources stop before downloading', () async {
      server.checksumOverride = 'c' * 64;
      final updater = service();
      final update = (await updater.check() as UpdateFound).update;
      await expectLater(
        updater.download(update),
        throwsA(isA<UpdateException>()),
      );
      expect(server.installerRequests, 0);
      expect(_names(cache), isEmpty);
    });

    test('cancelling mid-download removes the partial file', () async {
      server.slow = true;
      final updater = service();
      final update = (await updater.check() as UpdateFound).update;
      final token = UpdateCancelToken();
      final future = updater.download(
        update,
        cancelToken: token,
        onProgress: (received, _) {
          if (received > 0) token.cancel();
        },
      );
      await expectLater(future, throwsA(isA<UpdateCancelledException>()));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(_names(cache), isEmpty);
    });

    test('startup cleanup reads the last result and empties the cache', () async {
      File(p.join(cache.path, 'old.apk')).writeAsBytesSync(List.filled(10, 1));
      File(p.join(cache.path, 'old.apk.part')).writeAsBytesSync([1, 2]);
      Directory(p.join(cache.path, 'staging-1.8.0', 'data'))
          .createSync(recursive: true);
      File(p.join(cache.path, 'staging-1.8.0', 'data', 'app.so'))
          .writeAsBytesSync([1, 2, 3]);
      File(p.join(cache.path, 'update_result.json')).writeAsStringSync(
        jsonEncode({'ok': false, 'version': '1.8.1', 'message': 'locked'}),
      );
      final updater = service();
      expect(await updater.cacheSize(), greaterThan(15));
      await updater.cleanupOnStartup();
      expect(_names(cache), isEmpty);
      final outcome = updater.takePreviousOutcome();
      expect(outcome?.succeeded, isFalse);
      expect(outcome?.version, '1.8.1');
      expect(updater.takePreviousOutcome(), isNull);

      File(p.join(cache.path, 'again.zip')).writeAsBytesSync([1, 2, 3, 4]);
      expect(await updater.clearCache(), 4);
      expect(await updater.cacheSize(), 0);
    });
  });

  group('Windows apply script', () {
    late Directory root;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('mengren_apply_test_');
    });

    tearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });

    Future<({AppUpdateService service, WindowsUpdatePlan plan, Directory target})>
    prepare() async {
      final package = Directory(p.join(root.path, 'package'));
      _write(package, '猛人快传.exe', 'new exe');
      _write(package, p.join('data', 'app.so'), 'new so');
      _write(package, p.join('data', 'new_plugin.dll'), 'new dll');
      final zip = File(p.join(root.path, 'update.zip'));
      // Same tool as scripts/package_windows.ps1 so path encoding matches.
      String quoted(String value) => "'${value.replaceAll("'", "''")}'";
      final compress = await Process.run('powershell.exe', [
        '-NoProfile',
        '-Command',
        'Compress-Archive -Path (Join-Path ${quoted(package.path)} "*") '
            '-DestinationPath ${quoted(zip.path)}',
      ]);
      expect(compress.exitCode, 0, reason: '${compress.stderr}');

      // Space, Chinese and an apostrophe all pass through the launch quoting.
      final target = Directory(p.join(root.path, "Tom's 安装 目录"));
      _write(target, '猛人快传.exe', 'old exe');
      _write(target, p.join('data', 'app.so'), 'old so');
      _write(target, '用户笔记.txt', 'keep me');

      final cache = Directory(p.join(root.path, 'cache'));
      final service = AppUpdateService(
        currentVersion: '1.8.0',
        platform: UpdatePlatform.windows,
        cacheDirectory: () async => cache,
      );
      final plan = await service.prepareWindowsUpdate(
        zip,
        _availableUpdate('1.8.1'),
        executablePath: p.join(target.path, '猛人快传.exe'),
      );
      return (service: service, plan: plan, target: target);
    }

    Future<void> runApply(WindowsUpdatePlan plan) async {
      // A short-lived process stands in for the app the script waits for.
      final stand = await Process.start('powershell.exe', [
        '-NoProfile',
        '-Command',
        'Start-Sleep -Milliseconds 700',
      ]);
      final result = await Process.run(
        'powershell.exe',
        plan.applyArguments(processId: stand.pid, restart: false, retries: 2),
      );
      expect(result.exitCode, 0, reason: '${result.stderr}');
      expect(await stand.exitCode, 0);
    }

    test(
      'replaces program files, keeps user files and records success',
      () async {
        final prepared = await prepare();
        await runApply(prepared.plan);
        final target = prepared.target;
        expect(_read(target, '猛人快传.exe'), 'new exe');
        expect(_read(target, p.join('data', 'app.so')), 'new so');
        expect(_read(target, p.join('data', 'new_plugin.dll')), 'new dll');
        expect(_read(target, '用户笔记.txt'), 'keep me');
        expect(_read(prepared.plan.backup, '猛人快传.exe'), 'old exe');
        final outcome = jsonDecode(prepared.plan.resultFile.readAsStringSync());
        expect(outcome['ok'], isTrue);
        expect(outcome['version'], '1.8.1');
      },
      skip: Platform.isWindows ? false : 'Windows only',
    );

    test(
      'a failed copy restores the previous version',
      () async {
        final prepared = await prepare();
        final locked = File(
          p.join(prepared.target.path, 'data', 'app.so'),
        ).openSync(mode: FileMode.append);
        locked.lockSync(FileLock.exclusive);
        try {
          await runApply(prepared.plan);
        } finally {
          locked.unlockSync();
          locked.closeSync();
        }
        final target = prepared.target;
        expect(_read(target, '猛人快传.exe'), 'old exe');
        expect(_read(target, p.join('data', 'app.so')), 'old so');
        expect(
          File(p.join(target.path, 'data', 'new_plugin.dll')).existsSync(),
          isFalse,
        );
        expect(_read(target, '用户笔记.txt'), 'keep me');
        final outcome = jsonDecode(prepared.plan.resultFile.readAsStringSync());
        expect(outcome['ok'], isFalse);
      },
      skip: Platform.isWindows ? false : 'Windows only',
    );

    test(
      'the real launch path runs the script as an independent process',
      () async {
        // Same call the app makes; restart off and no process to wait for.
        final prepared = await prepare();
        await prepared.service.launchWindowsApply(
          prepared.plan,
          processId: 0,
          restart: false,
        );
        expect(prepared.plan.startedFile.existsSync(), isTrue);
        final deadline = DateTime.now().add(const Duration(seconds: 30));
        while (!prepared.plan.resultFile.existsSync() &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
        final outcome = jsonDecode(prepared.plan.resultFile.readAsStringSync());
        expect(outcome['ok'], isTrue, reason: '${outcome['message']}');
        expect(_read(prepared.target, '猛人快传.exe'), 'new exe');
        expect(_read(prepared.target, '用户笔记.txt'), 'keep me');
      },
      skip: Platform.isWindows ? false : 'Windows only',
    );

    test('Windows argument quoting survives spaces, quotes and backslashes', () {
      expect(quoteWindowsArgument('plain'), '"plain"');
      expect(quoteWindowsArgument(r'C:\安装 目录'), r'"C:\安装 目录"');
      expect(quoteWindowsArgument('D:\\'), r'"D:\\"');
      expect(quoteWindowsArgument(r'a\"b'), r'"a\\\"b"');
      expect(quoteWindowsArgument("O'Brien"), "\"O'Brien\"");
    });

    test(
      'refuses unexpected launchers and incomplete packages',
      () async {
        final cache = Directory(p.join(root.path, 'cache'));
        final service = AppUpdateService(
          currentVersion: '1.8.0',
          platform: UpdatePlatform.windows,
          cacheDirectory: () async => cache,
        );
        await expectLater(
          service.prepareWindowsUpdate(
            File(p.join(root.path, 'missing.zip')),
            _availableUpdate('1.8.1'),
            executablePath: p.join(root.path, 'lan_transfer.exe'),
          ),
          throwsA(isA<UpdateException>()),
        );
        expect(service.isBusy, isFalse);
      },
      skip: Platform.isWindows ? false : 'Windows only',
    );
  });

  // One-off check against the real GitHub release, run manually with
  // MENGREN_LIVE_UPDATE_TEST=1. It pretends to be v1.7.0, downloads the
  // latest Windows package, verifies it and applies it to a temporary folder.
  test(
    'live GitHub update into a temporary folder',
    () async {
      SharedPreferences.setMockInitialValues({});
      final root = await Directory.systemTemp.createTemp('mengren_live_update_');
      try {
        final target = Directory(p.join(root.path, 'install'));
        _write(target, '猛人快传.exe', 'old exe');
        final service = AppUpdateService(
          currentVersion: '1.7.0',
          platform: UpdatePlatform.windows,
          cacheDirectory: () async => Directory(p.join(root.path, 'cache')),
        );
        final result = await service.check();
        expect(result, isA<UpdateFound>());
        final update = (result as UpdateFound).update;
        final zip = await service.download(update);
        final plan = await service.prepareWindowsUpdate(
          zip,
          update,
          executablePath: p.join(target.path, '猛人快传.exe'),
        );
        final apply = await Process.run(
          'powershell.exe',
          plan.applyArguments(processId: 0, restart: false),
        );
        expect(apply.exitCode, 0, reason: '${apply.stderr}');
        expect(jsonDecode(plan.resultFile.readAsStringSync())['ok'], isTrue);
        final exe = File(p.join(target.path, '猛人快传.exe'));
        expect(exe.lengthSync(), greaterThan(10000));
        expect(
          File(p.join(target.path, 'data', 'app.so')).existsSync(),
          isTrue,
        );
        // ignore: avoid_print
        print('live update ok: v${update.version} ${update.asset.name}');
      } finally {
        await root.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 10)),
    skip: Platform.isWindows &&
            Platform.environment['MENGREN_LIVE_UPDATE_TEST'] == '1'
        ? false
        : 'set MENGREN_LIVE_UPDATE_TEST=1 on Windows to run',
  );
}

Map<String, Object?> _release(String tag) {
  final version = tag.replaceFirst('v', '');
  Map<String, Object?> asset(String name) => {
    'name': name,
    'size': 10,
    'browser_download_url': 'https://example.com/$name',
    'digest': 'sha256:${'a' * 64}',
  };
  return {
    'tag_name': tag,
    'name': '猛人快传 $tag',
    'draft': false,
    'prerelease': false,
    'html_url': 'https://github.com/example/releases/tag/$tag',
    'body': '## 新功能\n- **一键更新**',
    'assets': [
      asset('mengren-transfer-android-v$version.apk'),
      asset('mengren-transfer-windows-x64-v$version.zip'),
      asset('SHA256SUMS-v$version.txt'),
    ],
  };
}

AvailableUpdate _availableUpdate(String version) => AvailableUpdate(
  version: version,
  title: 'v$version',
  notes: '',
  pageUrl: null,
  asset: UpdateAsset(
    name: 'mengren-transfer-windows-x64-v$version.zip',
    size: 0,
    downloadUrl: Uri.parse('https://example.com/update.zip'),
  ),
);

List<String> _names(Directory directory) => directory.existsSync()
    ? (directory.listSync().map((entity) => p.basename(entity.path)).toList()
        ..sort())
    : const [];

void _write(Directory root, String relative, String content) {
  final file = File(p.join(root.path, relative));
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(content);
}

String _read(Directory root, String relative) =>
    File(p.join(root.path, relative)).readAsStringSync();

class _FakeReleaseServer {
  _FakeReleaseServer._(this._server);

  final HttpServer _server;
  final List<int> payload = List.generate(300000, (index) => index % 251);
  bool tamper = false;
  bool slow = false;
  String? checksumOverride;
  int installerRequests = 0;

  static const _apk = 'mengren-transfer-android-v1.8.1.apk';

  static Future<_FakeReleaseServer> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fake = _FakeReleaseServer._(server);
    server.listen(fake._handle);
    return fake;
  }

  Uri uri(String path) => Uri.parse('http://127.0.0.1:${_server.port}$path');

  String get _digest => sha256.convert(payload).toString();

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    switch (request.uri.path) {
      case '/feed':
        response.headers.contentType = ContentType.json;
        response.write(
          jsonEncode({
            'tag_name': 'v1.8.1',
            'name': '猛人快传 v1.8.1',
            'draft': false,
            'prerelease': false,
            'body': '更新说明',
            'assets': [
              {
                'name': _apk,
                'size': payload.length,
                'browser_download_url': uri('/redirect').toString(),
                'digest': 'sha256:$_digest',
              },
              {
                'name': 'SHA256SUMS-v1.8.1.txt',
                'size': 100,
                'browser_download_url': uri('/sums').toString(),
              },
            ],
          }),
        );
      case '/sums':
        response.write('${checksumOverride ?? _digest}  $_apk\n');
      case '/redirect':
        response.statusCode = HttpStatus.found;
        response.headers.set(HttpHeaders.locationHeader, uri('/file').toString());
      case '/file':
        installerRequests++;
        response.contentLength = payload.length;
        final body = List.of(payload);
        if (tamper) body[1000] = (body[1000] + 1) % 256;
        if (slow) {
          response.add(body.sublist(0, 4096));
          await response.flush();
          await Future<void>.delayed(const Duration(seconds: 2));
          try {
            response.add(body.sublist(4096));
          } catch (_) {}
        } else {
          response.add(body);
        }
      default:
        response.statusCode = HttpStatus.notFound;
    }
    try {
      await response.close();
    } catch (_) {}
  }

  Future<void> close() => _server.close(force: true);
}
