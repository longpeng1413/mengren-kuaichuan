import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum AppThemeColor {
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

class AppSettings {
  const AppSettings({
    this.themeColor = AppThemeColor.green,
    this.themeMode = AppThemeMode.light,
    this.launchAtStartup = false,
    this.windowsSaveDirectory,
    this.androidTreeUri,
    this.androidSaveLabel = '系统下载/猛人快传',
  });

  final AppThemeColor themeColor;
  final AppThemeMode themeMode;
  final bool launchAtStartup;
  final String? windowsSaveDirectory;
  final String? androidTreeUri;
  final String androidSaveLabel;

  bool get usesCustomAndroidDirectory => androidTreeUri != null;

  AppSettings copyWith({
    AppThemeColor? themeColor,
    AppThemeMode? themeMode,
    bool? launchAtStartup,
    String? windowsSaveDirectory,
    String? androidTreeUri,
    String? androidSaveLabel,
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
    return AppSettings(
      themeColor: theme.isEmpty ? AppThemeColor.green : theme.first,
      themeMode: themeMode.isEmpty ? AppThemeMode.light : themeMode.first,
      launchAtStartup: preferences.getBool(_startupKey) ?? false,
      windowsSaveDirectory: preferences.getString(_windowsDirectoryKey),
      androidTreeUri: preferences.getString(_androidTreeKey),
      androidSaveLabel: preferences.getString(_androidLabelKey) ?? '系统下载/猛人快传',
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
  }
}
