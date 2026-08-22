import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:launch_at_startup/launch_at_startup.dart';

import 'src/app.dart';
import 'src/app_version.dart';
import 'src/device/device_identity.dart';
import 'src/desktop/desktop_tray_service.dart';
import 'src/diagnostics/diagnostic_log_service.dart';
import 'src/pairing/pairing_endpoint.dart';
import 'src/settings/app_settings.dart';

Future<void> main() async {
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
    'app_start version=$appVersion platform=${Platform.operatingSystem}',
  );

  try {
    final store = DeviceIdentityStore();
    final identity = await store.loadOrCreate();
    final pairingCode = await PairingStore().loadOrCreateCode();
    final settingsStore = AppSettingsStore();
    final settings = await settingsStore.load();
    await DesktopTrayService.instance.initialize();
    if (Platform.isWindows && settings.launchAtStartup) {
      launchAtStartup.setup(
        appName: '猛人快传',
        appPath: Platform.resolvedExecutable,
      );
      await launchAtStartup.enable();
    }

    runApp(
      LanTransferApp(
        initialIdentity: identity,
        pairingCode: pairingCode,
        initialSettings: settings,
        saveSettings: settingsStore.save,
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
