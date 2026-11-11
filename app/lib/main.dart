import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';

import 'src/app.dart';
import 'src/app_version.dart';
import 'src/chat/clipboard_files.dart';
import 'src/device/device_identity.dart';
import 'src/desktop/desktop_tray_service.dart';
import 'src/desktop/startup_launch.dart';
import 'src/diagnostics/diagnostic_log_service.dart';
import 'src/image_view/desktop_viewer_app.dart';
import 'src/image_view/viewer_protocol.dart';
import 'src/pairing/pairing_endpoint.dart';
import 'src/remote/remote_access_settings.dart';
import 'src/settings/app_settings.dart';
import 'src/update/app_update_service.dart';
import 'src/voice/speech_service.dart';
import 'src/voice/voice_store.dart';

Future<void> main(List<String> arguments) async {
  // Windows picture window (started by the chat window, like WeChat for
  // PC): no network, tray, logs or settings — only the viewer.
  if (Platform.isWindows && isImageViewerLaunch(arguments)) {
    await runImageViewerProcess();
    return;
  }
  WidgetsFlutterBinding.ensureInitialized();
  // Full-resolution phone photos can otherwise occupy tens of megabytes each
  // in Flutter's decoded image cache. Chat thumbnails do not need that budget.
  PaintingBinding.instance.imageCache
    ..maximumSize = 50
    ..maximumSizeBytes = 32 * 1024 * 1024;

  final diagnostics = DiagnosticLogService.instance;
  await diagnostics.initialize();
  final previousFlutterError = FlutterError.onError;
  FlutterError.onError = (details) {
    unawaited(
      diagnostics.log(
        'flutter_error',
        error: details.exception,
        stackTrace: details.stack,
      ),
    );
    previousFlutterError?.call(details);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    unawaited(
      diagnostics.log('uncaught_async_error', error: error, stackTrace: stack),
    );
    return true;
  };
  await diagnostics.log(
    'app_start version=$appVersion platform=${Platform.operatingSystem}'
    '${isSilentStart(arguments) ? ' silent=true' : ''}',
  );

  try {
    final store = DeviceIdentityStore();
    final identity = await store.loadOrCreate();
    final pairingCode = await PairingStore().loadOrCreateCode();
    final settingsStore = AppSettingsStore();
    final settings = await settingsStore.load();
    final remoteSettingsStore = RemoteAccessSettingsStore();
    var remoteSettings = const RemoteAccessSettings();
    try {
      remoteSettings = await remoteSettingsStore.load();
    } catch (error, stackTrace) {
      await diagnostics.log(
        'remote_secure_settings_load_failed',
        error: error,
        stackTrace: stackTrace,
      );
    }
    if (AppUpdateService.isSupportedPlatform) {
      try {
        await AppUpdateService.instance.cleanupOnStartup();
      } catch (error, stackTrace) {
        await diagnostics.log(
          'update_cache_cleanup_failed',
          error: error,
          stackTrace: stackTrace,
        );
      }
    }
    // Pasted pictures and forwarded copies: 30 days / 1 GiB, plus anything a
    // crash left half-written.
    try {
      final removed = await OutgoingCache.instance.cleanup();
      if (removed > 0) {
        await diagnostics.log('outgoing_cache_cleaned bytes=$removed');
      }
    } catch (error, stackTrace) {
      await diagnostics.log(
        'outgoing_cache_cleanup_failed',
        error: error,
        stackTrace: stackTrace,
      );
    }
    // Voice messages: 30 days / 500 MB and recordings a crash left behind;
    // the speech model: stale partial downloads.
    try {
      final removed = await VoiceStore.instance.cleanup();
      if (removed > 0) {
        await diagnostics.log('voice_store_cleaned bytes=$removed');
      }
      await SpeechModel.instance.cleanup();
    } catch (error, stackTrace) {
      await diagnostics.log(
        'voice_cleanup_failed',
        error: error,
        stackTrace: stackTrace,
      );
    }
    await DesktopTrayService.instance.initialize();
    if (Platform.isWindows && settings.launchAtStartup) {
      try {
        await applyLaunchAtStartup(
          enabled: true,
          silent: settings.silentStartup,
        );
      } catch (error, stackTrace) {
        await diagnostics.log(
          'launch_at_startup_refresh_failed',
          error: error,
          stackTrace: stackTrace,
        );
      }
    }

    runApp(
      LanTransferApp(
        initialIdentity: identity,
        pairingCode: pairingCode,
        initialSettings: settings,
        initialRemoteSettings: remoteSettings,
        saveSettings: settingsStore.save,
        saveRemoteSettings: remoteSettingsStore.save,
        saveIdentity: store.save,
      ),
    );
  } catch (error, stackTrace) {
    await diagnostics.log(
      'startup_failed',
      error: error,
      stackTrace: stackTrace,
    );
    rethrow;
  }
}
