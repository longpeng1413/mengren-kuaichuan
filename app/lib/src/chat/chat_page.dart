import 'dart:async';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;
import 'package:url_launcher/url_launcher.dart';

import '../discovery/discovered_device.dart';
import '../storage/received_file_service.dart';
import '../transfer/transfer_models.dart';
import 'chat_message.dart';

typedef SendChatText = Future<void> Function(String text);
typedef ClearConversation = Future<void> Function(bool deleteCache);
typedef RemoveDevice = Future<void> Function();
typedef PickAndSendFiles = Future<void> Function(
  Iterable<String>? filePaths,
  void Function(String fileName, int sentBytes, int totalBytes) onProgress,
  TransferCancellationToken cancellation,
);

class ChatPage extends StatefulWidget {
  const ChatPage({
    required this.device,
    required this.messages,
    required this.incomingProgress,
    required this.onSendText,
    required this.onSendFiles,
    required this.onClearConversation,
    required this.onRemoveDevice,
    this.initialFilePaths = const [],
    super.key,
  });

  final DiscoveredDevice device;
  final ValueListenable<List<ChatMessage>> messages;
  final ValueListenable<TransferProgressUpdate?> incomingProgress;
  final SendChatText onSendText;
  final PickAndSendFiles onSendFiles;
  final ClearConversation onClearConversation;
  final RemoveDevice onRemoveDevice;
  final List<String> initialFilePaths;

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final TextEditingController _textController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  bool _busy = false;
  String? _sendingFileName;
  int _sentBytes = 0;
  int _totalBytes = 0;
  DateTime? _outgoingStartedAt;
  double _outgoingBytesPerSecond = 0;
  String? _incomingTransferId;
  DateTime? _incomingStartedAt;
  double _incomingBytesPerSecond = 0;
  bool _dragging = false;
  TransferCancellationToken? _activeCancellation;
  bool _cancelling = false;

  @override
  void initState() {
    super.initState();
    widget.messages.addListener(_messagesChanged);
    widget.incomingProgress.addListener(_incomingProgressChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
    if (widget.initialFilePaths.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(_sendFiles(widget.initialFilePaths));
      });
    }
  }

  @override
  void dispose() {
    widget.messages.removeListener(_messagesChanged);
    widget.incomingProgress.removeListener(_incomingProgressChanged);
    _textController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _messagesChanged() {
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
  }

  void _incomingProgressChanged() {
    final progress = widget.incomingProgress.value;
    if (progress == null) {
      _incomingTransferId = null;
      _incomingStartedAt = null;
      _incomingBytesPerSecond = 0;
    } else {
      final now = DateTime.now();
      if (_incomingTransferId != progress.transferId ||
          progress.transferredBytes == 0) {
        _incomingTransferId = progress.transferId;
        _incomingStartedAt = now;
        _incomingBytesPerSecond = 0;
      } else {
        final elapsed = now.difference(_incomingStartedAt!).inMilliseconds;
        if (elapsed > 0) {
          _incomingBytesPerSecond = progress.transferredBytes * 1000 / elapsed;
        }
      }
    }
    if (mounted) setState(() {});
  }

  void _scrollToBottom() {
    if (!_scrollController.hasClients) return;
    _scrollController.animateTo(
      _scrollController.position.maxScrollExtent,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
    );
  }

  Future<void> _sendText() async {
    final text = _textController.text.trim();
    if (_busy || text.isEmpty) return;
    setState(() => _busy = true);
    try {
      await widget.onSendText(text);
      _textController.clear();
    } catch (error) {
      _showError(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _sendFiles([Iterable<String>? filePaths]) async {
    if (_busy) return;
    final cancellation = TransferCancellationToken();
    setState(() {
      _busy = true;
      _activeCancellation = cancellation;
      _cancelling = false;
      _sendingFileName = null;
      _sentBytes = 0;
      _totalBytes = 0;
      _outgoingStartedAt = null;
      _outgoingBytesPerSecond = 0;
    });
    try {
      await widget.onSendFiles(filePaths, (fileName, sentBytes, totalBytes) {
        if (!mounted) return;
        final now = DateTime.now();
        setState(() {
          if (_sendingFileName != fileName || sentBytes == 0) {
            _outgoingStartedAt = now;
            _outgoingBytesPerSecond = 0;
          } else {
            final elapsed = now
                .difference(_outgoingStartedAt ?? now)
                .inMilliseconds;
            if (elapsed > 0) {
              _outgoingBytesPerSecond = sentBytes * 1000 / elapsed;
            }
          }
          _sendingFileName = fileName;
          _sentBytes = sentBytes;
          _totalBytes = totalBytes;
        });
      }, cancellation);
    } on TransferCancelledException {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('文件发送已取消')));
      }
    } catch (error) {
      _showError(error);
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _activeCancellation = null;
          _cancelling = false;
          _sendingFileName = null;
          _sentBytes = 0;
          _totalBytes = 0;
          _outgoingStartedAt = null;
          _outgoingBytesPerSecond = 0;
        });
      }
    }
  }

  void _cancelTransfer() {
    final cancellation = _activeCancellation;
    if (cancellation == null || cancellation.isCancelled) return;
    setState(() => _cancelling = true);
    cancellation.cancel();
  }

  Future<void> _sendDroppedFiles(DropDoneDetails details) async {
    final paths = <String>[];
    for (final item in details.files) {
      if (await File(item.path).exists()) paths.add(item.path);
    }
    if (mounted) setState(() => _dragging = false);
    if (paths.isEmpty) {
      _showError('请拖入一个或多个文件，暂不支持直接发送文件夹');
      return;
    }
    await _sendFiles(paths);
  }

  void _showError(Object error) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('发送失败：$error')));
  }

  Future<void> _openConversationMenu() async {
    final action = await showModalBottomSheet<_ConversationAction>(
      context: context,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 10),
                child: Text(
                  '会话设置',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              ListTile(
                leading: const Icon(Icons.delete_sweep_outlined),
                title: const Text('清空消息与缓存'),
                subtitle: const Text('删除本会话的聊天记录'),
                onTap: () => Navigator.pop(context, _ConversationAction.clear),
              ),
              ListTile(
                leading: Icon(
                  Icons.delete_forever_outlined,
                  color: Theme.of(context).colorScheme.error,
                ),
                title: const Text('移除设备'),
                subtitle: const Text('忘记此设备，需要重新发现或扫码配对'),
                onTap: () => Navigator.pop(context, _ConversationAction.remove),
              ),
            ],
          ),
        ),
      ),
    );
    if (!mounted || action == null) return;
    switch (action) {
      case _ConversationAction.clear:
        await _confirmClearConversation();
      case _ConversationAction.remove:
        await _confirmRemoveDevice();
    }
  }

  Future<void> _confirmClearConversation() async {
    var deleteCache = true;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('清空消息'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('将删除本会话的全部聊天记录。已保存到系统下载或自定义文件夹的文件不会删除。'),
              const SizedBox(height: 10),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: deleteCache,
                title: const Text('同时删除应用缓存文件'),
                onChanged: (value) =>
                    setDialogState(() => deleteCache = value ?? true),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('清空消息'),
            ),
          ],
        ),
      ),
    );
    if (confirmed == true) await widget.onClearConversation(deleteCache);
  }

  Future<void> _confirmRemoveDevice() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('移除设备？'),
        content: Text(
          '将移除“${widget.device.displayName}”并清空本会话。已保存的接收文件不会删除。以后可通过重新发现或扫码再次添加。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('移除设备'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await widget.onRemoveDevice();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final progress = _totalBytes <= 0
        ? 0.0
        : (_sentBytes / _totalBytes).clamp(0.0, 1.0);
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.device.displayName),
            Text(
              widget.device.isRemote
                  ? '公网 VPS 中转 · 图片可随时停止'
                  : widget.device.routeLabel,
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: '会话设置',
            onPressed: _busy ? null : _openConversationMenu,
            icon: const Icon(Icons.more_vert),
          ),
        ],
      ),
      body: DropTarget(
        onDragEntered: _busy ? null : (_) => setState(() => _dragging = true),
        onDragExited: (_) => setState(() => _dragging = false),
        onDragDone: _busy ? null : _sendDroppedFiles,
        child: Stack(
          children: [
            SafeArea(
              child: Column(
                children: [
                  if (_sendingFileName != null)
                    _TransferProgress(
                      direction: _TransferDirection.sending,
                      fileName: _sendingFileName!,
                      progress: progress,
                      transferredBytes: _sentBytes,
                      totalBytes: _totalBytes,
                      bytesPerSecond: _outgoingBytesPerSecond,
                      onCancel: _cancelTransfer,
                      isCancelling: _cancelling,
                    ),
                  ValueListenableBuilder<TransferProgressUpdate?>(
                    valueListenable: widget.incomingProgress,
                    builder: (context, incoming, _) {
                      if (incoming == null) return const SizedBox.shrink();
                      final incomingProgress = incoming.totalBytes <= 0
                          ? 0.0
                          : (incoming.transferredBytes / incoming.totalBytes)
                                .clamp(0.0, 1.0);
                      return _TransferProgress(
                        direction: _TransferDirection.receiving,
                        fileName: incoming.fileName,
                        progress: incomingProgress,
                        transferredBytes: incoming.transferredBytes,
                        totalBytes: incoming.totalBytes,
                        bytesPerSecond: _incomingBytesPerSecond,
                      );
                    },
                  ),
                  Expanded(
                    child: ValueListenableBuilder<List<ChatMessage>>(
                      valueListenable: widget.messages,
                      builder: (context, messages, _) {
                        if (messages.isEmpty) {
                          return const Center(
                            child: Text(
                              '还没有消息\n可以发送文字、链接、图片、视频或文件\nWindows 也可以把文件拖到这里',
                              textAlign: TextAlign.center,
                            ),
                          );
                        }
                        return ListView.builder(
                          controller: _scrollController,
                          padding: const EdgeInsets.fromLTRB(16, 16, 16, 10),
                          itemCount: messages.length,
                          itemBuilder: (context, index) =>
                              _MessageBubble(message: messages[index]),
                        );
                      },
                    ),
                  ),
                  const Divider(height: 1),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(8, 7, 8, 8),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        IconButton(
                          tooltip: '发送图片、视频或文件',
                          onPressed: _busy ? null : () => _sendFiles(),
                          icon: const Icon(Icons.attach_file),
                        ),
                        Expanded(
                          child: Shortcuts(
                            shortcuts: const {
                              SingleActivator(LogicalKeyboardKey.enter):
                                  _SendMessageIntent(),
                            },
                            child: Actions(
                              actions: {
                                _SendMessageIntent:
                                    CallbackAction<_SendMessageIntent>(
                                      onInvoke: (_) {
                                        unawaited(_sendText());
                                        return null;
                                      },
                                    ),
                              },
                              child: TextField(
                                controller: _textController,
                                enabled: !_busy,
                                minLines: 1,
                                maxLines: 5,
                                maxLength: 16000,
                                buildCounter: (
                                  _, {
                                  required currentLength,
                                  required isFocused,
                                  maxLength,
                                }) => null,
                                textInputAction: Platform.isAndroid
                                    ? TextInputAction.send
                                    : TextInputAction.newline,
                                onSubmitted: Platform.isAndroid
                                    ? (_) => _sendText()
                                    : null,
                                decoration: const InputDecoration(
                                  hintText:
                                      '输入文字或粘贴链接（Enter 发送，Shift+Enter 换行）',
                                  border: OutlineInputBorder(),
                                  isDense: true,
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        IconButton.filled(
                          tooltip: '发送',
                          onPressed: _busy ? null : _sendText,
                          icon: _busy && _sendingFileName == null
                              ? const SizedBox.square(
                                  dimension: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.send),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            if (_dragging)
              Positioned.fill(
                child: IgnorePointer(
                  child: ColoredBox(
                    color: Theme.of(context).colorScheme.primaryContainer
                        .withValues(alpha: 0.92),
                    child: const Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.file_download_outlined, size: 72),
                          SizedBox(height: 12),
                          Text('松开鼠标发送文件'),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _SendMessageIntent extends Intent {
  const _SendMessageIntent();
}

enum _ConversationAction { clear, remove }

enum _TransferDirection { sending, receiving }

class _TransferProgress extends StatelessWidget {
  const _TransferProgress({
    required this.direction,
    required this.fileName,
    required this.progress,
    required this.transferredBytes,
    required this.totalBytes,
    required this.bytesPerSecond,
    this.onCancel,
    this.isCancelling = false,
  });

  final _TransferDirection direction;
  final String fileName;
  final double progress;
  final int transferredBytes;
  final int totalBytes;
  final double bytesPerSecond;
  final VoidCallback? onCancel;
  final bool isCancelling;

  @override
  Widget build(BuildContext context) {
    final percent = (progress * 100).toStringAsFixed(0);
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    direction == _TransferDirection.sending
                        ? (progress == 0
                              ? '等待对方确认：$fileName'
                              : '正在发送：$fileName')
                        : (progress >= 1
                              ? '正在保存到系统文件夹：$fileName'
                              : progress == 0
                              ? '准备接收：$fileName'
                              : '正在接收：$fileName'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text('$percent%'),
                if (onCancel != null) ...[
                  const SizedBox(width: 4),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    tooltip: isCancelling ? '正在停止' : '停止发送',
                    onPressed: isCancelling ? null : onCancel,
                    icon: isCancelling
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.stop_circle_outlined),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 7),
            LinearProgressIndicator(value: progress),
            const SizedBox(height: 4),
            Text(
              '${_formatBytes(transferredBytes)} / ${_formatBytes(totalBytes)}'
              '  ·  ${_formatSpeed(bytesPerSecond)}',
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ],
        ),
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({required this.message});

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final outgoing = message.isOutgoing;
    return Align(
      alignment: outgoing ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 560),
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 7),
        decoration: BoxDecoration(
          color: outgoing
              ? colors.primaryContainer
              : colors.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (message.kind == ChatMessageKind.text)
              _TextMessage(text: message.text ?? '')
            else
              _FileMessage(message: message),
            const SizedBox(height: 4),
            Text(
              _formatTime(message.sentAt),
              style: Theme.of(context).textTheme.labelSmall
                  ?.copyWith(color: colors.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

class _TextMessage extends StatelessWidget {
  const _TextMessage({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final uri = _httpUri(text);
    if (uri == null) return SelectableText(text);
    return InkWell(
      onTap: () => launchUrl(uri, mode: LaunchMode.externalApplication),
      child: Text(
        text,
        style: TextStyle(
          color: Theme.of(context).colorScheme.primary,
          decoration: TextDecoration.underline,
        ),
      ),
    );
  }
}

class _FileMessage extends StatelessWidget {
  const _FileMessage({required this.message});

  static final ReceivedFileService _fileService = ReceivedFileService();

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final filePath = message.filePath;
    final isImage = _isImageFile(message.fileName ?? filePath ?? '');
    final file = filePath == null ? null : File(filePath);
    final localExists = file?.existsSync() ?? false;
    final canOpen = localExists || message.contentUri != null;
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: canOpen
          ? () async {
              try {
                await _fileService.openFile(
                  filePath: filePath,
                  contentUri: message.contentUri,
                );
              } catch (error) {
                if (!context.mounted) return;
                ScaffoldMessenger.of(context)
                    .showSnackBar(SnackBar(content: Text('无法打开文件：$error')));
              }
            }
          : null,
      child: Padding(
        padding: const EdgeInsets.all(2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (isImage && localExists)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(9),
                  child: Image.file(
                    file!,
                    width: 260,
                    height: 190,
                    cacheWidth: 780,
                    cacheHeight: 570,
                    fit: BoxFit.cover,
                    filterQuality: FilterQuality.low,
                    errorBuilder: (_, _, _) => const SizedBox.shrink(),
                  ),
                ),
              ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  isImage
                      ? Icons.image_outlined
                      : Icons.insert_drive_file_outlined,
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        message.fileName ?? '文件',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (message.fileSize != null)
                        Text(
                          _formatBytes(message.fileSize!),
                          style: Theme.of(context).textTheme.labelSmall,
                        ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 5),
            Text(
              canOpen
                  ? (message.isOutgoing ? '点击打开本机文件' : '点击选择应用打开')
                  : message.displayLocation ?? '文件已被移动或删除',
              style: Theme.of(context).textTheme.labelSmall,
            ),
            if ((message.displayLocation != null || filePath != null) &&
                canOpen) ...[
              const SizedBox(height: 3),
              Text(
                '保存位置：${message.displayLocation ?? filePath}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

Uri? _httpUri(String value) {
  final uri = Uri.tryParse(value.trim());
  if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
    return null;
  }
  return uri.host.isEmpty ? null : uri;
}

bool _isImageFile(String value) {
  const extensions = {'.jpg', '.jpeg', '.png', '.gif', '.webp', '.bmp'};
  return extensions.contains(path.extension(value).toLowerCase());
}

String _formatTime(DateTime value) {
  final local = value.toLocal();
  final hour = local.hour.toString().padLeft(2, '0');
  final minute = local.minute.toString().padLeft(2, '0');
  return '$hour:$minute';
}

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  final kib = bytes / 1024;
  if (kib < 1024) return '${kib.toStringAsFixed(1)} KiB';
  final mib = kib / 1024;
  if (mib < 1024) return '${mib.toStringAsFixed(1)} MiB';
  return '${(mib / 1024).toStringAsFixed(2)} GiB';
}

String _formatSpeed(double bytesPerSecond) {
  if (!bytesPerSecond.isFinite || bytesPerSecond <= 0) return '测速中';
  return '${_formatBytes(bytesPerSecond.round())}/s';
}
