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

  /// Logs what can stop background receiving, so a diagnostic export shows
  /// whether the battery exemption and notifications were granted.
  static Future<void> logStatus() async {
    if (!isSupported) return;
    try {
      final status = await _channel.invokeMapMethod<String, Object?>('status');
      await DiagnosticLogService.instance.log(
        'background_receive_status '
        'manufacturer=${status?['manufacturer']} '
        'service=${status?['serviceRunning']} '
        'ignoring_battery=${status?['ignoringBattery']} '
        'notifications=${status?['notificationsEnabled']}',
      );
    } catch (_) {}
  }

  /// Opens the phone vendor's auto-launch / background page (Huawei, Honor,
  /// Xiaomi, OPPO, vivo, Meizu), or the app's system info page.
  static Future<void> openVendorBackgroundSettings() async {
    if (!isSupported) return;
    try {
      final page = await _channel.invokeMethod<String>(
        'openVendorBackgroundSettings',
      );
      await DiagnosticLogService.instance.log(
        'vendor_background_settings_opened page=$page',
      );
    } catch (_) {}
  }

  static Future<void> requestIgnoreBatteryOptimizations() async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod<void>('requestIgnoreBatteryOptimizations');
    } catch (_) {}
  }
}
