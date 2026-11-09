import 'dart:async';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;

import '../discovery/discovered_device.dart';
import '../storage/received_file_service.dart';
import '../transfer/transfer_client.dart' show TransferException;
import '../transfer/transfer_models.dart';
import 'chat_message.dart';
import 'chat_dates.dart';
import 'chat_quote.dart';
import 'chat_text_message.dart';
import 'chat_thumbnail.dart';
import 'clipboard_files.dart';
import '../voice/speech_download_dialog.dart';
import '../voice/speech_service.dart';
import '../voice/voice_audio.dart';
import '../voice/voice_level.dart';
import '../voice/voice_store.dart';

typedef SendChatText = Future<void> Function(String text);
typedef ClearConversation = Future<void> Function(bool deleteCache);
typedef RemoveDevice = Future<void> Function();
typedef CancelIncomingTransfer = Future<void> Function(String transferId);
typedef PickAndSendFiles = Future<void> Function(
  Iterable<String>? filePaths,
  void Function(String fileName, int sentBytes, int totalBytes) onProgress,
  TransferCancellationToken cancellation,
);

/// Forwards [message] to [target]; returns a short note for the user, or null
/// when the app switched to the target conversation to show the progress.
typedef ForwardChatMessage = Future<String?> Function(
  ChatMessage message,
  DiscoveredDevice target,
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
    this.onCancelIncomingTransfer,
    this.onDiscardUndelivered,
    this.onDeleteMessage,
    this.onForward,
    this.forwardTargets,
    this.clipboard,
    this.onTranscribed,
    this.voiceRecorder,
    this.speech,
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
  final CancelIncomingTransfer? onCancelIncomingTransfer;

  /// Cancels a queued message/file or removes one that failed to send.
  final void Function(String messageId)? onDiscardUndelivered;

  /// Long-press 删除: removes the message from this device's history only.
  final Future<void> Function(ChatMessage message)? onDeleteMessage;

  /// Long-press 转发 to another device (online, offline or via VPS).
  final ForwardChatMessage? onForward;
  final List<DiscoveredDevice> Function()? forwardTargets;

  /// Pasting pictures/files from the clipboard; tests pass a fake.
  final ClipboardFileSource? clipboard;

  /// Saves the text of a voice message (转文字), or null to hide it.
  final Future<void> Function(ChatMessage message, String? text)?
  onTranscribed;

  /// Microphone and offline speech recognition; tests pass fakes.
  final VoiceRecorder? voiceRecorder;
  final SpeechEngine? speech;
  final List<String> initialFilePaths;

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final TextEditingController _textController = TextEditingController();
  final FocusNode _inputFocus = FocusNode();
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
  bool _incomingCancelling = false;

  /// The message shown above the input box while replying with a quote.
  ChatMessage? _quoting;

  /// One key per message row, so a tapped quote can scroll to the original.
  final Map<String, GlobalKey> _messageKeys = {};

  /// The original message briefly highlighted after jumping to it.
  String? _highlightedId;
  Timer? _highlightTimer;

  ClipboardFileSource get _clipboard =>
      widget.clipboard ?? PlatformClipboardFiles.instance;

  // ---- 语音 ----
  late final VoiceRecorder _recorder =
      widget.voiceRecorder ?? PlatformVoiceRecorder();
  SpeechEngine get _speech => widget.speech ?? const PlatformSpeechEngine();

  /// Holding the mic button records a voice message; tapping it dictates
  /// text into the input box.
  _VoiceMode? _recordingMode;
  DateTime? _recordStartedAt;
  File? _recordingFile;
  Future<bool>? _recordingStart;
  Timer? _recordTicker;
  bool _cancelArmed = false;
  bool _dictating = false;
  final Set<String> _transcribingIds = {};

  @override
  void initState() {
    super.initState();
    widget.messages.addListener(_messagesChanged);
    widget.incomingProgress.addListener(_incomingProgressChanged);
    final initialIncoming = widget.incomingProgress.value;
    if (initialIncoming != null) {
      _incomingTransferId = initialIncoming.transferId;
      _incomingStartedAt = DateTime.now();
    }
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
    _inputFocus.dispose();
    _scrollController.dispose();
    _highlightTimer?.cancel();
    _recordTicker?.cancel();
    if (_recordingMode != null) {
      unawaited(_recorder.cancel());
      final file = _recordingFile;
      if (file != null) unawaited(file.delete().then((_) {}, onError: (_) {}));
    }
    unawaited(VoicePlayer.instance.stop());
    super.dispose();
  }

  void _messagesChanged() {
    final ids = {for (final message in widget.messages.value) message.id};
    _messageKeys.removeWhere((id, _) => !ids.contains(id));
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
  }

  // ---- 点击引用跳到原消息 ----

  Future<void> _jumpToQuoted(
    List<ChatMessage> messages,
    int replyIndex,
    ChatQuote quote,
  ) async {
    final targetIndex = findQuotedMessage(messages, replyIndex, quote);
    if (targetIndex == null) {
      _showNotice('找不到原消息，可能已经被删除');
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('跳转到原消息？'),
        content: Text(
          '${quote.senderName}：${quote.snippet}',
          maxLines: 4,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('跳转'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final target = messages[targetIndex];
    if (!await _scrollToMessage(messages, targetIndex)) {
      _showNotice('没能定位到原消息');
      return;
    }
    if (!mounted) return;
    _highlightTimer?.cancel();
    setState(() => _highlightedId = target.id);
    _highlightTimer = Timer(const Duration(milliseconds: 1800), () {
      if (mounted) setState(() => _highlightedId = null);
    });
  }

  /// Rows have different heights and far rows are not built yet, so jump to
  /// the estimated position first, then step a screen at a time until the
  /// row exists, and finally scroll it smoothly into view.
  Future<bool> _scrollToMessage(List<ChatMessage> messages, int index) async {
    final id = messages[index].id;
    for (var attempt = 0; attempt < 60; attempt++) {
      final rowContext = _messageKeys[id]?.currentContext;
      if (rowContext != null && rowContext.mounted) {
        await Scrollable.ensureVisible(
          rowContext,
          alignment: 0.3,
          duration: const Duration(milliseconds: 280),
          curve: Curves.easeOut,
        );
        return true;
      }
      if (!_scrollController.hasClients) return false;
      final position = _scrollController.position;
      final double next;
      if (attempt == 0) {
        next = messages.length <= 1
            ? 0
            : position.maxScrollExtent * index / (messages.length - 1);
      } else {
        int? firstBuilt;
        for (var i = 0; i < messages.length; i++) {
          if (_messageKeys[messages[i].id]?.currentContext != null) {
            firstBuilt = i;
            break;
          }
        }
        if (firstBuilt == null) return false;
        final step = position.viewportDimension * 0.8;
        next = index < firstBuilt
            ? position.pixels - step
            : position.pixels + step;
      }
      final clamped = next
          .clamp(position.minScrollExtent, position.maxScrollExtent)
          .toDouble();
      if (attempt > 0 && clamped == position.pixels) return false;
      position.jumpTo(clamped);
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return false;
    }
    return false;
  }

  void _incomingProgressChanged() {
    final progress = widget.incomingProgress.value;
    if (progress == null) {
      _incomingTransferId = null;
      _incomingStartedAt = null;
      _incomingBytesPerSecond = 0;
      _incomingCancelling = false;
    } else {
      final now = DateTime.now();
      if (_incomingTransferId != progress.transferId ||
          progress.transferredBytes == 0) {
        _incomingTransferId = progress.transferId;
        _incomingStartedAt = now;
        _incomingBytesPerSecond = 0;
        _incomingCancelling = false;
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
    final quoting = _quoting;
    setState(() => _busy = true);
    try {
      await widget.onSendText(
        quoting == null ? text : composeQuotedText(quoteFor(quoting), text),
      );
      _textController.clear();
      if (mounted && identical(_quoting, quoting)) {
        setState(() => _quoting = null);
      }
    } catch (error) {
      _showError(error);
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        // Keep typing after Enter without clicking back into the box.
        _inputFocus.requestFocus();
      }
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

  Future<void> _cancelIncomingTransfer() async {
    final transferId = _incomingTransferId;
    final cancel = widget.onCancelIncomingTransfer;
    if (transferId == null || cancel == null || _incomingCancelling) return;
    setState(() => _incomingCancelling = true);
    try {
      await cancel(transferId);
    } catch (error) {
      _showError(error);
      if (mounted) setState(() => _incomingCancelling = false);
    }
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
    final details = error.toString();
    final windowsFirewallHint =
        widget.device.platform == 'windows' && details.contains('无法连接接收设备')
        ? '\n请在电脑端重新运行安装目录中的 enable_lan_access.cmd，并允许 Windows 用户账户控制。'
        : '';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('发送失败：$details$windowsFirewallHint')),
    );
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

  void _showNotice(String text, {ScaffoldMessengerState? messenger}) {
    final target =
        messenger ?? (mounted ? ScaffoldMessenger.of(context) : null);
    target?.showSnackBar(SnackBar(content: Text(text)));
  }

  static String _describe(Object error) => switch (error) {
    FileSystemException(:final message) => message,
    TransferException(:final message) => message,
    // Plugins often put the readable text in details (e.g. record on
    // Windows: code "Record", message null, details "指定的对象或值不存在。").
    PlatformException(:final message, :final details) =>
      message ?? details?.toString() ?? '$error',
    _ => '$error',
  };

  // ---- 长按菜单 ----

  List<ChatMessageAction> _actionsFor(
    ChatMessage message, {
    bool inTextMenu = false,
  }) {
    final isText = message.kind == ChatMessageKind.text;
    final filePath = message.filePath;
    final localFile = filePath != null && File(filePath).existsSync();
    final isVoice =
        !isText && isVoiceFileName(message.fileName ?? filePath ?? '');
    return [
      // The text selection menu already has its own 复制.
      if (isText && !inTextMenu)
        ChatMessageAction(
          '复制',
          () => unawaited(_copyMessage(message)),
          icon: Icons.copy_rounded,
        ),
      if (!isText &&
          _clipboard.canCopyFiles &&
          (localFile || (Platform.isAndroid && message.contentUri != null)))
        ChatMessageAction(
          '复制',
          () => unawaited(_copyMessage(message)),
          icon: Icons.copy_rounded,
        ),
      if (widget.onForward != null)
        ChatMessageAction(
          '转发',
          () => unawaited(_forwardMessage(message)),
          icon: Icons.shortcut_rounded,
        ),
      ChatMessageAction(
        '引用',
        () => _startQuote(message),
        icon: Icons.format_quote_rounded,
      ),
      if (!isText && localFile && Platform.isWindows)
        ChatMessageAction(
          '在文件夹中显示',
          () => unawaited(_revealInFolder(filePath)),
          icon: Icons.folder_open_outlined,
        ),
      if (!isText && !Platform.isWindows && message.displayLocation != null)
        ChatMessageAction(
          '保存位置',
          () => _showNotice('保存位置：${message.displayLocation}'),
          icon: Icons.info_outline_rounded,
        ),
      if (isVoice && widget.onTranscribed != null && message.transcript == null)
        ChatMessageAction(
          '转文字',
          () => unawaited(_transcribeMessage(message)),
          icon: Icons.subtitles_outlined,
        ),
      if (isVoice && widget.onTranscribed != null && message.transcript != null)
        ChatMessageAction(
          '隐藏文字',
          () => unawaited(widget.onTranscribed!(message, null)),
          icon: Icons.subtitles_off_outlined,
        ),
      if (widget.onDeleteMessage != null)
        ChatMessageAction(
          '删除',
          () => unawaited(_deleteMessage(message)),
          icon: Icons.delete_outline_rounded,
        ),
    ];
  }

  // ---- 语音消息与语音输入 ----

  Future<bool> _startRecording(_VoiceMode mode) async {
    if (_recordingMode != null || _dictating) return false;
    if (!await _recorder.ensurePermission()) {
      _showNotice(
        Platform.isWindows
            ? '无法使用麦克风：请在 Windows 设置 → 隐私和安全性 → 麦克风 中允许桌面应用访问麦克风'
            : '没有麦克风权限，请在手机设置里允许猛人快传使用麦克风',
      );
      return false;
    }
    if (!mounted) return false;
    await VoicePlayer.instance.stop();
    final startedAt = DateTime.now();
    final file = await VoiceStore.instance.newRecordingFile(startedAt);
    try {
      await _recorder.start(file.path);
    } catch (error) {
      _showNotice('无法开始录音：${_describe(error)}');
      return false;
    }
    if (!mounted) {
      await _recorder.cancel();
      return false;
    }
    if (Platform.isAndroid) unawaited(HapticFeedback.mediumImpact());
    setState(() {
      _recordingMode = mode;
      _recordStartedAt = startedAt;
      _recordingFile = file;
      _cancelArmed = false;
    });
    _recordTicker = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (!mounted) return;
      final elapsed = DateTime.now().difference(startedAt);
      if (elapsed.inSeconds >= maximumVoiceSeconds) {
        // WeChat-style limit: a voice message is sent at 60 s.
        unawaited(
          _recordingMode == _VoiceMode.message
              ? _finishVoiceMessage(send: true)
              : _finishDictation(),
        );
      } else {
        setState(() {});
      }
    });
    return true;
  }

  /// Stops the recorder; returns the recorded file and its length.
  Future<({File file, Duration length, DateTime startedAt})?>
  _stopRecording() async {
    final starting = _recordingStart;
    if (starting != null && !await starting) return null;
    final file = _recordingFile;
    final startedAt = _recordStartedAt;
    _recordTicker?.cancel();
    _recordTicker = null;
    if (file == null || startedAt == null) return null;
    String? recorded;
    try {
      recorded = await _recorder.stop();
    } catch (_) {}
    final length = DateTime.now().difference(startedAt);
    if (mounted) {
      setState(() {
        _recordingMode = null;
        _recordingFile = null;
        _recordStartedAt = null;
        _cancelArmed = false;
      });
    }
    return (
      file: File(recorded ?? file.path),
      length: length,
      startedAt: startedAt,
    );
  }

  Future<void> _finishVoiceMessage({required bool send}) async {
    if (_recordingMode != _VoiceMode.message && _recordingStart == null) {
      return;
    }
    final recorded = await _stopRecording();
    _recordingStart = null;
    if (recorded == null) return;
    if (!send || recorded.length < const Duration(seconds: 1)) {
      await _deleteQuietly(recorded.file);
      if (send) _showNotice('说话时间太短');
      return;
    }
    final seconds = (recorded.length.inMilliseconds / 1000).round().clamp(
      1,
      maximumVoiceSeconds,
    );
    final File voice;
    try {
      voice = await VoiceStore.instance.finishRecording(
        recorded.file,
        recorded.startedAt,
        seconds,
      );
    } catch (error) {
      _showNotice('录音保存失败：${_describe(error)}');
      return;
    }
    // Laptop/USB-camera microphones record far below normal speech level.
    await _normalizeQuietly(voice);
    if (mounted) await _sendFiles([voice.path]);
  }

  Future<void> _toggleDictation() async {
    if (_recordingMode == _VoiceMode.dictation) {
      await _finishDictation();
      return;
    }
    if (_recordingMode != null || _dictating || _busy) return;
    if (!await ensureSpeechModel(context, _speech) || !mounted) return;
    final start = _startRecording(_VoiceMode.dictation);
    _recordingStart = start;
    await start;
    _recordingStart = null;
  }

  Future<void> _finishDictation() async {
    if (_recordingMode != _VoiceMode.dictation) return;
    final recorded = await _stopRecording();
    if (recorded == null) return;
    if (recorded.length < const Duration(milliseconds: 600)) {
      await _deleteQuietly(recorded.file);
      return;
    }
    setState(() => _dictating = true);
    try {
      await _normalizeQuietly(recorded.file);
      final text = await _speech.transcribe(recorded.file.path);
      if (!mounted) return;
      if (text.isEmpty) {
        _showNotice('没有识别出文字，请靠近麦克风再说一次');
        return;
      }
      final value = _textController.value;
      final selection = value.selection;
      final start = selection.isValid ? selection.start : value.text.length;
      final end = selection.isValid ? selection.end : value.text.length;
      final updated = value.text.replaceRange(start, end, text);
      _textController.value = TextEditingValue(
        text: updated,
        selection: TextSelection.collapsed(offset: start + text.length),
      );
      _inputFocus.requestFocus();
    } catch (error) {
      _showNotice('语音输入失败：${_describe(error)}');
    } finally {
      // Dictation audio is only needed for recognition.
      await _deleteQuietly(recorded.file);
      if (mounted) setState(() => _dictating = false);
    }
  }

  /// A failed volume adjustment must never stop the message itself.
  static Future<void> _normalizeQuietly(File file) async {
    try {
      await normalizeVoiceFile(file);
    } catch (_) {}
  }

  static Future<void> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  Future<void> _toggleVoicePlayback(ChatMessage message) async {
    final filePath = message.filePath;
    if (filePath == null || !File(filePath).existsSync()) {
      _showNotice('语音已过期或被删除');
      return;
    }
    try {
      await VoicePlayer.instance.toggle(message.id, filePath);
    } catch (error) {
      _showNotice('无法播放：${_describe(error)}');
    }
  }

  Future<void> _transcribeMessage(ChatMessage message) async {
    final save = widget.onTranscribed;
    final filePath = message.filePath;
    if (save == null || _transcribingIds.contains(message.id)) return;
    if (filePath == null || !File(filePath).existsSync()) {
      _showNotice('语音已过期或被删除，无法转文字');
      return;
    }
    if (!await ensureSpeechModel(context, _speech) || !mounted) return;
    setState(() => _transcribingIds.add(message.id));
    try {
      final text = await _speech.transcribe(filePath);
      await save(message, text.isEmpty ? '（没有识别出文字）' : text);
    } catch (error) {
      _showNotice('转文字失败：${_describe(error)}');
    } finally {
      if (mounted) setState(() => _transcribingIds.remove(message.id));
    }
  }

  void _startQuote(ChatMessage message) {
    setState(() => _quoting = message);
    _inputFocus.requestFocus();
  }

  Future<void> _copyMessage(ChatMessage message) async {
    try {
      if (message.kind == ChatMessageKind.text) {
        await Clipboard.setData(
          ClipboardData(text: parseQuotedText(message.text ?? '').reply),
        );
        _showNotice('已复制');
        return;
      }
      final filePath = message.filePath;
      final localFile = filePath != null && File(filePath).existsSync();
      // Android files saved through 系统下载 only have a content URI.
      final source = localFile
          ? filePath
          : Platform.isAndroid
          ? message.contentUri
          : null;
      if (source == null) {
        throw const FileSystemException('文件已被移动或删除');
      }
      await _clipboard.copyFiles([source]);
      final picture = isImageFileName(message.fileName ?? filePath ?? '');
      _showNotice(
        Platform.isAndroid
            ? (picture
                  ? '图片已复制，可以到微信等应用里长按输入框粘贴'
                  : '文件已复制，可以到支持粘贴文件的应用里粘贴')
            : picture
            ? '图片已复制，可以粘贴到微信、QQ、画图或文件夹里'
            : '文件已复制，可以粘贴到文件夹或微信里',
      );
    } catch (error) {
      _showNotice('复制失败：${_describe(error)}');
    }
  }

  Future<void> _revealInFolder(String filePath) async {
    try {
      await Process.start('explorer.exe', ['/select,', filePath]);
    } catch (error) {
      _showNotice('无法打开文件夹：${_describe(error)}');
    }
  }

  Future<void> _deleteMessage(ChatMessage message) async {
    final delete = widget.onDeleteMessage;
    if (delete == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除这条消息？'),
        content: Text(
          message.kind == ChatMessageKind.file
              ? '只删除本机的聊天记录，已经保存的文件不会删除，对方那边也不受影响。'
              : '只删除本机的聊天记录，对方那边不受影响。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    if (_quoting?.id == message.id) setState(() => _quoting = null);
    try {
      await delete(message);
    } catch (error) {
      _showNotice('删除失败：${_describe(error)}');
    }
  }

  Future<void> _forwardMessage(ChatMessage message) async {
    final forward = widget.onForward;
    if (forward == null) return;
    final candidates = (widget.forwardTargets?.call() ?? const [])
        .where((device) => device.deviceId != widget.device.deviceId)
        .toList();
    if (candidates.isEmpty) {
      _showNotice('附近没有其他设备，请先在另一台设备上打开猛人快传');
      return;
    }
    final target = await showDialog<DiscoveredDevice>(
      context: context,
      builder: (_) => _ForwardDialog(
        devices: candidates,
        preview: quoteSnippetFor(message),
      ),
    );
    if (target == null || !mounted) return;
    // Forwarding a file switches to the target conversation; keep a handle
    // to show the result there.
    final messenger = ScaffoldMessenger.of(context);
    try {
      final note = await forward(message, target);
      if (note != null) _showNotice(note, messenger: messenger);
    } on TransferCancelledException {
      _showNotice('已取消转发', messenger: messenger);
    } catch (error) {
      _showNotice('转发失败：${_describe(error)}', messenger: messenger);
    }
  }

  // ---- 粘贴图片和文件 ----

  Future<void> _pasteAttachments() async {
    if (_busy) {
      _showNotice('正在发送，请稍候再粘贴');
      return;
    }
    ClipboardAttachments attachments;
    try {
      attachments = await _clipboard.read();
    } catch (error) {
      _showNotice('读取剪贴板失败：${_describe(error)}');
      return;
    }
    if (!mounted) return;
    if (attachments.paths.isEmpty) {
      _showNotice(
        attachments.skippedFolders > 0
            ? '暂不支持发送文件夹，请复制文件夹里的文件'
            : '剪贴板里没有可以发送的图片或文件',
      );
      return;
    }
    await _confirmAndSend(
      attachments.paths,
      skippedFolders: attachments.skippedFolders,
    );
  }

  Future<void> _confirmAndSend(
    List<String> paths, {
    int skippedFolders = 0,
  }) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => _PasteConfirmDialog(
        device: widget.device,
        paths: paths,
        skippedFolders: skippedFolders,
      ),
    );
    if (confirmed == true && mounted) {
      await _sendFiles(paths);
      return;
    }
    // A pasted screenshot that was not sent is not kept.
    for (final filePath in paths) {
      if (!OutgoingCache.instance.contains(filePath)) continue;
      try {
        await File(filePath).delete();
      } catch (_) {}
    }
  }

  /// Ctrl+V on Windows: copied files (or a bitmap without text) are offered
  /// for sending; anything else is pasted into the box as usual.
  Future<void> _handlePasteShortcut() async {
    final peek = await _clipboard.peek();
    if (!mounted) return;
    if (peek.files || (peek.image && !peek.text)) {
      await _pasteAttachments();
      return;
    }
    final focusContext = _inputFocus.context;
    if (focusContext != null && focusContext.mounted) {
      Actions.maybeInvoke(
        focusContext,
        const PasteTextIntent(SelectionChangedCause.keyboard),
      );
    }
  }

  /// Android keyboards (Gboard's clipboard panel, stickers) insert pictures
  /// as content instead of text.
  Future<void> _insertKeyboardContent(KeyboardInsertedContent content) async {
    final data = content.data;
    if (data == null || data.isEmpty) {
      _showNotice('输入法没有提供图片内容，请换用长按输入框粘贴');
      return;
    }
    final extension = switch (content.mimeType) {
      'image/gif' => '.gif',
      'image/webp' => '.webp',
      'image/jpeg' || 'image/jpg' => '.jpg',
      _ => '.png',
    };
    try {
      final file = await OutgoingCache.instance.createFile(
        pastedImageName().replaceFirst(RegExp(r'\.png$'), extension),
      );
      await file.writeAsBytes(data, flush: true);
      if (!mounted) {
        await file.delete();
        return;
      }
      await _confirmAndSend([file.path]);
    } catch (error) {
      _showNotice('无法读取输入法的图片：${_describe(error)}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final progress = _totalBytes <= 0
        ? 0.0
        : (_sentBytes / _totalBytes).clamp(0.0, 1.0);
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 4,
        title: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(11),
              ),
              child: Icon(
                widget.device.isRemote
                    ? Icons.cloud_outlined
                    : widget.device.platform == 'android'
                    ? Icons.smartphone_rounded
                    : Icons.laptop_windows_rounded,
                size: 20,
                color: Theme.of(context).colorScheme.onPrimaryContainer,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.device.displayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                  Text(
                    widget.device.isRemote
                        ? '公网 VPS 中转 · 单文件 ≤ 200 MiB · 可随时停止'
                        : widget.device.isOffline
                        ? '离线 · 发的内容会在对方上线后自动送达'
                        : widget.device.routeLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
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
                        onCancel: widget.onCancelIncomingTransfer == null
                            ? null
                            : () => unawaited(_cancelIncomingTransfer()),
                        isCancelling: _incomingCancelling,
                      );
                    },
                  ),
                  Expanded(
                    child: ValueListenableBuilder<List<ChatMessage>>(
                      valueListenable: widget.messages,
                      builder: (context, messages, _) {
                        if (messages.isEmpty) {
                          final theme = Theme.of(context);
                          return Center(
                            child: Padding(
                              padding: const EdgeInsets.all(32),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Container(
                                    width: 72,
                                    height: 72,
                                    decoration: BoxDecoration(
                                      color: theme.colorScheme.primaryContainer
                                          .withValues(alpha: 0.6),
                                      shape: BoxShape.circle,
                                    ),
                                    child: Icon(
                                      Icons.forum_outlined,
                                      size: 32,
                                      color: theme.colorScheme.primary,
                                    ),
                                  ),
                                  const SizedBox(height: 16),
                                  Text(
                                    '还没有消息',
                                    style: theme.textTheme.titleSmall?.copyWith(
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    Platform.isWindows
                                        ? '可以发送文字、链接、图片、视频或文件\n也可以把文件直接拖到这里'
                                        : '可以发送文字、链接、图片、视频或文件',
                                    textAlign: TextAlign.center,
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: theme.colorScheme.onSurfaceVariant,
                                      height: 1.6,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        }
                        return ListView.builder(
                          controller: _scrollController,
                          padding: const EdgeInsets.fromLTRB(16, 16, 16, 10),
                          itemCount: messages.length,
                          itemBuilder: (context, index) {
                            final message = messages[index];
                            final quote = message.kind == ChatMessageKind.text
                                ? parseQuotedText(message.text ?? '').quote
                                : null;
                            final bubble = _MessageBubble(
                                message: message,
                                highlighted: message.id == _highlightedId,
                              transcribing: _transcribingIds.contains(
                                message.id,
                              ),
                              onPlayVoice: () =>
                                  unawaited(_toggleVoicePlayback(message)),
                                onTapQuote: quote == null
                                    ? null
                                    : () => unawaited(
                                        _jumpToQuoted(messages, index, quote),
                                      ),
                                actions: _actionsFor(message),
                                textMenuActions: _actionsFor(
                                  message,
                                  inTextMenu: true,
                                ),
                                onDiscard:
                                    message.deliveryState == null ||
                                        widget.onDiscardUndelivered == null
                                    ? null
                                    : () => widget.onDiscardUndelivered!(
                                        message.id,
                                      ),
                            );
                            // WeChat-style: one date bar above the first
                            // message of each day.
                            final newDay = startsNewDay(
                              index == 0 ? null : messages[index - 1].sentAt,
                              message.sentAt,
                            );
                            return KeyedSubtree(
                              key: _messageKeys.putIfAbsent(
                                message.id,
                                () => GlobalKey(),
                              ),
                              child: newDay
                                  ? Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.stretch,
                                      children: [
                                        _DaySeparator(
                                          label: chatDayLabel(message.sentAt),
                                        ),
                                        bubble,
                                      ],
                                    )
                                  : bubble,
                            );
                          },
                        );
                      },
                    ),
                  ),
                  const Divider(height: 1),
                  if (_recordingMode != null || _dictating)
                    _RecordingBar(
                      mode: _recordingMode,
                      elapsed: _recordStartedAt == null
                          ? Duration.zero
                          : DateTime.now().difference(_recordStartedAt!),
                      cancelArmed: _cancelArmed,
                      recognizing: _dictating,
                    ),
                  if (_quoting != null)
                    _QuoteBar(
                      quote: quoteFor(_quoting!),
                      onClose: () => setState(() => _quoting = null),
                    ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(10, 10, 10, 10),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        IconButton.filledTonal(
                          tooltip: '发送图片、视频或文件',
                          onPressed: _busy ? null : () => _sendFiles(),
                          icon: const Icon(Icons.attach_file),
                        ),
                        const SizedBox(width: 4),
                        _MicButton(
                          key: const Key('mic_button'),
                          enabled: !_busy && !_dictating,
                          recording: _recordingMode != null,
                          onTap: () => unawaited(_toggleDictation()),
                          onHoldStart: () {
                            if (_recordingMode != null || _busy) return;
                            final start = _startRecording(_VoiceMode.message);
                            _recordingStart = start;
                          },
                          onHoldMove: (dy) {
                            final armed = dy < -60;
                            if (armed != _cancelArmed &&
                                _recordingMode == _VoiceMode.message) {
                              setState(() => _cancelArmed = armed);
                            }
                          },
                          onHoldEnd: () => unawaited(
                            _finishVoiceMessage(send: !_cancelArmed),
                          ),
                        ),
                        Expanded(
                          child: Shortcuts(
                            shortcuts: {
                              const SingleActivator(LogicalKeyboardKey.enter):
                                  const _SendMessageIntent(),
                              if (Platform.isWindows)
                                const SingleActivator(
                                  LogicalKeyboardKey.keyV,
                                  control: true,
                                ): const _PasteIntent(),
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
                                _PasteIntent: CallbackAction<_PasteIntent>(
                                  onInvoke: (_) {
                                    unawaited(_handlePasteShortcut());
                                    return null;
                                  },
                                ),
                              },
                              child: TextField(
                                controller: _textController,
                                // Stays enabled while sending: disabling it
                                // dropped the keyboard focus after every
                                // Enter. _sendText ignores Enter while busy.
                                focusNode: _inputFocus,
                                autofocus: !Platform.isAndroid,
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
                                contextMenuBuilder: (context, state) =>
                                    _InputContextMenu(
                                      editableTextState: state,
                                      clipboard: _clipboard,
                                      onPasteAttachments: () {
                                        state.hideToolbar();
                                        unawaited(_pasteAttachments());
                                      },
                                    ),
                                contentInsertionConfiguration:
                                    Platform.isAndroid
                                    ? ContentInsertionConfiguration(
                                        onContentInserted: (content) =>
                                            unawaited(
                                              _insertKeyboardContent(content),
                                            ),
                                      )
                                    : null,
                                decoration: InputDecoration(
                                  hintText: Platform.isAndroid
                                      ? '输入文字，长按可粘贴图片或文件'
                                      : '输入文字，Enter 发送，Ctrl+V 可粘贴图片',
                                  isDense: true,
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(22),
                                    borderSide: BorderSide.none,
                                  ),
                                  enabledBorder: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(22),
                                    borderSide: BorderSide.none,
                                  ),
                                  focusedBorder: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(22),
                                    borderSide: BorderSide(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .primary,
                                      width: 1.5,
                                    ),
                                  ),
                                  contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 16,
                                    vertical: 11,
                                  ),
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

class _PasteIntent extends Intent {
  const _PasteIntent();
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
                    tooltip: isCancelling
                        ? '正在停止'
                        : direction == _TransferDirection.sending
                        ? '停止发送'
                        : '停止接收',
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
  const _MessageBubble({
    required this.message,
    this.actions = const [],
    this.textMenuActions = const [],
    this.onDiscard,
    this.onTapQuote,
    this.highlighted = false,
    this.onPlayVoice,
    this.transcribing = false,
  });

  final ChatMessage message;

  /// Long-press / right-click menu of the bubble.
  final List<ChatMessageAction> actions;

  /// Added to the text selection menu (it brings its own 复制).
  final List<ChatMessageAction> textMenuActions;

  /// Cancels a queued item or deletes a failed one.
  final VoidCallback? onDiscard;

  /// Tap on the grey quote: asks, then scrolls to the original message.
  final VoidCallback? onTapQuote;

  /// Briefly true for the original message after jumping to it.
  final bool highlighted;

  /// Tap on a voice message.
  final VoidCallback? onPlayVoice;

  /// 转文字 is running for this voice message.
  final bool transcribing;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final outgoing = message.isOutgoing;
    final state = message.deliveryState;
    final isText = message.kind == ChatMessageKind.text;
    final isPicture =
        !isText && isImageFileName(message.fileName ?? message.filePath ?? '');
    final voiceSeconds = isText
        ? null
        : voiceSecondsFromName(message.fileName ?? message.filePath ?? '');
    final quoted = isText ? parseQuotedText(message.text ?? '') : null;
    final time = Text(
      _formatTime(message.sentAt),
      style: Theme.of(context).textTheme.labelSmall
          ?.copyWith(color: colors.onSurfaceVariant),
    );

    Widget decorated(Widget child) => Container(
      constraints: const BoxConstraints(maxWidth: 560),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 7),
      decoration: BoxDecoration(
        color: outgoing
            ? colors.primaryContainer
            : colors.surfaceContainerLowest,
        border: outgoing
            ? null
            : Border.all(color: colors.outlineVariant.withValues(alpha: 0.7)),
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(16),
          topRight: const Radius.circular(16),
          bottomLeft: Radius.circular(outgoing ? 16 : 4),
          bottomRight: Radius.circular(outgoing ? 4 : 16),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [child, const SizedBox(height: 4), time],
      ),
    );

    final Widget content;
    if (isText) {
      content = decorated(
        ChatTextMessage(text: quoted!.reply, extraActions: textMenuActions),
      );
    } else if (voiceSeconds != null) {
      content = decorated(
        _VoiceContent(
          messageId: message.id,
          seconds: voiceSeconds,
          outgoing: outgoing,
          available:
              message.filePath != null && File(message.filePath!).existsSync(),
        ),
      );
    } else if (isPicture) {
      // WeChat style: only a small picture, no name/size/location.
      content = ChatImageThumbnail(
        key: ValueKey('thumbnail_${message.id}'),
        filePath: message.filePath,
        contentUri: message.contentUri,
        footer: time,
        alignEnd: outgoing,
        fallback: decorated(_FileCard(message: message)),
      );
    } else {
      content = decorated(_FileCard(message: message));
    }

    void showMenuAt(Offset position) =>
        unawaited(_showMessageMenu(context, position, actions));

    final bubble = AnimatedContainer(
      key: ValueKey('row_${message.id}'),
      duration: const Duration(milliseconds: 250),
      decoration: BoxDecoration(
        color: highlighted
            ? colors.primary.withValues(alpha: 0.14)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Align(
        alignment: outgoing ? Alignment.centerRight : Alignment.centerLeft,
        child: Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: outgoing
                ? CrossAxisAlignment.end
                : CrossAxisAlignment.start,
            children: [
              GestureDetector(
                key: ValueKey('bubble_${message.id}'),
                onTap: isText
                    ? null
                    : voiceSeconds != null
                    ? onPlayVoice
                    : () => _openMessageFile(context, message),
                onLongPressStart: (details) =>
                    showMenuAt(details.globalPosition),
                onSecondaryTapUp: (details) =>
                    showMenuAt(details.globalPosition),
                child: content,
              ),
              if (quoted?.quote != null)
                _QuotedBlock(quote: quoted!.quote!, onTap: onTapQuote),
              if (voiceSeconds != null &&
                  (transcribing || message.transcript != null))
                _TranscriptBlock(
                  text: transcribing ? null : message.transcript,
                ),
            ],
          ),
        ),
      ),
    );
    if (state == null) return bubble;
    final failed = state == ChatDeliveryState.failed;
    final tone = failed ? colors.error : colors.onSurfaceVariant;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Opacity(opacity: failed ? 1 : 0.7, child: bubble),
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                failed ? Icons.error_outline : Icons.schedule,
                size: 14,
                color: tone,
              ),
              const SizedBox(width: 4),
              Flexible(
                child: Text(
                  failed
                      ? '未发送：${message.deliveryNote ?? '发送失败'}'
                      : '等待对方上线，上线后自动发送',
                  key: Key('delivery_${message.id}'),
                  style: Theme.of(context).textTheme.labelSmall
                      ?.copyWith(color: tone),
                ),
              ),
              if (onDiscard != null)
                TextButton(
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                  onPressed: onDiscard,
                  child: Text(failed ? '删除' : '取消'),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

Future<void> _showMessageMenu(
  BuildContext context,
  Offset position,
  List<ChatMessageAction> actions,
) async {
  if (actions.isEmpty) return;
  final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
  final selected = await showMenu<ChatMessageAction>(
    context: context,
    position: RelativeRect.fromRect(
      position & const Size(1, 1),
      Offset.zero & overlay.size,
    ),
    items: [
      for (final action in actions)
        PopupMenuItem<ChatMessageAction>(
          value: action,
          height: 42,
          child: Row(
            children: [
              if (action.icon != null) ...[
                Icon(action.icon, size: 18),
                const SizedBox(width: 12),
              ],
              Text(action.label),
            ],
          ),
        ),
    ],
  );
  selected?.onSelected();
}

final ReceivedFileService _fileService = ReceivedFileService();

Future<void> _openMessageFile(BuildContext context, ChatMessage message) async {
  final filePath = message.filePath;
  final localExists = filePath != null && File(filePath).existsSync();
  if (!localExists && message.contentUri == null) {
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('文件已被移动或删除')));
    return;
  }
  try {
    await _fileService.openFile(
      filePath: localExists ? filePath : null,
      contentUri: message.contentUri,
    );
  } catch (error) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('无法打开文件：$error')));
  }
}

/// A compact file card: type icon, name and size. The save location is in
/// the long-press menu (在文件夹中显示 / 保存位置) instead of taking space here.
class _FileCard extends StatelessWidget {
  const _FileCard({required this.message});

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final filePath = message.filePath;
    final name =
        message.fileName ?? (filePath == null ? '文件' : path.basename(filePath));
    final localExists = filePath != null && File(filePath).existsSync();
    final canOpen = localExists || message.contentUri != null;
    final size = message.fileSize;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(9),
          ),
          child: Icon(
            _fileIconFor(name),
            size: 22,
            color: theme.colorScheme.primary,
          ),
        ),
        const SizedBox(width: 10),
        Flexible(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(name, maxLines: 2, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 2),
              Text(
                canOpen
                    ? (size == null ? '点击打开' : _formatBytes(size))
                    // Files shared from another app are removed after
                    // sending on purpose; say so instead of "deleted".
                    : filePath == null && message.displayLocation != null
                    ? message.displayLocation!
                    : '文件已被移动或删除',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: canOpen
                      ? theme.colorScheme.onSurfaceVariant
                      : theme.colorScheme.error,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

IconData _fileIconFor(String name) {
  switch (path.extension(name).toLowerCase()) {
    case '.jpg':
    case '.jpeg':
    case '.png':
    case '.gif':
    case '.webp':
    case '.bmp':
      return Icons.image_outlined;
    case '.mp4':
    case '.mkv':
    case '.mov':
    case '.avi':
    case '.wmv':
      return Icons.movie_outlined;
    case '.mp3':
    case '.wav':
    case '.flac':
    case '.m4a':
      return Icons.audiotrack_outlined;
    case '.zip':
    case '.rar':
    case '.7z':
    case '.tar':
    case '.gz':
      return Icons.folder_zip_outlined;
    case '.apk':
      return Icons.android_rounded;
    case '.pdf':
      return Icons.picture_as_pdf_outlined;
    case '.doc':
    case '.docx':
    case '.txt':
    case '.md':
      return Icons.description_outlined;
    case '.xls':
    case '.xlsx':
    case '.csv':
      return Icons.table_chart_outlined;
    default:
      return Icons.insert_drive_file_outlined;
  }
}

/// The centred date bar between days (今天 / 昨天 / 星期三 / 11月3日).
class _DaySeparator extends StatelessWidget {
  const _DaySeparator({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 14),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest.withValues(
              alpha: 0.7,
            ),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(
            label,
            key: const Key('day_separator'),
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}

enum _VoiceMode { message, dictation }

/// Hold: voice message (slide up to cancel). Tap: dictation into the box.
class _MicButton extends StatelessWidget {
  const _MicButton({
    required this.enabled,
    required this.recording,
    required this.onTap,
    required this.onHoldStart,
    required this.onHoldMove,
    required this.onHoldEnd,
    super.key,
  });

  final bool enabled;
  final bool recording;
  final VoidCallback onTap;
  final VoidCallback onHoldStart;
  final ValueChanged<double> onHoldMove;
  final VoidCallback onHoldEnd;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Tooltip(
      message: '按住发语音（上滑取消），点一下语音输入文字',
      child: GestureDetector(
        onTap: enabled ? onTap : null,
        onLongPressStart: enabled ? (_) => onHoldStart() : null,
        onLongPressMoveUpdate: enabled
            ? (details) => onHoldMove(details.localOffsetFromOrigin.dy)
            : null,
        onLongPressEnd: enabled ? (_) => onHoldEnd() : null,
        child: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: recording
                ? colors.errorContainer
                : colors.secondaryContainer.withValues(
                    alpha: enabled ? 1 : 0.5,
                  ),
            shape: BoxShape.circle,
          ),
          child: Icon(
            recording ? Icons.mic_rounded : Icons.mic_none_rounded,
            color: recording ? colors.error : colors.onSecondaryContainer,
          ),
        ),
      ),
    );
  }
}

class _RecordingBar extends StatelessWidget {
  const _RecordingBar({
    required this.mode,
    required this.elapsed,
    required this.cancelArmed,
    required this.recognizing,
  });

  final _VoiceMode? mode;
  final Duration elapsed;
  final bool cancelArmed;
  final bool recognizing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final seconds = elapsed.inSeconds;
    final clock = '0:${seconds.toString().padLeft(2, '0')}';
    final String label;
    if (recognizing) {
      label = '正在识别…';
    } else if (mode == _VoiceMode.dictation) {
      label = '正在听写 $clock · 再点一次麦克风结束';
    } else if (cancelArmed) {
      label = '松开手指，取消发送';
    } else {
      label = '正在录音 $clock · 松开发送，上滑取消';
    }
    final danger = cancelArmed && !recognizing;
    return Container(
      key: const Key('recording_bar'),
      width: double.infinity,
      color: danger
          ? theme.colorScheme.errorContainer
          : theme.colorScheme.surfaceContainerHigh,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          if (recognizing)
            const SizedBox.square(
              dimension: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else
            Icon(
              danger ? Icons.cancel_outlined : Icons.fiber_manual_record,
              size: 14,
              color: theme.colorScheme.error,
            ),
          const SizedBox(width: 10),
          Expanded(child: Text(label, style: theme.textTheme.bodySmall)),
          if (!recognizing && mode == _VoiceMode.message)
            Text(
              '最长 $maximumVoiceSeconds 秒',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
        ],
      ),
    );
  }
}

/// ▶ 12″ — width grows with the length, like WeChat.
class _VoiceContent extends StatelessWidget {
  const _VoiceContent({
    required this.messageId,
    required this.seconds,
    required this.outgoing,
    required this.available,
  });

  final String messageId;
  final int seconds;
  final bool outgoing;
  final bool available;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final width = (64 + seconds * 2.6)
        .clamp(available ? 64 : 112, 210)
        .toDouble();
    return ValueListenableBuilder<String?>(
      valueListenable: VoicePlayer.instance.playingId,
      builder: (context, playing, _) {
        final isPlaying = playing == messageId;
        final icon = Icon(
          isPlaying ? Icons.stop_circle_outlined : Icons.graphic_eq_rounded,
          size: 20,
          color: available
              ? theme.colorScheme.primary
              : theme.colorScheme.onSurfaceVariant,
        );
        final label = Text(
          available ? '$seconds″' : '$seconds″ 已过期',
          key: Key('voice_$messageId'),
        );
        return SizedBox(
          width: width,
          child: Row(
            mainAxisAlignment: outgoing
                ? MainAxisAlignment.end
                : MainAxisAlignment.start,
            children: outgoing
                ? [label, const SizedBox(width: 6), icon]
                : [icon, const SizedBox(width: 6), label],
          ),
        );
      },
    );
  }
}

/// The text of a voice message (转文字), under its bubble.
class _TranscriptBlock extends StatelessWidget {
  const _TranscriptBlock({required this.text});

  /// Null while recognizing.
  final String? text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final value = text;
    return Container(
      key: const Key('transcript_block'),
      constraints: const BoxConstraints(maxWidth: 420),
      margin: const EdgeInsets.only(top: 4),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLowest,
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.7),
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: value == null
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox.square(
                  dimension: 12,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 8),
                Text('正在转文字…', style: theme.textTheme.bodySmall),
              ],
            )
          : SelectableText(value, style: theme.textTheme.bodyMedium),
    );
  }
}

/// The grey quote under a reply bubble, as in WeChat.
class _QuotedBlock extends StatelessWidget {
  const _QuotedBlock({required this.quote, this.onTap});

  final ChatQuote quote;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final block = Container(
      constraints: const BoxConstraints(maxWidth: 420),
      margin: const EdgeInsets.only(top: 4),
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.8),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        '${quote.senderName}：${quote.snippet}',
        key: const Key('quoted_block'),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
    if (onTap == null) return block;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: block,
      ),
    );
  }
}

/// Shown above the input box while replying with a quote.
class _QuoteBar extends StatelessWidget {
  const _QuoteBar({required this.quote, required this.onClose});

  final ChatQuote quote;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      key: const Key('quote_bar'),
      color: theme.colorScheme.surfaceContainerHigh,
      padding: const EdgeInsets.fromLTRB(14, 4, 4, 4),
      child: Row(
        children: [
          Icon(
            Icons.format_quote_rounded,
            size: 18,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '引用 ${quote.senderName}：${quote.snippet}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          IconButton(
            tooltip: '取消引用',
            visualDensity: VisualDensity.compact,
            onPressed: onClose,
            icon: const Icon(Icons.close_rounded, size: 18),
          ),
        ],
      ),
    );
  }
}

/// The input box's long-press / right-click menu in Chinese, plus
/// 粘贴图片 / 粘贴文件 when the clipboard holds something to send.
class _InputContextMenu extends StatefulWidget {
  const _InputContextMenu({
    required this.editableTextState,
    required this.clipboard,
    required this.onPasteAttachments,
  });

  final EditableTextState editableTextState;
  final ClipboardFileSource clipboard;
  final VoidCallback onPasteAttachments;

  @override
  State<_InputContextMenu> createState() => _InputContextMenuState();
}

class _InputContextMenuState extends State<_InputContextMenu> {
  ClipboardPeek _peek = ClipboardPeek.empty;

  @override
  void initState() {
    super.initState();
    // The menu is built synchronously; the clipboard check adds its button
    // a moment later.
    unawaited(
      widget.clipboard.peek().then((peek) {
        if (mounted) setState(() => _peek = peek);
      }),
    );
  }

  static String? _chineseLabel(ContextMenuButtonType type) => switch (type) {
    ContextMenuButtonType.cut => '剪切',
    ContextMenuButtonType.copy => '复制',
    ContextMenuButtonType.paste => '粘贴',
    ContextMenuButtonType.selectAll => '全选',
    ContextMenuButtonType.delete => '删除',
    ContextMenuButtonType.lookUp => '查询',
    ContextMenuButtonType.searchWeb => '搜索',
    ContextMenuButtonType.share => '分享',
    _ => null,
  };

  @override
  Widget build(BuildContext context) {
    final items = [
      for (final item in widget.editableTextState.contextMenuButtonItems)
        item.label == null && _chineseLabel(item.type) != null
            ? item.copyWith(label: _chineseLabel(item.type))
            : item,
    ];
    if (_peek.hasAttachment) {
      final pasteIndex = items.indexWhere(
        (item) => item.type == ContextMenuButtonType.paste,
      );
      items.insert(
        pasteIndex < 0 ? 0 : pasteIndex + 1,
        ContextMenuButtonItem(
          label: _peek.files ? '粘贴文件' : '粘贴图片',
          onPressed: widget.onPasteAttachments,
        ),
      );
    }
    return AdaptiveTextSelectionToolbar.buttonItems(
      anchors: widget.editableTextState.contextMenuAnchors,
      buttonItems: items,
    );
  }
}

IconData _deviceIcon(DiscoveredDevice device) => device.isRemote
    ? Icons.cloud_outlined
    : device.platform == 'android'
    ? Icons.smartphone_rounded
    : Icons.laptop_windows_rounded;

class _ForwardDialog extends StatefulWidget {
  const _ForwardDialog({required this.devices, required this.preview});

  final List<DiscoveredDevice> devices;
  final String preview;

  @override
  State<_ForwardDialog> createState() => _ForwardDialogState();
}

class _ForwardDialogState extends State<_ForwardDialog> {
  DiscoveredDevice? _selected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('转发给'),
      contentPadding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 12),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                widget.preview,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall,
              ),
            ),
            const SizedBox(height: 8),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final device in widget.devices)
                    ListTile(
                      key: ValueKey('forward_${device.deviceId}'),
                      leading: Icon(_deviceIcon(device)),
                      title: Text(
                        device.displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        device.isOffline ? '离线 · 上线后自动送达' : device.routeLabel,
                      ),
                      trailing: Icon(
                        _selected?.deviceId == device.deviceId
                            ? Icons.check_circle_rounded
                            : Icons.radio_button_unchecked_rounded,
                        color: _selected?.deviceId == device.deviceId
                            ? theme.colorScheme.primary
                            : theme.colorScheme.outline,
                      ),
                      onTap: () => setState(() => _selected = device),
                    ),
                ],
              ),
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
          onPressed: _selected == null
              ? null
              : () => Navigator.pop(context, _selected),
          child: const Text('发送'),
        ),
      ],
    );
  }
}

class _PasteConfirmDialog extends StatelessWidget {
  const _PasteConfirmDialog({
    required this.device,
    required this.paths,
    this.skippedFolders = 0,
  });

  final DiscoveredDevice device;
  final List<String> paths;
  final int skippedFolders;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final single = paths.length == 1;
    return AlertDialog(
      title: Text('发送给 ${device.displayName}'),
      content: SizedBox(
        width: 340,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (single && isImageFileName(paths.first))
              Center(
                child: ChatImageThumbnail(
                  filePath: paths.first,
                  maxWidth: 260,
                  maxHeight: 260,
                  fallback: Text(path.basename(paths.first)),
                ),
              )
            else
              for (final filePath in paths.take(5))
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      Icon(_fileIconFor(filePath), size: 20),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          path.basename(filePath),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _sizeLabel(filePath),
                        style: theme.textTheme.labelSmall,
                      ),
                    ],
                  ),
                ),
            if (paths.length > 5)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text('等 ${paths.length} 个文件'),
              ),
            if (skippedFolders > 0)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '已跳过 $skippedFolders 个文件夹（暂不支持发送文件夹）',
                  style: theme.textTheme.bodySmall,
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('发送'),
        ),
      ],
    );
  }

  static String _sizeLabel(String filePath) {
    try {
      return _formatBytes(File(filePath).lengthSync());
    } catch (_) {
      return '';
    }
  }
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
