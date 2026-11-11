import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_version.dart';
import '../background/background_receive.dart';
import '../chat/chat_thumbnail.dart';
import '../chat/clipboard_files.dart';
import '../desktop/startup_launch.dart';
import '../voice/speech_download_dialog.dart';
import '../voice/speech_service.dart';
import '../voice/voice_store.dart';
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
  int _outgoingCacheBytes = 0;
  int _voiceBytes = 0;
  int _speechModelBytes = 0;
  bool _speechModelReady = false;

  @override
  void initState() {
    super.initState();
    _settings = widget.initialSettings;
    _remoteSettings = widget.initialRemoteSettings;
    _removedDevices = List.of(widget.removedDevices);
    if (Platform.isAndroid || Platform.isWindows) _refreshDiagnosticInfo();
    if (AppUpdateService.isSupportedPlatform) _refreshUpdateCache();
    if (Platform.isAndroid || Platform.isWindows) {
      _refreshOutgoingCache();
      _refreshVoice();
    }
  }

  Future<void> _refreshVoice() async {
    try {
      final voice = await VoiceStore.instance.size();
      final model = await SpeechModel.instance.size();
      final ready = await SpeechModel.instance.isInstalled();
      if (!mounted) return;
      setState(() {
        _voiceBytes = voice;
        _speechModelBytes = model;
        _speechModelReady = ready;
      });
    } catch (_) {}
  }

  Future<void> _clearVoice() async {
    final confirmed = await _confirm(
      '清空语音消息？',
      '会删除本机保存的全部语音消息录音，聊天记录里的语音会显示“已过期”，已转出的文字保留。',
      '清空',
    );
    if (confirmed != true) return;
    try {
      final removed = await VoiceStore.instance.clear();
      _showMessage('已清空语音消息（${formatUpdateBytes(removed)}）');
    } catch (error) {
      _showError('清空语音消息失败：$error');
    } finally {
      await _refreshVoice();
    }
  }

  Future<void> _manageSpeechModel() async {
    if (_speechModelReady) {
      final confirmed = await _confirm(
        '删除语音识别模型？',
        '删除后“转文字”和语音输入需要重新下载模型（约 '
            '${formatUpdateBytes(SpeechModel.totalBytes)}）。语音消息本身不受影响。',
        '删除',
      );
      if (confirmed != true) return;
      try {
        await SpeechModel.instance.delete();
        _showMessage('已删除语音识别模型');
      } catch (error) {
        _showError('删除失败：$error');
      }
    } else {
      await ensureSpeechModel(context, const PlatformSpeechEngine());
    }
    await _refreshVoice();
  }

  Future<bool?> _confirm(String title, String body, String action) =>
      showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(body),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(action),
            ),
          ],
        ),
      );

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
      final succeeded = await applyLaunchAtStartup(
        enabled: enabled,
        silent: _settings.silentStartup,
      );
      if (!succeeded) throw Exception('Windows 没有接受自启动设置');
      await _save(_settings.copyWith(launchAtStartup: enabled));
    } catch (error) {
      _showError('设置开机自启动失败：$error');
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _toggleSilentStartup(bool silent) async {
    if (!Platform.isWindows || _working) return;
    setState(() => _working = true);
    try {
      if (_settings.launchAtStartup) {
        final succeeded = await applyLaunchAtStartup(
          enabled: true,
          silent: silent,
        );
        if (!succeeded) throw Exception('Windows 没有接受自启动设置');
      }
      await _save(_settings.copyWith(silentStartup: silent));
    } catch (error) {
      _showError('设置静默启动失败：$error');
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _refreshOutgoingCache() async {
    try {
      final bytes = await OutgoingCache.instance.size();
      if (mounted) setState(() => _outgoingCacheBytes = bytes);
    } catch (_) {}
  }

  Future<void> _clearOutgoingCache() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清空发送缓存？'),
        content: const Text(
          '会删除粘贴后发送的截图、手机转发时临时复制的文件。'
          '聊天记录保留，但这些图片不再显示缩略图；还在排队等待对方上线的这类文件会发送失败。'
          '你自己电脑或手机里原来的文件不受影响。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      final removed = await OutgoingCache.instance.clear();
      ContentUriThumbnails.instance.clear();
      _showMessage('已清空发送缓存（${formatUpdateBytes(removed)}）');
    } catch (error) {
      _showError('清空发送缓存失败：$error');
    } finally {
      await _refreshOutgoingCache();
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

  Future<void> _chooseAutoAcceptMode() async {
    final selected = await showDialog<AutoAcceptMode>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('自动接收文件'),
        children: [
          RadioGroup<AutoAcceptMode>(
            groupValue: _settings.autoAcceptMode,
            onChanged: (value) => Navigator.pop(context, value),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final mode in AutoAcceptMode.values)
                  RadioListTile<AutoAcceptMode>(
                    key: Key('auto_accept_${mode.name}'),
                    value: mode,
                    title: Text(mode.label),
                    subtitle: Text(mode.description),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 4),
            child: Text(
              '只影响局域网收文件；文字消息一直直接接收。公网 VPS 中转收到的文件也一直直接接收'
              '（单个不超过 200 MiB）。在咖啡店等公共 Wi-Fi 上，建议选“每次都询问”。',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
    if (selected == null || selected == _settings.autoAcceptMode) return;
    await _save(_settings.copyWith(autoAcceptMode: selected));
  }

  Future<void> _toggleBackgroundReceive(bool enabled) async {
    await _save(_settings.copyWith(androidBackgroundReceive: enabled));
    if (!enabled || !mounted) return;
    // Without this exemption Doze cuts the network a while after the screen
    // goes off, even with the foreground service running.
    if (await BackgroundReceive.isIgnoringBatteryOptimizations()) return;
    if (!mounted) return;
    final allow = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('允许猛人快传后台运行？'),
        content: const Text(
          '手机熄屏一段时间后，系统会为了省电断开后台应用的网络。'
          '点“去允许”，在弹出的窗口里选择允许，熄屏后也能继续接收。\n\n'
          '魅族、小米等手机可能还需要在系统的“应用管理 → 猛人快传 → 耗电/后台”里设为“允许后台运行”。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('以后再说'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('去允许'),
          ),
        ],
      ),
    );
    if (allow == true) {
      await BackgroundReceive.requestIgnoreBatteryOptimizations();
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
              // Version, author and project page first (user request).
              Center(
                key: const Key('about_header'),
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
                      label: const Text('github.com/$officialUpdateRepository'),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
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
                  if (Platform.isWindows && _settings.launchAtStartup)
                    _SettingsTile(
                      key: const Key('silent_startup'),
                      icon: Icons.visibility_off_outlined,
                      title: '静默启动',
                      subtitle: '开机时只在任务栏右下角的托盘里运行，不打开主窗口；点托盘图标即可打开',
                      trailing: Switch(
                        value: _settings.silentStartup,
                        onChanged: _working ? null : _toggleSilentStartup,
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
                  if (Platform.isAndroid || Platform.isWindows)
                    _SettingsTile(
                      key: const Key('outgoing_cache'),
                      icon: Icons.cleaning_services_outlined,
                      title: '发送缓存',
                      subtitle:
                          '${formatUpdateBytes(_outgoingCacheBytes)} · 粘贴发送的截图、转发时复制的文件；'
                          '超过 30 天或总量超过 1 GB 的启动时自动清理',
                      trailing: TextButton(
                        onPressed: _outgoingCacheBytes == 0
                            ? null
                            : _clearOutgoingCache,
                        child: const Text('清空'),
                      ),
                    ),
                  if (Platform.isAndroid || Platform.isWindows)
                    _SettingsTile(
                      key: const Key('voice_messages'),
                      icon: Icons.keyboard_voice_outlined,
                      title: '语音消息',
                      subtitle:
                          '${formatUpdateBytes(_voiceBytes)} · 按住输入框旁的麦克风录音；'
                          '超过 30 天或总量超过 500 MB 的启动时自动清理',
                      trailing: TextButton(
                        onPressed: _voiceBytes == 0 ? null : _clearVoice,
                        child: const Text('清空'),
                      ),
                    ),
                  if (Platform.isAndroid || Platform.isWindows)
                    _SettingsTile(
                      key: const Key('speech_model'),
                      icon: Icons.record_voice_over_outlined,
                      title: '语音识别模型',
                      subtitle: _speechModelReady
                          ? '已下载 ${formatUpdateBytes(_speechModelBytes)} · 转文字和语音输入在本机离线完成'
                          : '未下载 · 第一次转文字时下载（约 '
                                '${formatUpdateBytes(SpeechModel.totalBytes)}）'
                                '${_speechModelBytes > 0 ? '，已下载一部分 ${formatUpdateBytes(_speechModelBytes)}' : ''}',
                      trailing: TextButton(
                        onPressed: _manageSpeechModel,
                        child: Text(_speechModelReady ? '删除' : '下载'),
                      ),
                    ),
                ],
              ),
              _SettingsSection(
                key: const Key('receive_section'),
                title: '接收',
                children: [
                  _SettingsTile(
                    key: const Key('auto_accept_mode'),
                    icon: Icons.move_to_inbox_outlined,
                    title: '自动接收文件',
                    subtitle: _settings.autoAcceptMode.label,
                    trailing: const Icon(Icons.chevron_right),
                    onTap: _chooseAutoAcceptMode,
                  ),
                  if (Platform.isAndroid)
                    _SettingsTile(
                      key: const Key('background_receive'),
                      icon: Icons.notifications_active_outlined,
                      title: '后台持续接收',
                      subtitle: '切到后台、熄屏也能收文件和消息；通知栏常驻一条提示，耗电稍多',
                      trailing: Switch(
                        value: _settings.androidBackgroundReceive,
                        onChanged: _toggleBackgroundReceive,
                      ),
                    ),
                  if (Platform.isAndroid && _settings.androidBackgroundReceive)
                    _SettingsTile(
                      key: const Key('vendor_background_settings'),
                      icon: Icons.verified_user_outlined,
                      title: '系统后台设置',
                      subtitle:
                          '华为、荣耀等手机要在这里允许猛人快传自启动和后台活动，'
                          '否则切到后台会被系统冻结',
                      trailing: const Icon(Icons.open_in_new),
                      onTap: () => unawaited(
                        BackgroundReceive.openVendorBackgroundSettings(),
                      ),
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
                    icon: Icons.move_to_inbox_outlined,
                    title: '自动接收和后台接收',
                    body:
                        '自动接收：默认“只限连接过的设备”——你给它发过东西、和它配对过、或手动接收过它文件的设备，'
                        '发来的文件直接保存；陌生设备第一次发文件仍会询问。设备标识在局域网里是公开广播的，'
                        '在咖啡店等公共 Wi-Fi 上建议改成“每次都询问”。\n'
                        '后台持续接收（手机）：打开后切到后台、熄屏也能收，收到时会弹通知；按返回键不会退出，'
                        '只是回到后台。从最近任务里划掉或手机重启后，需要重新打开猛人快传。'
                        '华为、荣耀手机：点“系统后台设置”（或手机设置 → 应用 → 应用启动管理），把猛人快传改成“手动管理”，'
                        '打开允许自启动、允许关联启动、允许后台活动；再在最近任务里把猛人快传的卡片下拉锁定，'
                        '一键清理时就不会被关掉。小米、OPPO、vivo、魅族在同一个入口里允许自启动/后台运行即可。'
                        '电脑端隐藏到托盘时本来就一直在接收。\n'
                        '对方不在线时发的文字和文件会先排队，显示“等待对方上线”，对方打开猛人快传后自动发出；'
                        '排队最多 100 条，7 天没发出去会标记为未发送。',
                  ),
                  _HelpTile(
                    icon: Icons.touch_app_outlined,
                    title: '长按消息、粘贴图片和静默启动',
                    body:
                        '长按消息（电脑上右键）：复制、转发、引用、删除。转发可以发给附近任意一台设备，'
                        '对方不在线时会排队；转发文件会切换到对方的对话里显示进度。'
                        '删除只删本机的聊天记录，已保存的文件不受影响。'
                        '引用回复在旧版本猛人快传上显示为“「名字：原文」”加一条分隔线的普通文字。\n'
                        '粘贴图片和文件：手机长按输入框，剪贴板里有图片或文件时会出现“粘贴图片/粘贴文件”；'
                        '电脑上按 Ctrl+V 或右键输入框即可，确认后发送。粘贴的截图会存在“发送缓存”里，'
                        '30 天后自动清理。\n'
                        '静默启动（电脑）：打开“开机自启动”后，默认开机只在任务栏右下角托盘里运行，'
                        '不弹出窗口，照常接收；点托盘图标打开。',
                  ),
                  _HelpTile(
                    icon: Icons.keyboard_voice_outlined,
                    title: '语音消息和语音转文字',
                    body:
                        '按住输入框旁的麦克风说话，松开发送；手指上滑可以取消，最长 60 秒。'
                        '点一下麦克风是语音输入：说完再点一次，说的话会变成文字填进输入框，可以修改后再发。\n'
                        '长按语音消息选“转文字”，文字显示在语音下方。识别在本机离线完成，录音不会上传；'
                        '第一次使用需要下载约 229 MB 的识别模型（从 GitHub 下载，国内网络可能需要代理），'
                        '可在“设置 → 常规 → 语音识别模型”删除。旧版本猛人快传收到的语音是一个可播放的音频文件。',
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
                        'TCP 53318；连接异常时请导出诊断日志。\n'
                        '发送时提示“连接被中途断开”：多半是 AdGuard、杀毒软件或防火墙接管了猛人快传的网络连接。'
                        '以 AdGuard 为例：设置 → 网络 → 应用程序管理，找到猛人快传，关闭“通过 AdGuard 路由流量”。'
                        '提示“文件已全部发出”时，对方多半已经收到，请先在对方那边确认再决定是否重发。',
                  ),
                ],
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
