import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:launch_at_startup/launch_at_startup.dart';

import '../app_version.dart';
import '../diagnostics/diagnostic_log_service.dart';
import '../remote/remote_access_settings.dart';
import '../storage/received_file_service.dart';
import 'app_settings.dart';

typedef SaveAppSettings = Future<void> Function(AppSettings settings);

class SettingsPage extends StatefulWidget {
  const SettingsPage({
    required this.initialSettings,
    required this.saveSettings,
    this.initialRemoteSettings = const RemoteAccessSettings(),
    this.saveRemoteSettings,
    super.key,
  });

  final AppSettings initialSettings;
  final SaveAppSettings saveSettings;
  final RemoteAccessSettings initialRemoteSettings;
  final Future<void> Function(RemoteAccessSettings settings)?
  saveRemoteSettings;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final ReceivedFileService _fileService = ReceivedFileService();
  final DiagnosticLogService _diagnostics = DiagnosticLogService.instance;
  late AppSettings _settings;
  late RemoteAccessSettings _remoteSettings;
  bool _working = false;
  DiagnosticLogInfo? _diagnosticInfo;

  @override
  void initState() {
    super.initState();
    _settings = widget.initialSettings;
    _remoteSettings = widget.initialRemoteSettings;
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

  Future<void> _configureRemoteAccess() async {
    if (_working || widget.saveRemoteSettings == null) return;
    final urlController = TextEditingController(text: _remoteSettings.relayUrl);
    final tokenController = TextEditingController(
      text: _remoteSettings.accessToken.trim(),
    );
    final secretController = TextEditingController(
      text: _remoteSettings.familySecret.trim(),
    );
    var enabled = _remoteSettings.enabled;
    var showAccessToken = false;
    var showFamilySecret = false;
    RemoteAccessSettings? result;
    try {
      result = await showDialog<RemoteAccessSettings>(
        context: context,
        builder: (context) => StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
            title: const Text('配置公网远程传输'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('启用 VPS 远程连接'),
                    subtitle: const Text('启用后设备列表会明确标记“公网 VPS 中转”'),
                    value: enabled,
                    onChanged: (value) => setDialogState(() => enabled = value),
                  ),
                  TextField(
                    controller: urlController,
                    enabled: enabled,
                    keyboardType: TextInputType.url,
                    decoration: const InputDecoration(
                      labelText: '中转地址',
                      hintText: 'wss://你的域名/v1/relay',
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    key: const Key('remote_access_token_field'),
                    controller: tokenController,
                    enabled: enabled,
                    obscureText: !showAccessToken,
                    decoration: InputDecoration(
                      labelText: 'VPS 访问令牌（至少 24 位）',
                      helperText: '用于连接 VPS；已显示远程设备说明此项有效',
                      suffixIcon: IconButton(
                        key: const Key('remote_access_token_visibility'),
                        tooltip: showAccessToken ? '隐藏访问令牌' : '显示访问令牌',
                        onPressed: enabled
                            ? () => setDialogState(
                                () => showAccessToken = !showAccessToken,
                              )
                            : null,
                        icon: Icon(
                          showAccessToken
                              ? Icons.visibility_off_outlined
                              : Icons.visibility_outlined,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    key: const Key('remote_family_secret_field'),
                    controller: secretController,
                    enabled: enabled,
                    obscureText: !showFamilySecret,
                    onChanged: (_) => setDialogState(() {}),
                    decoration: InputDecoration(
                      labelText: '家庭加密口令（12-256 位）',
                      helperText: '三端必须完全相同；首尾空格会自动去除',
                      suffixIcon: IconButton(
                        key: const Key('remote_family_secret_visibility'),
                        tooltip: showFamilySecret ? '隐藏家庭加密口令' : '显示家庭加密口令',
                        onPressed: enabled
                            ? () => setDialogState(
                                () => showFamilySecret = !showFamilySecret,
                              )
                            : null,
                        icon: Icon(
                          showFamilySecret
                              ? Icons.visibility_off_outlined
                              : Icons.visibility_outlined,
                        ),
                      ),
                    ),
                  ),
                  if (enabled && secretController.text.trim().isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        '家庭口令校验码：'
                        '${familySecretCheckCode(secretController.text)}\n'
                        '仅在本机计算，不会发送；三台设备必须显示相同校验码。',
                        key: const Key('remote_family_secret_check_code'),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  const Text(
                    '公网中转支持在线文字、链接，以及单个不超过 200 MiB 的图片、'
                    '视频、APK、压缩包和其他文件。请注意移动数据与 VPS 流量。',
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () {
                  final settings = RemoteAccessSettings(
                    enabled: enabled,
                    relayUrl: urlController.text.trim(),
                    accessToken: tokenController.text.trim(),
                    familySecret: secretController.text.trim(),
                  );
                  try {
                    settings.validate();
                    Navigator.pop(context, settings);
                  } on FormatException catch (error) {
                    ScaffoldMessenger.of(context)
                        .showSnackBar(SnackBar(content: Text(error.message)));
                  }
                },
                child: const Text('保存'),
              ),
            ],
          ),
        ),
      );
    } finally {
      urlController.dispose();
      tokenController.dispose();
      secretController.dispose();
    }
    if (result == null) return;
    setState(() => _working = true);
    try {
      await widget.saveRemoteSettings!(result);
      if (mounted) setState(() => _remoteSettings = result!);
    } catch (error) {
      _showError('保存远程传输设置失败：$error');
    } finally {
      if (mounted) setState(() => _working = false);
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
          Text('公网远程传输', style: Theme.of(context).textTheme.titleMedium),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              _remoteSettings.enabled
                  ? Icons.cloud_done_outlined
                  : Icons.cloud_off_outlined,
            ),
            title: Text(_remoteSettings.enabled ? '已启用 VPS 中转' : '未启用 VPS 中转'),
            subtitle: Text(
              _remoteSettings.enabled
                  ? '${_remoteSettings.relayUrl}\n密钥保存在系统安全存储中'
                  : '默认只使用局域网；配置 VPS 后可远程发送文字、链接和 200 MiB 内文件',
            ),
            isThreeLine: _remoteSettings.enabled,
            trailing: const Icon(Icons.chevron_right),
            onTap: _working ? null : _configureRemoteAccess,
          ),
          const Card(
            margin: EdgeInsets.zero,
            child: ListTile(
              leading: Icon(Icons.route_outlined),
              title: Text('传输时始终显示实际网络路线'),
              subtitle: Text(
                '局域网会显示“局域网直连”或“二维码本地连接”；跨地区时显示“公网 VPS 中转”。'
                '公网文件发送可随时点击停止，接收端会清理未完成文件。',
              ),
            ),
          ),
          const Divider(height: 32),
          Text('连接与高速传输', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          const Card(
            margin: EdgeInsets.zero,
            child: Column(
              children: [
                ListTile(
                  leading: Icon(Icons.wifi_tethering),
                  title: Text('手机热点互传'),
                  subtitle: Text(
                    '一台手机打开热点，另一台连接后，双方会自动出现在设备列表；未出现时使用二维码或手动 IP 连接。',
                  ),
                ),
                Divider(height: 1),
                ListTile(
                  leading: Icon(Icons.speed_outlined),
                  title: Text('大文件请使用 5 GHz 热点'),
                  subtitle: Text(
                    '2.4 GHz 热点常见速度约 8 MiB/s；切换 5 GHz、关闭兼容模式并让设备靠近，可显著提速，实际速度取决于手机。',
                  ),
                ),
                Divider(height: 1),
                ListTile(
                  leading: Icon(Icons.hub_outlined),
                  title: Text('连接注意事项'),
                  subtitle: Text(
                    '参与传输的设备应使用相同协议版本。Windows 首次使用需放行 UDP 53317 和 TCP 53318；连接异常时请导出诊断日志。',
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.info_outline),
            title: const Text(appVersionLabel),
            subtitle: Text(
              _remoteSettings.enabled
                  ? '局域网优先；仅远程设备使用加密 VPS 中转'
                  : '默认纯局域网传输，不经过公网服务器',
            ),
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
