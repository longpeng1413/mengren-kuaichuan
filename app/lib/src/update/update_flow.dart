import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_version.dart';
import '../desktop/desktop_tray_service.dart';
import 'app_update_service.dart';

enum UpdatePromptChoice { update, later, skip }

/// Shared by the startup auto-check and the settings page button.
class UpdateFlow {
  UpdateFlow._();

  static bool _dialogOpen = false;

  static Future<void> offer(
    BuildContext context,
    AvailableUpdate update, {
    required bool automatic,
    AppUpdateService? service,
  }) async {
    if (_dialogOpen) return;
    final updater = service ?? AppUpdateService.instance;
    _dialogOpen = true;
    try {
      final choice = await showDialog<UpdatePromptChoice>(
        context: context,
        builder: (_) =>
            UpdateAvailableDialog(update: update, allowSkip: automatic),
      );
      if (!context.mounted) return;
      switch (choice) {
        case UpdatePromptChoice.update:
          await showDialog<void>(
            context: context,
            barrierDismissible: false,
            builder: (_) =>
                UpdateProgressDialog(update: update, service: updater),
          );
        case UpdatePromptChoice.skip:
          await updater.skipVersion(update.version);
        case UpdatePromptChoice.later:
        case null:
          break;
      }
    } finally {
      _dialogOpen = false;
    }
  }

  static Future<void> openReleasePage(Uri? pageUrl) async {
    final target =
        pageUrl ??
        Uri.parse('https://github.com/$officialUpdateRepository/releases');
    await launchUrl(target, mode: LaunchMode.externalApplication);
  }
}

class UpdateAvailableDialog extends StatelessWidget {
  const UpdateAvailableDialog({
    required this.update,
    required this.allowSkip,
    super.key,
  });

  final AvailableUpdate update;
  final bool allowSkip;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text('发现新版本 v${update.version}'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '当前 v$appVersion · 安装包 ${formatUpdateBytes(update.asset.size)}',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            if (update.notes.isNotEmpty)
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 280),
                child: SingleChildScrollView(
                  child: SelectableText(update.notes),
                ),
              ),
            const SizedBox(height: 12),
            Text(
              Platform.isWindows
                  ? '更新时猛人快传会自动关闭，几秒后自动重新打开；正在进行的传输会中断。'
                      '设置、聊天记录和已配对设备都会保留。'
                  : '下载并校验后，系统会弹出安装确认；设置、聊天记录和已配对设备都会保留。',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
      actions: [
        if (allowSkip)
          TextButton(
            onPressed: () =>
                Navigator.of(context).pop(UpdatePromptChoice.skip),
            child: const Text('跳过此版本'),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(UpdatePromptChoice.later),
          child: const Text('以后再说'),
        ),
        FilledButton(
          onPressed: () =>
              Navigator.of(context).pop(UpdatePromptChoice.update),
          child: const Text('立即更新'),
        ),
      ],
    );
  }
}

enum _Stage { downloading, preparing, needsPermission, installing, restarting, failed }

class UpdateProgressDialog extends StatefulWidget {
  const UpdateProgressDialog({
    required this.update,
    required this.service,
    super.key,
  });

  final AvailableUpdate update;
  final AppUpdateService service;

  @override
  State<UpdateProgressDialog> createState() => _UpdateProgressDialogState();
}

class _UpdateProgressDialogState extends State<UpdateProgressDialog>
    with WidgetsBindingObserver {
  final UpdateCancelToken _cancelToken = UpdateCancelToken();
  StreamSubscription<AndroidInstallStatus>? _installSubscription;
  _Stage _stage = _Stage.downloading;
  int _received = 0;
  int _total = 0;
  String? _message;
  File? _downloaded;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (Platform.isAndroid) {
      _installSubscription = widget.service.androidInstallStatus.listen(
        _onInstallStatus,
      );
    }
    unawaited(_run());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _cancelToken.cancel();
    unawaited(_installSubscription?.cancel());
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Returning from the "install unknown apps" settings page continues
    // automatically once the permission has been granted.
    if (state == AppLifecycleState.resumed &&
        _stage == _Stage.needsPermission) {
      unawaited(_installAndroid());
    }
  }

  Future<void> _run() async {
    try {
      final file = await widget.service.download(
        widget.update,
        cancelToken: _cancelToken,
        onProgress: (received, total) {
          if (!mounted) return;
          setState(() {
            _received = received;
            _total = total;
          });
        },
      );
      _downloaded = file;
      if (!mounted) return;
      if (Platform.isAndroid) {
        await _installAndroid();
      } else {
        await _applyWindows(file);
      }
    } on UpdateCancelledException {
      if (mounted) Navigator.of(context).pop();
    } on UpdateException catch (error) {
      _fail(error.message);
    } catch (error) {
      _fail('更新失败：$error');
    }
  }

  Future<void> _installAndroid() async {
    final apk = _downloaded;
    if (apk == null) return;
    try {
      if (!await widget.service.canInstallPackages()) {
        if (mounted) setState(() => _stage = _Stage.needsPermission);
        return;
      }
      if (mounted) {
        setState(() {
          _stage = _Stage.installing;
          _message = '正在交给系统安装…';
        });
      }
      await widget.service.installAndroidApk(apk, widget.update.asset.name);
    } on UpdateException catch (error) {
      _fail(error.message);
    } catch (error) {
      _fail('无法启动安装：$error');
    }
  }

  void _onInstallStatus(AndroidInstallStatus status) {
    if (!mounted) return;
    switch (status.kind) {
      case AndroidInstallStatusKind.pendingUserAction:
        setState(() {
          _stage = _Stage.installing;
          _message = '请在系统窗口里点“更新/安装”。装好后猛人快传会重新打开或回到桌面。';
        });
      case AndroidInstallStatusKind.success:
        setState(() => _message = '安装完成');
      case AndroidInstallStatusKind.cancelled:
        Navigator.of(context).pop();
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(content: Text(status.description)),
        );
      case AndroidInstallStatusKind.failure:
        _fail(status.description);
    }
  }

  Future<void> _applyWindows(File zip) async {
    setState(() => _stage = _Stage.preparing);
    final plan = await widget.service.prepareWindowsUpdate(zip, widget.update);
    if (!mounted) return;
    setState(() => _stage = _Stage.restarting);
    await widget.service.launchWindowsApply(plan);
    // Give the dialog a moment to show the restart notice, then exit so the
    // script can replace the files. exit() is a fallback if the window does
    // not close on its own.
    await Future<void>.delayed(const Duration(milliseconds: 800));
    unawaited(
      Future<void>.delayed(const Duration(seconds: 5), () => exit(0)),
    );
    await DesktopTrayService.instance.exitApplication();
  }

  void _fail(String message) {
    if (!mounted) return;
    setState(() {
      _stage = _Stage.failed;
      _message = message;
    });
  }

  @override
  Widget build(BuildContext context) {
    final progress = _total > 0 ? (_received / _total).clamp(0.0, 1.0) : null;
    final content = switch (_stage) {
      _Stage.downloading => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LinearProgressIndicator(value: progress),
          const SizedBox(height: 10),
          Text(
            _total > 0
                ? '已下载 ${formatUpdateBytes(_received)} / ${formatUpdateBytes(_total)}'
                : '正在连接 GitHub 并核对校验信息…',
          ),
          const SizedBox(height: 6),
          Text(
            '下载完成后会先核对 SHA-256 校验值，不一致会自动删除，不会安装。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
      _Stage.preparing => const _Busy(text: '校验通过，正在解压新版本…'),
      _Stage.restarting => const _Busy(
        text: '即将关闭猛人快传并替换为新版本，几秒后会自动重新打开。',
      ),
      _Stage.needsPermission => const Text(
        '安卓系统要求先允许猛人快传“安装未知应用”。\n'
        '点“去允许”，打开开关后返回这里，会自动继续安装。',
      ),
      _Stage.installing => _Busy(text: _message ?? '正在安装…'),
      _Stage.failed => Text(_message ?? '更新失败'),
    };
    return PopScope(
      canPop: false,
      child: AlertDialog(
        title: Text(
          _stage == _Stage.failed
              ? '更新没有完成'
              : '正在更新到 v${widget.update.version}',
        ),
        content: SizedBox(width: 420, child: content),
        actions: [
          if (_stage == _Stage.downloading)
            TextButton(
              onPressed: _cancelToken.cancel,
              child: const Text('取消下载'),
            ),
          if (_stage == _Stage.needsPermission) ...[
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('以后再说'),
            ),
            FilledButton(
              onPressed: () =>
                  unawaited(widget.service.openInstallPermissionSettings()),
              child: const Text('去允许'),
            ),
          ],
          if (_stage == _Stage.installing)
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('关闭'),
            ),
          if (_stage == _Stage.failed) ...[
            TextButton(
              onPressed: () =>
                  unawaited(UpdateFlow.openReleasePage(widget.update.pageUrl)),
              child: const Text('去网页手动下载'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('关闭'),
            ),
          ],
        ],
      ),
    );
  }
}

class _Busy extends StatelessWidget {
  const _Busy({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(strokeWidth: 2.5),
        ),
        const SizedBox(width: 14),
        Expanded(child: Text(text)),
      ],
    );
  }
}

String formatUpdateBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}
