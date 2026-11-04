import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum AppThemeColor {
  ruby('宝石红', Color(0xFFB0283A)),
  green('墨绿', Color(0xFF176B5B)),
  blue('蓝色', Color(0xFF2962A3)),
  purple('紫色', Color(0xFF6E4AA5)),
  orange('橙色', Color(0xFF9A5718)),
  rose('玫红', Color(0xFF9A3D61));

  const AppThemeColor(this.label, this.seedColor);

  final String label;
  final Color seedColor;
}

enum AppThemeMode {
  light('浅色'),
  dark('深色'),
  system('跟随系统');

  const AppThemeMode(this.label);

  final String label;

  ThemeMode get materialMode => switch (this) {
    AppThemeMode.light => ThemeMode.light,
    AppThemeMode.dark => ThemeMode.dark,
    AppThemeMode.system => ThemeMode.system,
  };
}

/// Whether incoming LAN files start without the "接收文件？" dialog. Remote
/// (VPS) files never ask; they are already capped at 200 MiB.
enum AutoAcceptMode {
  all('局域网内所有设备', '局域网里任何设备发来的文件都直接接收'),
  known('只限连接过的设备', '给它发过东西、配对过或手动接收过它文件的设备直接接收，陌生设备仍会询问'),
  ask('每次都询问', '每个文件都弹窗确认，60 秒没点就自动拒绝');

  const AutoAcceptMode(this.label, this.description);

  final String label;
  final String description;
}

class AppSettings {
  const AppSettings({
    this.themeColor = AppThemeColor.ruby,
    this.themeMode = AppThemeMode.light,
    this.launchAtStartup = false,
    this.windowsSaveDirectory,
    this.androidTreeUri,
    this.androidSaveLabel = '系统下载/猛人快传',
    this.autoCheckUpdates = true,
    this.autoAcceptMode = AutoAcceptMode.known,
    this.androidBackgroundReceive = false,
  });

  final AppThemeColor themeColor;
  final AppThemeMode themeMode;
  final bool launchAtStartup;
  final String? windowsSaveDirectory;
  final String? androidTreeUri;
  final String androidSaveLabel;
  final bool autoCheckUpdates;
  final AutoAcceptMode autoAcceptMode;

  /// Android only: keep a foreground service so discovery, the receiver and
  /// the VPS connection keep running while the app is in the background.
  final bool androidBackgroundReceive;

  bool get usesCustomAndroidDirectory => androidTreeUri != null;

  AppSettings copyWith({
    AppThemeColor? themeColor,
    AppThemeMode? themeMode,
    bool? launchAtStartup,
    String? windowsSaveDirectory,
    String? androidTreeUri,
    String? androidSaveLabel,
    bool? autoCheckUpdates,
    AutoAcceptMode? autoAcceptMode,
    bool? androidBackgroundReceive,
    bool clearAndroidDirectory = false,
    bool clearWindowsDirectory = false,
  }) {
    return AppSettings(
      themeColor: themeColor ?? this.themeColor,
      themeMode: themeMode ?? this.themeMode,
      launchAtStartup: launchAtStartup ?? this.launchAtStartup,
      windowsSaveDirectory: clearWindowsDirectory
          ? null
          : windowsSaveDirectory ?? this.windowsSaveDirectory,
      androidTreeUri: clearAndroidDirectory
          ? null
          : androidTreeUri ?? this.androidTreeUri,
      androidSaveLabel: clearAndroidDirectory
          ? '系统下载/猛人快传'
          : androidSaveLabel ?? this.androidSaveLabel,
      autoCheckUpdates: autoCheckUpdates ?? this.autoCheckUpdates,
      autoAcceptMode: autoAcceptMode ?? this.autoAcceptMode,
      androidBackgroundReceive:
          androidBackgroundReceive ?? this.androidBackgroundReceive,
    );
  }
}

class AppSettingsStore {
  static const _themeKey = 'settings_theme_color';
  static const _themeModeKey = 'settings_theme_mode';
  static const _startupKey = 'settings_launch_at_startup';
  static const _windowsDirectoryKey = 'settings_windows_save_directory';
  static const _androidTreeKey = 'settings_android_tree_uri';
  static const _androidLabelKey = 'settings_android_save_label';
  static const _autoCheckUpdatesKey = 'settings_auto_check_updates';
  static const _autoAcceptKey = 'settings_auto_accept_mode';
  static const _backgroundReceiveKey = 'settings_android_background_receive';

  Future<AppSettings> load() async {
    final preferences = await SharedPreferences.getInstance();
    final themeName = preferences.getString(_themeKey);
    final theme = AppThemeColor.values.where(
      (candidate) => candidate.name == themeName,
    );
    final themeModeName = preferences.getString(_themeModeKey);
    final themeMode = AppThemeMode.values.where(
      (candidate) => candidate.name == themeModeName,
    );
    final autoAcceptName = preferences.getString(_autoAcceptKey);
    final autoAccept = AutoAcceptMode.values.where(
      (candidate) => candidate.name == autoAcceptName,
    );
    return AppSettings(
      themeColor: theme.isEmpty ? AppThemeColor.ruby : theme.first,
      themeMode: themeMode.isEmpty ? AppThemeMode.light : themeMode.first,
      launchAtStartup: preferences.getBool(_startupKey) ?? false,
      windowsSaveDirectory: preferences.getString(_windowsDirectoryKey),
      androidTreeUri: preferences.getString(_androidTreeKey),
      androidSaveLabel: preferences.getString(_androidLabelKey) ?? '系统下载/猛人快传',
      autoCheckUpdates: preferences.getBool(_autoCheckUpdatesKey) ?? true,
      autoAcceptMode: autoAccept.isEmpty
          ? AutoAcceptMode.known
          : autoAccept.first,
      androidBackgroundReceive:
          preferences.getBool(_backgroundReceiveKey) ?? false,
    );
  }

  Future<void> save(AppSettings settings) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_themeKey, settings.themeColor.name);
    await preferences.setString(_themeModeKey, settings.themeMode.name);
    await preferences.setBool(_startupKey, settings.launchAtStartup);
    if (settings.windowsSaveDirectory == null) {
      await preferences.remove(_windowsDirectoryKey);
    } else {
      await preferences.setString(
        _windowsDirectoryKey,
        settings.windowsSaveDirectory!,
      );
    }
    if (settings.androidTreeUri == null) {
      await preferences.remove(_androidTreeKey);
    } else {
      await preferences.setString(_androidTreeKey, settings.androidTreeUri!);
    }
    await preferences.setString(_androidLabelKey, settings.androidSaveLabel);
    await preferences.setBool(_autoCheckUpdatesKey, settings.autoCheckUpdates);
    await preferences.setString(_autoAcceptKey, settings.autoAcceptMode.name);
    await preferences.setBool(
      _backgroundReceiveKey,
      settings.androidBackgroundReceive,
    );
  }
}
