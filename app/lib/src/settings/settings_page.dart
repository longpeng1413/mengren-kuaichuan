import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:launch_at_startup/launch_at_startup.dart';

import '../app_version.dart';
import '../diagnostics/diagnostic_log_service.dart';
import '../storage/received_file_service.dart';
import 'app_settings.dart';

typedef SaveAppSettings = Future<void> Function(AppSettings settings);

class SettingsPage extends StatefulWidget {
  const SettingsPage({
    required this.initialSettings,
    required this.saveSettings,
    super.key,
  });

  final AppSettings initialSettings;
  final SaveAppSettings saveSettings;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final ReceivedFileService _fileService = ReceivedFileService();
  final DiagnosticLogService _diagnostics = DiagnosticLogService.instance;
  late AppSettings _settings;
  bool _working = false;
  DiagnosticLogInfo? _diagnosticInfo;

  @override
  void initState() {
    super.initState();
    _settings = widget.initialSettings;
    if (Platform.isAndroid) _refreshDiagnosticInfo();
  }

  Future<void> _refreshDiagnosticInfo() async {
    final info = await _diagnostics.info();
    if (mounted) setState(() => _diagnosticInfo = info);
  }

  Future<void> _exportDiagnostics() async {
    if (_working) return;
    setState(() => _working = true);
    try {
      await _diagnostics.log('diagnostics_export_requested');
      final location = await _diagnostics.export();
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('诊断日志已导出到：$location')));
      }
    } catch (error) {
      _showError('导出诊断日志失败：$error');
    } finally {
      if (mounted) setState(() => _working = false);
      await _refreshDiagnosticInfo();
    }
  }

  Future<void> _clearDiagnostics() async {
    if (_working) return;
    setState(() => _working = true);
    try {
      await _diagnostics.clear();
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('诊断日志已清除')));
      }
    } catch (error) {
      _showError('清除诊断日志失败：$error');
    } finally {
      if (mounted) setState(() => _working = false);
      await _refreshDiagnosticInfo();
    }
  }

  Future<void> _save(AppSettings settings) async {
    setState(() => _settings = settings);
    await widget.saveSettings(settings);
  }

  Future<void> _toggleStartup(bool enabled) async {
    if (!Platform.isWindows || _working) return;
    setState(() => _working = true);
    try {
      launchAtStartup.setup(
        appName: '猛人快传',
        appPath: Platform.resolvedExecutable,
      );
      final succeeded = enabled
          ? await launchAtStartup.enable()
          : await launchAtStartup.disable();
      if (!succeeded) throw Exception('Windows 没有接受自启动设置');
      await _save(_settings.copyWith(launchAtStartup: enabled));
    } catch (error) {
      _showError('设置开机自启动失败：$error');
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _chooseDirectory() async {
    if (_working) return;
    setState(() => _working = true);
    try {
      if (Platform.isWindows) {
        final selected = await FilePicker.platform.getDirectoryPath(
          dialogTitle: '选择猛人快传默认保存文件夹',
        );
        if (selected != null) {
          await Directory(selected).create(recursive: true);
          await _save(_settings.copyWith(windowsSaveDirectory: selected));
        }
      } else if (Platform.isAndroid) {
        final selected = await _fileService.pickAndroidDirectory();
        if (selected != null) {
          await _save(
            _settings.copyWith(
              androidTreeUri: selected.uri,
              androidSaveLabel: selected.label,
            ),
          );
        }
      }
    } catch (error) {
      _showError('选择保存文件夹失败：$error');
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _useDefaultDirectory() async {
    if (Platform.isAndroid) {
      await _save(_settings.copyWith(clearAndroidDirectory: true));
    } else {
      await _save(_settings.copyWith(clearWindowsDirectory: true));
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final saveLocation = Platform.isAndroid
        ? _settings.androidSaveLabel
        : _settings.windowsSaveDirectory ?? 'Windows 下载/猛人快传';
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('外观', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 10),
          SegmentedButton<AppThemeMode>(
            segments: AppThemeMode.values
                .map(
                  (mode) => ButtonSegment<AppThemeMode>(
                    value: mode,
                    label: Text(mode.label),
                    icon: Icon(switch (mode) {
                      AppThemeMode.light => Icons.light_mode_outlined,
                      AppThemeMode.dark => Icons.dark_mode_outlined,
                      AppThemeMode.system => Icons.brightness_auto_outlined,
                    }),
                  ),
                )
                .toList(),
            selected: {_settings.themeMode},
            onSelectionChanged: (selection) =>
                _save(_settings.copyWith(themeMode: selection.first)),
          ),
          const SizedBox(height: 16),
          Text('强调色', style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: AppThemeColor.values
                .map(
                  (theme) => ChoiceChip(
                    selected: _settings.themeColor == theme,
                    avatar: CircleAvatar(backgroundColor: theme.seedColor),
                    label: Text(theme.label),
                    onSelected: (_) =>
                        _save(_settings.copyWith(themeColor: theme)),
                  ),
                )
                .toList(),
          ),
          const SizedBox(height: 22),
          Text('常规', style: Theme.of(context).textTheme.titleMedium),
          if (Platform.isWindows)
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('开机自启动'),
              subtitle: const Text('登录 Windows 后自动启动猛人快传'),
              value: _settings.launchAtStartup,
              onChanged: _working ? null : _toggleStartup,
            ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.folder_outlined),
            title: const Text('默认文件保存位置'),
            subtitle: Text(saveLocation),
            trailing: const Icon(Icons.chevron_right),
            onTap: _working ? null : _chooseDirectory,
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: _working ? null : _useDefaultDirectory,
              child: Text(
                Platform.isAndroid ? '恢复为系统下载/猛人快传' : '恢复为 Windows 下载/猛人快传',
              ),
            ),
          ),
          if (Platform.isAndroid) ...[
            const Divider(height: 32),
            Text('诊断', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.bug_report_outlined),
              title: const Text('导出诊断日志'),
              subtitle: Text(
                '当前 ${_formatDiagnosticBytes(_diagnosticInfo?.bytes ?? 0)}；'
                '单份最多 1 MB，仅保留当前和上一份，7 天自动清理',
              ),
              trailing: const Icon(Icons.download_outlined),
              onTap: _working ? null : _exportDiagnostics,
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.delete_sweep_outlined),
              title: const Text('清除诊断日志'),
              subtitle: const Text('只删除运行日志，不影响聊天记录和已接收文件'),
              onTap: _working ? null : _clearDiagnostics,
            ),
          ],
          const Divider(height: 32),
          const ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.info_outline),
            title: Text(appVersionLabel),
            subtitle: Text('纯局域网传输，不经过公网服务器'),
          ),
        ],
      ),
    );
  }
}

String _formatDiagnosticBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}
