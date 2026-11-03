import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:launch_at_startup/launch_at_startup.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_version.dart';
import '../diagnostics/diagnostic_log_service.dart';
import '../pairing/pairing_endpoint.dart';
import '../remote/remote_access_settings.dart';
import '../storage/received_file_service.dart';
import '../update/app_update_service.dart';
import '../update/update_flow.dart';
import 'app_settings.dart';

typedef SaveAppSettings = Future<void> Function(AppSettings settings);

class SettingsPage extends StatefulWidget {
  const SettingsPage({
    required this.initialSettings,
    required this.saveSettings,
    this.initialRemoteSettings = const RemoteAccessSettings(),
    this.saveRemoteSettings,
    this.removedDevices = const [],
    this.restoreRemovedDevice,
    this.restoreAllRemovedDevices,
    super.key,
  });

  final AppSettings initialSettings;
  final SaveAppSettings saveSettings;
  final RemoteAccessSettings initialRemoteSettings;
  final Future<void> Function(RemoteAccessSettings settings)?
  saveRemoteSettings;
  final List<RemovedDeviceEntry> removedDevices;
  final Future<void> Function(String deviceId)? restoreRemovedDevice;
  final Future<void> Function()? restoreAllRemovedDevices;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final ReceivedFileService _fileService = ReceivedFileService();
  final DiagnosticLogService _diagnostics = DiagnosticLogService.instance;
  late AppSettings _settings;
  late RemoteAccessSettings _remoteSettings;
  late List<RemovedDeviceEntry> _removedDevices;
  bool _working = false;
  DiagnosticLogInfo? _diagnosticInfo;
  bool _checkingUpdate = false;
  int _updateCacheBytes = 0;

  @override
  void initState() {
    super.initState();
    _settings = widget.initialSettings;
    _remoteSettings = widget.initialRemoteSettings;
    _removedDevices = List.of(widget.removedDevices);
    if (Platform.isAndroid || Platform.isWindows) _refreshDiagnosticInfo();
    if (AppUpdateService.isSupportedPlatform) _refreshUpdateCache();
  }

  Future<void> _refreshUpdateCache() async {
    try {
      final bytes = await AppUpdateService.instance.cacheSize();
      if (mounted) setState(() => _updateCacheBytes = bytes);
    } catch (_) {}
  }

  Future<void> _checkForUpdate() async {
    if (_checkingUpdate) return;
    setState(() => _checkingUpdate = true);
    try {
      final result = await AppUpdateService.instance.check();
      if (!mounted) return;
      switch (result) {
        case UpdateFound(:final update):
          await UpdateFlow.offer(context, update, automatic: false);
        case UpdateUpToDate():
          _showMessage('已是最新版本 v$appVersion');
        case UpdateWithoutInstaller(:final version, :final pageUrl):
          _showMessage('新版本 v$version 暂时没有本平台的安装包，请到发布页查看');
          await UpdateFlow.openReleasePage(pageUrl);
      }
    } on UpdateException catch (error) {
      _showError(error.message);
    } catch (error) {
      _showError('检查更新失败：$error');
    } finally {
      if (mounted) setState(() => _checkingUpdate = false);
      await _refreshUpdateCache();
    }
  }

  Future<void> _clearUpdateCache() async {
    try {
      final removed = await AppUpdateService.instance.clearCache();
      _showMessage('已清空更新缓存（${formatUpdateBytes(removed)}）');
    } on UpdateException catch (error) {
      _showError(error.message);
    } catch (error) {
      _showError('清空更新缓存失败：$error');
    } finally {
      await _refreshUpdateCache();
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
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

  Future<void> _restoreDevice(RemovedDeviceEntry entry) async {
    final restore = widget.restoreRemovedDevice;
    if (_working || restore == null) return;
    setState(() => _working = true);
    try {
      await restore(entry.deviceId);
      if (!mounted) return;
      setState(() {
        _removedDevices.removeWhere((item) => item.deviceId == entry.deviceId);
      });
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('已恢复：${entry.label}')));
    } catch (error) {
      _showError('恢复设备失败：$error');
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _restoreAllDevices() async {
    final restore = widget.restoreAllRemovedDevices;
    if (_working || restore == null || _removedDevices.isEmpty) return;
    setState(() => _working = true);
    try {
      final count = _removedDevices.length;
      await restore();
      if (!mounted) return;
      setState(() => _removedDevices.clear());
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('已恢复 $count 台设备')));
    } catch (error) {
      _showError('恢复设备失败：$error');
    } finally {
      if (mounted) setState(() => _working = false);
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

  void _showError(String message) => _showMessage(message);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final saveLocation = Platform.isAndroid
        ? _settings.androidSaveLabel
        : _settings.windowsSaveDirectory ?? 'Windows 下载/猛人快传';
    final usesCustomLocation = Platform.isAndroid
        ? _settings.usesCustomAndroidDirectory
        : _settings.windowsSaveDirectory != null;
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 28),
            children: [
              _SettingsSection(
                title: '外观',
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
                    child: Row(
                      children: [
                        Text('主题', style: theme.textTheme.bodyLarge),
                        const Spacer(),
                        SegmentedButton<AppThemeMode>(
                          showSelectedIcon: false,
                          segments: AppThemeMode.values
                              .map(
                                (mode) => ButtonSegment<AppThemeMode>(
                                  value: mode,
                                  label: Text(mode.label),
                                ),
                              )
                              .toList(),
                          selected: {_settings.themeMode},
                          onSelectionChanged: (selection) => _save(
                            _settings.copyWith(themeMode: selection.first),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 14),
                    child: Row(
                      children: [
                        Text('强调色', style: theme.textTheme.bodyLarge),
                        const Spacer(),
                        for (final color in AppThemeColor.values)
                          _ColorDot(
                            color: color,
                            selected: _settings.themeColor == color,
                            onTap: () =>
                                _save(_settings.copyWith(themeColor: color)),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
              _SettingsSection(
                title: '常规',
                children: [
                  if (Platform.isWindows)
                    _SettingsTile(
                      icon: Icons.power_settings_new_rounded,
                      title: '开机自启动',
                      subtitle: '登录 Windows 后自动在托盘运行',
                      trailing: Switch(
                        value: _settings.launchAtStartup,
                        onChanged: _working ? null : _toggleStartup,
                      ),
                    ),
                  _SettingsTile(
                    icon: Icons.folder_outlined,
                    title: '文件保存位置',
                    subtitle: saveLocation,
                    trailing: usesCustomLocation
                        ? TextButton(
                            onPressed: _working ? null : _useDefaultDirectory,
                            child: const Text('恢复默认'),
                          )
                        : const Icon(Icons.chevron_right),
                    onTap: _working ? null : _chooseDirectory,
                  ),
                ],
              ),
              if (AppUpdateService.isSupportedPlatform)
                _SettingsSection(
                  key: const Key('update_section'),
                  title: '软件更新',
                  children: [
                    _SettingsTile(
                      key: const Key('check_update'),
                      icon: Icons.system_update_alt_rounded,
                      title: '检查更新',
                      subtitle: '当前 v$appVersion，有新版本时可一键安装',
                      trailing: _checkingUpdate
                          ? const SizedBox.square(
                              dimension: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.chevron_right),
                      onTap: _checkingUpdate ? null : _checkForUpdate,
                    ),
                    _SettingsTile(
                      icon: Icons.update_rounded,
                      title: '自动检查更新',
                      subtitle: '每天最多一次，只向 GitHub 查询版本号',
                      trailing: Switch(
                        value: _settings.autoCheckUpdates,
                        onChanged: (enabled) => _save(
                          _settings.copyWith(autoCheckUpdates: enabled),
                        ),
                      ),
                    ),
                    _SettingsTile(
                      icon: Icons.cleaning_services_outlined,
                      title: '更新缓存',
                      subtitle:
                          '${formatUpdateBytes(_updateCacheBytes)} · 每次启动自动清理',
                      trailing: TextButton(
                        onPressed: _checkingUpdate || _updateCacheBytes == 0
                            ? null
                            : _clearUpdateCache,
                        child: const Text('清空'),
                      ),
                    ),
                  ],
                ),
              _SettingsSection(
                title: '公网远程传输',
                children: [
                  _SettingsTile(
                    icon: _remoteSettings.enabled
                        ? Icons.cloud_done_outlined
                        : Icons.cloud_off_outlined,
                    title: _remoteSettings.enabled
                        ? '已启用 VPS 中转'
                        : '未启用 VPS 中转',
                    subtitle: _remoteSettings.enabled
                        ? '${_remoteSettings.relayUrl}\n密钥保存在系统安全存储中'
                        : '默认只用局域网；配置方法见下方“使用帮助”',
                    trailing: const Icon(Icons.chevron_right),
                    onTap: _working ? null : _configureRemoteAccess,
                  ),
                ],
              ),
              _SettingsSection(
                title: '设备管理',
                children: [
                  _SettingsTile(
                    key: const Key('removed_devices_summary'),
                    icon: Icons.devices_other_outlined,
                    title: '已移除设备',
                    subtitle: _removedDevices.isEmpty
                        ? '没有已移除设备；移除后可在这里恢复'
                        : '共 ${_removedDevices.length} 台；恢复后会重新参与自动发现和连接',
                    trailing: _removedDevices.length > 1
                        ? TextButton(
                            key: const Key('restore_all_removed_devices'),
                            onPressed: _working ? null : _restoreAllDevices,
                            child: const Text('全部恢复'),
                          )
                        : null,
                  ),
                  for (final entry in _removedDevices)
                    _SettingsTile(
                      key: Key('removed_device_${entry.deviceId}'),
                      indent: true,
                      title: entry.label,
                      subtitle: '设备标识：${entry.shortId.toUpperCase()}',
                      trailing: TextButton(
                        onPressed: _working
                            ? null
                            : () => _restoreDevice(entry),
                        child: const Text('恢复'),
                      ),
                    ),
                ],
              ),
              if (Platform.isAndroid || Platform.isWindows)
                _SettingsSection(
                  key: const Key('diagnostics_section'),
                  title: '诊断',
                  children: [
                    _SettingsTile(
                      icon: Icons.bug_report_outlined,
                      title: '诊断日志',
                      subtitle:
                          '${_formatDiagnosticBytes(_diagnosticInfo?.bytes ?? 0)}'
                          ' · 最多保留 2 份，7 天自动清理',
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
                      child: Row(
                        children: [
                          Expanded(
                            child: FilledButton.tonalIcon(
                              onPressed: _working ? null : _exportDiagnostics,
                              icon: const Icon(Icons.download_outlined),
                              label: const Text('导出诊断日志'),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: _working ? null : _clearDiagnostics,
                              icon: const Icon(Icons.delete_sweep_outlined),
                              label: const Text('清除诊断日志'),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              _SettingsSection(
                title: '使用帮助',
                children: const [
                  _HelpTile(
                    key: Key('remote_setup_help'),
                    icon: Icons.cloud_outlined,
                    title: '公网远程传输怎么配置',
                    body:
                        '适合手机和电脑不在同一个网络时使用（例如人在外面、电脑在家），'
                        '需要你自己有一台 VPS 和一个域名。\n'
                        '1. 在 VPS 上部署猛人快传中转服务，生成一个至少 24 位的访问令牌，'
                        '并给域名配置 HTTPS（步骤见下方“完整部署指南”）。\n'
                        '2. 在每台设备的“设置 → 公网远程传输”里打开“启用 VPS 远程连接”，填写三项：'
                        '中转地址（wss://你的域名/v1/relay）、VPS 访问令牌、家庭加密口令'
                        '（12–256 位，自己设定）。\n'
                        '3. 所有设备的三项必须完全一样。填好后对比每台设备显示的“家庭口令校验码”，'
                        '校验码相同才说明口令一致。\n'
                        '4. 保存后，主界面本机卡片会显示“VPS 已连接”；不在同一网络的设备会出现在列表里，'
                        '并标注“公网 VPS 中转”。\n'
                        '说明：同一局域网内仍优先直连，不走公网；文件在设备之间端到端加密，'
                        '家庭加密口令只存在本机、不会发给 VPS；公网单个文件不超过 200 MiB，'
                        '注意手机流量和 VPS 流量。',
                    linkLabel: '查看完整部署指南',
                    linkUrl: _relayGuideUrl,
                  ),
                  _HelpTile(
                    icon: Icons.route_outlined,
                    title: '传输时始终显示实际网络路线',
                    body:
                        '局域网会显示“局域网直连”或“局域网安全连接”；后者可由已保存的连接自动重连，'
                        '并不表示本次扫描了二维码。跨地区时显示“公网 VPS 中转”。'
                        '公网文件发送可随时点击停止，接收端会清理未完成文件。',
                  ),
                  _HelpTile(
                    icon: Icons.wifi_tethering,
                    title: '手机热点互传',
                    body:
                        '一台手机打开热点，另一台连接后，双方会自动出现在设备列表；'
                        '未出现时使用二维码或手动 IP 连接。',
                  ),
                  _HelpTile(
                    icon: Icons.speed_outlined,
                    title: '大文件请使用 5 GHz 热点',
                    body:
                        '2.4 GHz 热点常见速度约 8 MiB/s；切换 5 GHz、关闭兼容模式并让设备靠近，'
                        '可显著提速，实际速度取决于手机。',
                  ),
                  _HelpTile(
                    icon: Icons.hub_outlined,
                    title: '连接注意事项',
                    body:
                        '参与传输的设备应使用相同协议版本。Windows 首次使用需放行 UDP 53317 和 '
                        'TCP 53318；连接异常时请导出诊断日志。',
                  ),
                ],
              ),
              const SizedBox(height: 22),
              Center(
                child: Column(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: Image.asset(
                        'assets/icon/mengren_icon_small.png',
                        width: 44,
                        height: 44,
                        cacheWidth: 144,
                        errorBuilder: (_, _, _) => const SizedBox.shrink(),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(appVersionLabel, style: theme.textTheme.bodyMedium),
                    const SizedBox(height: 2),
                    Text(
                      '作者 $appAuthor',
                      key: const Key('about_author'),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    TextButton.icon(
                      key: const Key('about_github'),
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                      ),
                      onPressed: () => unawaited(
                        launchUrl(
                          Uri.parse(_projectUrl),
                          mode: LaunchMode.externalApplication,
                        ),
                      ),
                      icon: const Icon(Icons.open_in_new, size: 16),
                      label: const Text(
                        'github.com/$officialUpdateRepository',
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A titled group of rows drawn as one rounded card.
class _SettingsSection extends StatelessWidget {
  const _SettingsSection({
    required this.title,
    required this.children,
    super.key,
  });

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rows = <Widget>[];
    for (var index = 0; index < children.length; index++) {
      if (index > 0) rows.add(const Divider(indent: 16, endIndent: 16));
      rows.add(children[index]);
    }
    return Padding(
      padding: const EdgeInsets.only(top: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 0, 6, 8),
            child: Text(
              title,
              style: theme.textTheme.labelLarge?.copyWith(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Card(child: Column(children: rows)),
        ],
      ),
    );
  }
}

class _SettingsTile extends StatelessWidget {
  const _SettingsTile({
    required this.title,
    this.icon,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.indent = false,
    super.key,
  });

  final IconData? icon;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool indent;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return ListTile(
      contentPadding: EdgeInsets.fromLTRB(indent ? 68 : 16, 2, 12, 2),
      leading: icon == null
          ? null
          : Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: colors.primaryContainer,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, size: 20, color: colors.onPrimaryContainer),
            ),
      title: Text(title),
      subtitle: subtitle == null ? null : Text(subtitle!),
      trailing: trailing,
      onTap: onTap,
    );
  }
}

const _projectUrl = 'https://github.com/$officialUpdateRepository';

/// The VPS relay setup steps in the public repository.
const _relayGuideUrl =
    'https://github.com/$officialUpdateRepository/blob/main/docs/'
    '%E8%87%AA%E5%BB%BAVPS%E4%B8%AD%E8%BD%AC%E6%8C%87%E5%8D%97-v1.7.2.md';

class _HelpTile extends StatelessWidget {
  const _HelpTile({
    required this.icon,
    required this.title,
    required this.body,
    this.linkLabel,
    this.linkUrl,
    super.key,
  });

  final IconData icon;
  final String title;
  final String body;
  final String? linkLabel;
  final String? linkUrl;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Theme(
      // ExpansionTile draws its own borders when open; the card already
      // separates rows.
      data: theme.copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        leading: Icon(icon, size: 22),
        title: Text(title, style: theme.listTileTheme.titleTextStyle),
        childrenPadding: const EdgeInsets.fromLTRB(56, 0, 20, 14),
        expandedAlignment: Alignment.centerLeft,
        children: [
          Text(
            body,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              height: 1.55,
            ),
          ),
          if (linkLabel != null && linkUrl != null) ...[
            const SizedBox(height: 6),
            TextButton.icon(
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                visualDensity: VisualDensity.compact,
              ),
              onPressed: () => unawaited(
                launchUrl(
                  Uri.parse(linkUrl!),
                  mode: LaunchMode.externalApplication,
                ),
              ),
              icon: const Icon(Icons.open_in_new, size: 16),
              label: Text(linkLabel!),
            ),
          ],
        ],
      ),
    );
  }
}

class _ColorDot extends StatelessWidget {
  const _ColorDot({
    required this.color,
    required this.selected,
    required this.onTap,
  });

  final AppThemeColor color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Tooltip(
      message: color.label,
      child: Padding(
        padding: const EdgeInsets.only(left: 6),
        child: InkResponse(
          onTap: onTap,
          radius: 20,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            width: 30,
            height: 30,
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: selected ? colors.onSurface : Colors.transparent,
                width: 2,
              ),
            ),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: color.seedColor,
                shape: BoxShape.circle,
              ),
              child: selected
                  ? const Icon(Icons.check, size: 14, color: Colors.white)
                  : null,
            ),
          ),
        ),
      ),
    );
  }
}

String _formatDiagnosticBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}
