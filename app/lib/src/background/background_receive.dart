import 'dart:io';

import 'package:flutter/services.dart';

import '../diagnostics/diagnostic_log_service.dart';

/// Android "keep receiving in the background": starts or stops the native
/// foreground service and posts notifications for items received meanwhile.
/// Every call is a no-op on other platforms.
class BackgroundReceive {
  BackgroundReceive._();

  static const _channel = MethodChannel(
    'com.personal.lantransfer.lan_transfer/background',
  );

  static bool get isSupported => Platform.isAndroid;

  /// [askPermission] asks for the notification permission (Android 13+);
  /// pass it only when the user has just turned the option on. Returns
  /// whether the service (and its multicast lock) is really running.
  static Future<bool> start({bool askPermission = false}) async {
    if (!isSupported) return false;
    try {
      await _channel.invokeMethod<void>('start', {
        'askPermission': askPermission,
      });
      return true;
    } catch (error) {
      await DiagnosticLogService.instance.log(
        'background_receive_start_failed',
        error: error,
      );
      return false;
    }
  }

  static Future<void> stop() async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod<void>('stop');
    } catch (_) {}
  }

  static Future<void> notify(String title, String text) async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod<void>('notify', {
        'title': title,
        'text': text,
      });
    } catch (_) {}
  }

  static Future<bool> isIgnoringBatteryOptimizations() async {
    if (!isSupported) return true;
    try {
      return await _channel.invokeMethod<bool>(
            'isIgnoringBatteryOptimizations',
          ) ??
          true;
    } catch (_) {
      return true;
    }
  }

  static Future<void> requestIgnoreBatteryOptimizations() async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod<void>('requestIgnoreBatteryOptimizations');
    } catch (_) {}
  }
}
