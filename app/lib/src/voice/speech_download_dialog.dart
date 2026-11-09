import 'package:flutter/material.dart';

import 'speech_service.dart';

String _mib(int bytes) => '${(bytes / 1024 / 1024).toStringAsFixed(0)} MB';

/// Asks before the first download, then downloads with a progress dialog.
/// Returns true once the model is ready.
Future<bool> ensureSpeechModel(BuildContext context, SpeechEngine engine) async {
  if (await engine.isModelInstalled()) return true;
  if (!context.mounted) return false;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('下载语音识别模型'),
      content: Text(
        '语音转文字完全在本机离线完成，录音不会上传。'
        '第一次使用需要下载识别模型（约 ${_mib(SpeechModel.totalBytes)}，只需下载一次，'
        '可在设置里删除）。\n\n'
        '模型从猛人快传的 GitHub 发布页下载，国内网络可能需要先打开代理；'
        '中途取消后再次下载会从断点继续。',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('下载'),
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return false;
  return downloadSpeechModel(context, engine);
}

/// Shows download progress; returns true when the model is installed.
Future<bool> downloadSpeechModel(
  BuildContext context,
  SpeechEngine engine,
) async {
  final result = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _SpeechDownloadDialog(engine: engine),
  );
  return result == true;
}

class _SpeechDownloadDialog extends StatefulWidget {
  const _SpeechDownloadDialog({required this.engine});

  final SpeechEngine engine;

  @override
  State<_SpeechDownloadDialog> createState() => _SpeechDownloadDialogState();
}

class _SpeechDownloadDialogState extends State<_SpeechDownloadDialog> {
  SpeechDownloadToken _token = SpeechDownloadToken();
  int _received = 0;
  int _total = SpeechModel.totalBytes;
  String? _error;
  DateTime? _startedAt;
  int _startedFrom = 0;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    setState(() {
      _error = null;
      _token = SpeechDownloadToken();
      _startedAt = null;
    });
    try {
      await widget.engine.downloadModel(
        token: _token,
        onProgress: (received, total) {
          if (!mounted) return;
          setState(() {
            if (_startedAt == null) {
              _startedAt = DateTime.now();
              _startedFrom = received;
            }
            _received = received;
            _total = total;
          });
        },
      );
      if (mounted) Navigator.pop(context, true);
    } on SpeechDownloadCancelled {
      if (mounted) Navigator.pop(context, false);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
  }

  String get _speed {
    final startedAt = _startedAt;
    if (startedAt == null) return '正在连接…';
    final seconds = DateTime.now().difference(startedAt).inMilliseconds / 1000;
    if (seconds < 0.5) return '正在连接…';
    final perSecond = (_received - _startedFrom) / seconds;
    return '${(perSecond / 1024 / 1024).toStringAsFixed(1)} MB/s';
  }

  @override
  Widget build(BuildContext context) {
    final progress = _total <= 0 ? 0.0 : (_received / _total).clamp(0.0, 1.0);
    final error = _error;
    return AlertDialog(
      title: Text(error == null ? '正在下载语音识别模型' : '下载没有完成'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LinearProgressIndicator(value: progress),
          const SizedBox(height: 8),
          Text(
            '${_mib(_received)} / ${_mib(_total)}'
            '${error == null ? '  ·  $_speed' : ''}',
            key: const Key('speech_download_progress'),
          ),
          if (error != null) ...[
            const SizedBox(height: 10),
            Text(
              error,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
        ],
      ),
      actions: error == null
          ? [
              TextButton(
                onPressed: _token.cancel,
                child: const Text('取消下载'),
              ),
            ]
          : [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('关闭'),
              ),
              FilledButton(onPressed: _start, child: const Text('重试')),
            ],
    );
  }
}
