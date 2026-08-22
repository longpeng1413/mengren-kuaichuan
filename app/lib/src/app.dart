import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import 'chat/chat_message.dart';
import 'chat/chat_page.dart';
import 'app_version.dart';
import 'device/device_identity.dart';
import 'diagnostics/diagnostic_log_service.dart';
import 'discovery/discovered_device.dart';
import 'discovery/device_merge.dart';
import 'discovery/discovery_service.dart';
import 'pairing/pairing_endpoint.dart';
import 'pairing/pairing_page.dart';
import 'pairing/pairing_relay.dart';
import 'settings/app_settings.dart';
import 'settings/settings_page.dart';
import 'storage/received_file_service.dart';
import 'transfer/transfer_client.dart';
import 'transfer/transfer_models.dart';
import 'transfer/transfer_server.dart';

typedef SaveIdentity = Future<void> Function(DeviceIdentity identity);

class LanTransferApp extends StatefulWidget {
  const LanTransferApp({
    required this.initialIdentity,
    required this.pairingCode,
    required this.initialSettings,
    required this.saveSettings,
    required this.saveIdentity,
    super.key,
  });

  final DeviceIdentity initialIdentity;
  final String pairingCode;
  final AppSettings initialSettings;
  final Future<void> Function(AppSettings settings) saveSettings;
  final SaveIdentity saveIdentity;

  @override
  State<LanTransferApp> createState() => _LanTransferAppState();
}

class _LanTransferAppState extends State<LanTransferApp> {
  late DeviceIdentity _identity;
  late AppSettings _settings;

  @override
  void initState() {
    super.initState();
    _identity = widget.initialIdentity;
    _settings = widget.initialSettings;
  }

  Future<void> _saveSettings(AppSettings settings) async {
    await widget.saveSettings(settings);
    if (mounted) setState(() => _settings = settings);
  }

  Future<void> _saveIdentity(DeviceIdentity identity) async {
    await widget.saveIdentity(identity);
    if (mounted) setState(() => _identity = identity);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: appVersionLabel,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: _settings.themeColor.seedColor,
          brightness: Brightness.light,
        ),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: _settings.themeColor.seedColor,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      themeMode: _settings.themeMode.materialMode,
      home: DeviceListPage(
        identity: _identity,
        pairingCode: widget.pairingCode,
        settings: _settings,
        saveSettings: _saveSettings,
        saveIdentity: _saveIdentity,
      ),
    );
  }
}

class DeviceListPage extends StatefulWidget {
  const DeviceListPage({
    required this.identity,
    required this.pairingCode,
    required this.settings,
    required this.saveSettings,
    required this.saveIdentity,
    super.key,
  });

  final DeviceIdentity identity;
  final String pairingCode;
  final AppSettings settings;
  final SaveAppSettings saveSettings;
  final SaveIdentity saveIdentity;

  @override
  State<DeviceListPage> createState() => _DeviceListPageState();
}

class _DeviceListPageState extends State<DeviceListPage> {
  late final DiscoveryService _discovery;
  late final PairingRelay _pairingRelay;
  late final TransferServer _transferServer;
  final TransferClient _transferClient = const TransferClient();
  final PairingStore _pairingStore = PairingStore();
  final RemovedDeviceStore _removedDeviceStore = RemovedDeviceStore();
  final ReceivedFileService _receivedFileService = ReceivedFileService();
  final DiagnosticLogService _diagnostics = DiagnosticLogService.instance;
  StreamSubscription<List<DiscoveredDevice>>? _devicesSubscription;
  StreamSubscription<List<DiscoveredDevice>>? _pairedDevicesSubscription;
  StreamSubscription<void>? _incomingSubscription;
  StreamSubscription<void>? _pairedIncomingSubscription;
  StreamSubscription<CompletedTransfer>? _completedSubscription;
  StreamSubscription<CompletedTransfer>? _pairedCompletedSubscription;
  StreamSubscription<IncomingTextMessage>? _messageSubscription;
  StreamSubscription<IncomingTextMessage>? _pairedMessageSubscription;
  StreamSubscription<TransferProgressUpdate>? _progressSubscription;
  StreamSubscription<TransferProgressUpdate>? _pairedProgressSubscription;
  Timer? _reconnectTimer;
  final ChatHistoryStore _chatStore = ChatHistoryStore();
  final Map<String, List<ChatMessage>> _chatHistory = {};
  final Map<String, ValueNotifier<List<ChatMessage>>> _chatNotifiers = {};
  final Map<String, ValueNotifier<TransferProgressUpdate?>>
  _incomingProgressNotifiers = {};
  final List<String> _pendingSharedFiles = [];
  final Set<String> _sharedCachePaths = {};
  final Set<String> _removedDeviceIds = {};
  PairingEndpoint? _savedPairing;
  List<DiscoveredDevice> _localDevices = const [];
  List<DiscoveredDevice> _pairedDevices = const [];
  List<DiscoveredDevice> _devices = const [];
  String? _statusError;

  @override
  void initState() {
    super.initState();
    _discovery = DiscoveryService(widget.identity);
    _pairingRelay = PairingRelay(
      identity: widget.identity,
      pairingCode: widget.pairingCode,
    );
    _transferServer = TransferServer(pairingRelay: _pairingRelay);
    _devicesSubscription = _discovery.devices.listen((devices) {
      if (!mounted) return;
      if (_localDevices.length != devices.length) {
        unawaited(
          _diagnostics.log('local_devices_changed count=${devices.length}'),
        );
      }
      setState(() {
        _localDevices = devices;
        _mergeDevices();
      });
    });
    _pairedDevicesSubscription = _pairingRelay.devices.listen((devices) {
      if (!mounted) return;
      final previousIds = _pairedDevices
          .map((device) => device.deviceId)
          .toSet();
      final currentIds = devices.map((device) => device.deviceId).toSet();
      if (!previousIds.containsAll(currentIds) ||
          !currentIds.containsAll(previousIds)) {
        unawaited(
          _diagnostics.log('paired_devices_changed count=${devices.length}'),
        );
      }
      setState(() {
        _pairedDevices = devices;
        _mergeDevices();
      });
    });
    _discovery.start().catchError((Object error) {
      if (mounted) {
        setState(() => _statusError = '无法启动局域网发现：$error');
      }
    });
    _incomingSubscription = _transferServer.incoming
        .asyncMap(_handleIncomingTransfer)
        .listen((_) {});
    _pairedIncomingSubscription = _pairingRelay.incoming
        .asyncMap(_handleIncomingTransfer)
        .listen((_) {});
    _completedSubscription = _transferServer.completed.listen(
      _showCompletedTransfer,
    );
    _pairedCompletedSubscription = _pairingRelay.completed.listen(
      _showCompletedTransfer,
    );
    _messageSubscription = _transferServer.messages.listen(_receiveTextMessage);
    _pairedMessageSubscription = _pairingRelay.messages.listen(
      _receiveTextMessage,
    );
    _progressSubscription = _transferServer.incomingProgress.listen(
      _receiveProgress,
    );
    _pairedProgressSubscription = _pairingRelay.incomingProgress.listen(
      _receiveProgress,
    );
    _receivedFileService.setSharedFilesListener(_receiveSharedFiles);
    unawaited(_receivedFileService.takeSharedFiles().then(_receiveSharedFiles));
    unawaited(_loadChatHistory());
    unawaited(_loadRemovedDevices());
    unawaited(_startTransferServer());
  }

  Future<void> _loadRemovedDevices() async {
    final removed = await _removedDeviceStore.load();
    if (!mounted) return;
    setState(() {
      _removedDeviceIds
        ..clear()
        ..addAll(removed);
      _mergeDevices();
    });
  }

  void _receiveSharedFiles(List<String> paths) {
    if (!mounted || paths.isEmpty) return;
    unawaited(_diagnostics.log('shared_files_ready count=${paths.length}'));
    setState(() {
      for (final filePath in paths) {
        if (!_pendingSharedFiles.contains(filePath)) {
          _pendingSharedFiles.add(filePath);
          _sharedCachePaths.add(filePath);
        }
      }
    });
  }

  Future<void> _loadChatHistory() async {
    final stored = await _chatStore.load();
    for (final message in stored) {
      final conversation = _chatHistory.putIfAbsent(message.peerId, () => []);
      if (!conversation.any((existing) => existing.id == message.id)) {
        conversation.add(message);
      }
    }
    for (final entry in _chatHistory.entries) {
      entry.value.sort((left, right) => left.sentAt.compareTo(right.sentAt));
      _chatNotifiers[entry.key]?.value = List.unmodifiable(entry.value);
    }
  }

  ValueNotifier<List<ChatMessage>> _messagesFor(String peerId) {
    return _chatNotifiers.putIfAbsent(
      peerId,
      () => ValueNotifier<List<ChatMessage>>(
        List.unmodifiable(_chatHistory[peerId] ?? const []),
      ),
    );
  }

  ValueNotifier<TransferProgressUpdate?> _incomingProgressFor(String peerId) {
    return _incomingProgressNotifiers.putIfAbsent(
      peerId,
      () => ValueNotifier<TransferProgressUpdate?>(null),
    );
  }

  void _receiveProgress(TransferProgressUpdate progress) {
    if (progress.cancelled) {
      _incomingProgressFor(progress.peerId).value = null;
      return;
    }
    _incomingProgressFor(progress.peerId).value = progress;
  }

  void _receiveTextMessage(IncomingTextMessage message) {
    _appendChat(
      ChatMessage(
        id: message.messageId,
        peerId: message.senderId,
        peerName: message.senderName,
        senderId: message.senderId,
        senderName: message.senderName,
        kind: ChatMessageKind.text,
        sentAt: message.sentAt,
        isOutgoing: false,
        text: message.text,
      ),
    );
  }

  void _appendChat(ChatMessage message) {
    final conversation = _chatHistory.putIfAbsent(message.peerId, () => []);
    if (conversation.any((existing) => existing.id == message.id)) return;
    conversation.add(message);
    conversation.sort((left, right) => left.sentAt.compareTo(right.sentAt));
    _messagesFor(message.peerId).value = List.unmodifiable(conversation);
    unawaited(_chatStore.save(_chatHistory.values.expand((items) => items)));
  }

  void _mergeDevices() {
    _devices = mergeDiscoveredDevices(
      localDevices: _localDevices,
      pairedDevices: _pairedDevices,
    ).where((device) => !_removedDeviceIds.contains(device.deviceId)).toList();
  }

  void _showCompletedTransfer(CompletedTransfer transfer) {
    unawaited(_finalizeCompletedTransfer(transfer));
  }

  Future<void> _finalizeCompletedTransfer(CompletedTransfer transfer) async {
    await _diagnostics.log('receive_finalize_start bytes=${transfer.fileSize}');
    final stored = await _receivedFileService.finalizeReceivedFile(
      transfer.file,
      widget.settings,
    );
    if (!mounted) return;
    unawaited(
      _diagnostics.log('receive_finalize_complete cache=${stored.isCache}'),
    );
    _incomingProgressFor(transfer.senderId).value = null;
    _appendChat(
      ChatMessage(
        id: transfer.transferId,
        peerId: transfer.senderId,
        peerName: transfer.senderName,
        senderId: transfer.senderId,
        senderName: transfer.senderName,
        kind: ChatMessageKind.file,
        sentAt: DateTime.now(),
        isOutgoing: false,
        fileName: path.basename(transfer.file.path),
        filePath: stored.filePath,
        contentUri: stored.contentUri,
        displayLocation: stored.displayLocation,
        fileSize: transfer.fileSize,
        isCache: stored.isCache,
      ),
    );
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '已收到 ${path.basename(transfer.file.path)}\n保存位置：${stored.displayLocation}\n可在对话中点击打开',
        ),
      ),
    );
  }

  Future<void> _startTransferServer() async {
    try {
      await _transferServer.start();
      await _diagnostics.log(
        'transfer_server_started port=${_transferServer.actualPort}',
      );
      await _restorePairing();
    } catch (error) {
      await _diagnostics.log('transfer_server_failed', error: error);
      if (mounted) {
        setState(() => _statusError = '无法启动文件接收服务：$error');
      }
    }
  }

  Future<void> _restorePairing() async {
    _savedPairing = await _pairingStore.loadEndpoint();
    if (!mounted) return;
    await _tryReconnect();
    _reconnectTimer ??= Timer.periodic(
      const Duration(seconds: 5),
      (_) => unawaited(_tryReconnect()),
    );
  }

  Future<void> _tryReconnect() async {
    final endpoint = _savedPairing;
    if (endpoint == null ||
        _pairedDevices.isNotEmpty ||
        _pairingRelay.isConnecting) {
      return;
    }
    try {
      final device = await _pairingRelay.connect(endpoint);
      await _diagnostics.log(
        'pairing_reconnected peer=${device.deviceId.substring(0, 8)}',
      );
    } catch (_) {
      // Keep retrying quietly while the saved computer is offline.
    }
  }

  Future<void> _connectPairing(PairingEndpoint endpoint) async {
    late final DiscoveredDevice device;
    try {
      device = await _pairingRelay.connect(endpoint);
      await _diagnostics.log(
        'pairing_connected peer=${device.deviceId.substring(0, 8)}',
      );
    } catch (error, stackTrace) {
      await _diagnostics.log(
        'pairing_connect_failed',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
    if (_removedDeviceIds.remove(device.deviceId)) {
      await _removedDeviceStore.save(_removedDeviceIds);
      if (mounted) setState(_mergeDevices);
    }
    await _pairingStore.saveEndpoint(endpoint);
    _savedPairing = endpoint;
  }

  Future<void> _openPairingPage() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => PairingPage(
          pairingCode: widget.pairingCode,
          port: _transferServer.actualPort ?? DiscoveryService.transferPort,
          onConnect: _connectPairing,
        ),
      ),
    );
  }

  @override
  void didUpdateWidget(DeviceListPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.identity != widget.identity) {
      _discovery.updateIdentity(widget.identity);
      _pairingRelay.updateIdentity(widget.identity);
    }
  }

  @override
  void dispose() {
    _devicesSubscription?.cancel();
    _pairedDevicesSubscription?.cancel();
    _incomingSubscription?.cancel();
    _pairedIncomingSubscription?.cancel();
    _completedSubscription?.cancel();
    _pairedCompletedSubscription?.cancel();
    _messageSubscription?.cancel();
    _pairedMessageSubscription?.cancel();
    _progressSubscription?.cancel();
    _pairedProgressSubscription?.cancel();
    _reconnectTimer?.cancel();
    _discovery.dispose();
    _transferServer.dispose();
    _receivedFileService.setSharedFilesListener(null);
    for (final notifier in _chatNotifiers.values) {
      notifier.dispose();
    }
    for (final notifier in _incomingProgressNotifiers.values) {
      notifier.dispose();
    }
    super.dispose();
  }

  Future<void> _handleIncomingTransfer(IncomingTransferRequest request) async {
    if (!mounted) {
      request.reject();
      return;
    }

    final navigator = Navigator.of(context);
    final dialog = showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('接收文件？'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('发送设备：${request.senderName}'),
            const SizedBox(height: 8),
            Text('文件：${request.fileName}'),
            const SizedBox(height: 8),
            Text('大小：${_formatBytes(request.fileSize)}'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('拒绝'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('接收'),
          ),
        ],
      ),
    );
    final accepted = await Future.any<bool?>([
      dialog,
      request.cancelled.then((_) {
        if (mounted && navigator.canPop()) navigator.pop(false);
        return false;
      }),
    ]);

    if (accepted != true) {
      unawaited(_diagnostics.log('incoming_transfer_rejected'));
      request.reject();
      return;
    }

    try {
      final destination = await _receiveDirectory();
      unawaited(
        _diagnostics.log(
          'incoming_transfer_accepted bytes=${request.fileSize}',
        ),
      );
      request.accept(destination);
    } catch (error) {
      unawaited(_diagnostics.log('incoming_prepare_failed', error: error));
      request.reject();
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('无法准备接收目录：$error')));
      }
    }
  }

  Future<Directory> _receiveDirectory() async {
    if (Platform.isAndroid) {
      final root = await getTemporaryDirectory();
      final directory = Directory(path.join(root.path, 'incoming'));
      await directory.create(recursive: true);
      return directory;
    }

    final configured = widget.settings.windowsSaveDirectory;
    if (configured != null && configured.trim().isNotEmpty) {
      final directory = Directory(configured);
      await directory.create(recursive: true);
      return directory;
    }
    Directory? root;
    try {
      root = await getDownloadsDirectory();
    } catch (_) {
      root = null;
    }
    root ??= await getApplicationDocumentsDirectory();
    final directory = Directory(path.join(root.path, '猛人快传'));
    await directory.create(recursive: true);
    return directory;
  }

  Future<void> _sendFiles(
    DiscoveredDevice device,
    void Function(String fileName, int sentBytes, int totalBytes) onProgress, {
    Iterable<String>? filePaths,
    TransferCancellationToken? cancellation,
  }) async {
    final List<({String name, String path})> selectedFiles;
    if (filePaths == null) {
      final selection = await FilePicker.platform.pickFiles(
        allowMultiple: true,
        withData: false,
      );
      if (selection == null || selection.files.isEmpty) return;
      selectedFiles = selection.files
          .where((selected) => selected.path != null)
          .map((selected) => (name: selected.name, path: selected.path!))
          .toList();
    } else {
      selectedFiles = filePaths
          .map((filePath) => (name: path.basename(filePath), path: filePath))
          .toList();
    }
    if (selectedFiles.isEmpty) return;

    for (final selectedFile in selectedFiles) {
      cancellation?.throwIfCancelled();
      final file = File(selectedFile.path);
      if (!await file.exists()) {
        throw TransferException('文件不存在或无法读取：${selectedFile.path}');
      }
      final fileSize = await file.length();
      onProgress(selectedFile.name, 0, fileSize);
      late final TransferResult result;
      final directDevice = _directDeviceFor(device.deviceId);
      final usePaired = _pairingRelay.hasSession(device.deviceId);
      var sentBytes = 0;
      await _diagnostics.log(
        'send_start bytes=$fileSize route=${usePaired ? 'paired' : 'direct'}',
      );
      try {
        if (usePaired) {
          try {
            result = await _pairingRelay.sendFile(
              receiverId: device.deviceId,
              file: file,
              onProgress: (sent, total) {
                sentBytes = sent;
                onProgress(selectedFile.name, sent, total);
              },
              cancellation: cancellation,
            );
          } on TransferException catch (error) {
            if (sentBytes != 0 || directDevice == null) rethrow;
            await _diagnostics.log(
              'paired_send_unavailable_fallback_to_direct',
              error: error,
            );
            result = await _transferClient.sendFile(
              receiver: directDevice,
              senderId: widget.identity.deviceId,
              senderName: widget.identity.displayName,
              file: file,
              onProgress: (sent, total) =>
                  onProgress(selectedFile.name, sent, total),
              cancellation: cancellation,
            );
          }
        } else {
          final receiver = directDevice ?? (device.isPaired ? null : device);
          if (receiver == null) {
            throw const TransferException('设备连接已经断开，请等待重新连接');
          }
          result = await _transferClient.sendFile(
            receiver: receiver,
            senderId: widget.identity.deviceId,
            senderName: widget.identity.displayName,
            file: file,
            onProgress: (sent, total) =>
                onProgress(selectedFile.name, sent, total),
            cancellation: cancellation,
          );
        }
      } catch (error, stackTrace) {
        await _diagnostics.log(
          'send_failed route=${usePaired ? 'paired' : 'direct'}',
          error: error,
          stackTrace: stackTrace,
        );
        rethrow;
      }
      unawaited(_diagnostics.log('send_complete bytes=$fileSize'));
      final isSharedCache = _sharedCachePaths.contains(file.path);
      _appendChat(
        ChatMessage(
          id: 'sent-${DateTime.now().microsecondsSinceEpoch}-${result.fileName}',
          peerId: device.deviceId,
          peerName: device.displayName,
          senderId: widget.identity.deviceId,
          senderName: widget.identity.displayName,
          kind: ChatMessageKind.file,
          sentAt: DateTime.now(),
          isOutgoing: true,
          fileName: result.fileName,
          filePath: isSharedCache ? null : file.path,
          displayLocation: isSharedCache ? '系统共享缓存已自动清理' : file.path,
          fileSize: fileSize,
        ),
      );
      if (_sharedCachePaths.remove(file.path) && await file.exists()) {
        await file.delete();
      }
    }
  }

  Future<void> _sendText(DiscoveredDevice device, String text) async {
    late String messageId;
    final directDevice = _directDeviceFor(device.deviceId);
    if (_pairingRelay.hasSession(device.deviceId)) {
      try {
        messageId = await _pairingRelay.sendText(
          receiverId: device.deviceId,
          text: text,
        );
      } on TransferException {
        if (directDevice == null) rethrow;
        messageId = await _transferClient.sendText(
          receiver: directDevice,
          senderId: widget.identity.deviceId,
          senderName: widget.identity.displayName,
          text: text,
        );
      }
    } else {
      final receiver = directDevice ?? (device.isPaired ? null : device);
      if (receiver == null) {
        throw const TransferException('设备连接已经断开，请等待重新连接');
      }
      messageId = await _transferClient.sendText(
        receiver: receiver,
        senderId: widget.identity.deviceId,
        senderName: widget.identity.displayName,
        text: text,
      );
    }
    _appendChat(
      ChatMessage(
        id: messageId,
        peerId: device.deviceId,
        peerName: device.displayName,
        senderId: widget.identity.deviceId,
        senderName: widget.identity.displayName,
        kind: ChatMessageKind.text,
        sentAt: DateTime.now(),
        isOutgoing: true,
        text: text.trim(),
      ),
    );
  }

  DiscoveredDevice? _directDeviceFor(String deviceId) {
    for (final device in _localDevices) {
      if (device.deviceId == deviceId) return device;
    }
    return null;
  }

  Future<void> _openChat(DiscoveredDevice device) async {
    final sharedFiles = List<String>.from(_pendingSharedFiles);
    if (sharedFiles.isNotEmpty) {
      setState(() => _pendingSharedFiles.clear());
    }
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => ChatPage(
          device: device,
          messages: _messagesFor(device.deviceId),
          incomingProgress: _incomingProgressFor(device.deviceId),
          onSendText: (text) => _sendText(device, text),
          onSendFiles: (filePaths, onProgress, cancellation) => _sendFiles(
            device,
            onProgress,
            filePaths: filePaths,
            cancellation: cancellation,
          ),
          initialFilePaths: sharedFiles,
          onClearConversation: (deleteCache) =>
              _clearConversation(device.deviceId, deleteCache: deleteCache),
          onRemoveDevice: () => _removeDevice(device),
        ),
      ),
    );
    final remaining = <String>[];
    for (final filePath in sharedFiles) {
      if (await File(filePath).exists()) remaining.add(filePath);
    }
    if (mounted && remaining.isNotEmpty) {
      setState(() => _pendingSharedFiles.addAll(remaining));
    }
  }

  Future<void> _clearConversation(
    String deviceId, {
    required bool deleteCache,
  }) async {
    final messages = _chatHistory.remove(deviceId) ?? const <ChatMessage>[];
    if (deleteCache) {
      for (final message in messages.where((message) => message.isCache)) {
        final filePath = message.filePath;
        if (filePath == null) continue;
        final file = File(filePath);
        if (await file.exists()) await file.delete();
      }
    }
    _messagesFor(deviceId).value = const [];
    await _chatStore.save(_chatHistory.values.expand((items) => items));
  }

  Future<void> _removeDevice(DiscoveredDevice device) async {
    await _clearConversation(device.deviceId, deleteCache: true);
    await _pairingRelay.disconnect(device.deviceId);
    await _pairingStore.clearEndpoint();
    _savedPairing = null;
    _removedDeviceIds.add(device.deviceId);
    await _removedDeviceStore.save(_removedDeviceIds);
    if (mounted) {
      setState(_mergeDevices);
    }
  }

  Future<void> _discardSharedFiles() async {
    final paths = List<String>.from(_pendingSharedFiles);
    setState(() => _pendingSharedFiles.clear());
    for (final filePath in paths) {
      _sharedCachePaths.remove(filePath);
      final file = File(filePath);
      if (await file.exists()) await file.delete();
    }
  }

  Future<void> _renameDevice() async {
    final name = await showDialog<String>(
      context: context,
      builder: (context) =>
          _RenameDeviceDialog(initialName: widget.identity.displayName),
    );

    final trimmed = name?.trim();
    if (trimmed == null || trimmed.isEmpty || trimmed.length > 40) return;
    await widget.saveIdentity(widget.identity.copyWith(displayName: trimmed));
  }

  Future<void> _openSettings() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => SettingsPage(
          initialSettings: widget.settings,
          saveSettings: widget.saveSettings,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(appVersionLabel),
        actions: [
          IconButton(
            tooltip: '设置',
            onPressed: _openSettings,
            icon: const Icon(Icons.settings_outlined),
          ),
          IconButton(
            tooltip: '二维码 / 手动连接',
            onPressed: _openPairingPage,
            icon: const Icon(Icons.qr_code_2),
          ),
          IconButton(
            tooltip: '立即重新发现',
            onPressed: _discovery.announce,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Column(
        children: [
          _IdentityCard(identity: widget.identity, onRename: _renameDevice),
          if (_statusError != null)
            MaterialBanner(
              content: Text(_statusError!),
              actions: [
                TextButton(
                  onPressed: () => setState(() => _statusError = null),
                  child: const Text('知道了'),
                ),
              ],
            ),
          if (_pendingSharedFiles.isNotEmpty)
            MaterialBanner(
              leading: const Icon(Icons.share_outlined),
              content: Text(
                '已从系统分享或“其他应用打开”接收 ${_pendingSharedFiles.length} 个文件，请点击一个设备发送',
              ),
              actions: [
                TextButton(
                  onPressed: _discardSharedFiles,
                  child: const Text('取消发送'),
                ),
              ],
            ),
          Expanded(
            child: _devices.isEmpty
                ? _EmptyDevices(onPair: _openPairingPage)
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                    itemCount: _devices.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (context, index) {
                      final device = _devices[index];
                      return Card(
                        child: ListTile(
                          leading: Icon(
                            device.platform == 'android'
                                ? Icons.smartphone
                                : Icons.computer,
                          ),
                          title: Text(device.displayName),
                          subtitle: Text(
                            '${device.platform == 'android' ? 'Android' : 'Windows'}'
                            ' · ${device.isPaired ? '二维码连接' : device.address.address}'
                            ' · ${device.shortId} · 点击打开对话',
                          ),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => _openChat(device),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _RenameDeviceDialog extends StatefulWidget {
  const _RenameDeviceDialog({required this.initialName});

  final String initialName;

  @override
  State<_RenameDeviceDialog> createState() => _RenameDeviceDialogState();
}

class _RenameDeviceDialogState extends State<_RenameDeviceDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialName);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _save() => Navigator.pop(context, _controller.text);

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('修改设备名称'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        maxLength: 40,
        decoration: const InputDecoration(
          labelText: '设备名称',
          hintText: '例如：小李的笔记本',
        ),
        onSubmitted: (_) => _save(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _save, child: const Text('保存')),
      ],
    );
  }
}

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  final kibibytes = bytes / 1024;
  if (kibibytes < 1024) return '${kibibytes.toStringAsFixed(1)} KiB';
  final mebibytes = kibibytes / 1024;
  if (mebibytes < 1024) return '${mebibytes.toStringAsFixed(1)} MiB';
  return '${(mebibytes / 1024).toStringAsFixed(2)} GiB';
}

class _IdentityCard extends StatelessWidget {
  const _IdentityCard({required this.identity, required this.onRename});

  final DeviceIdentity identity;
  final VoidCallback onRename;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: ListTile(
        leading: const CircleAvatar(child: Icon(Icons.wifi_tethering)),
        title: Text(identity.displayName),
        subtitle: Text('本机 · ${identity.shortId} · 正在局域网内广播'),
        trailing: IconButton(
          tooltip: '修改设备名称',
          onPressed: onRename,
          icon: const Icon(Icons.edit_outlined),
        ),
      ),
    );
  }
}

class _EmptyDevices extends StatelessWidget {
  const _EmptyDevices({required this.onPair});

  final VoidCallback onPair;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.devices_other,
              size: 64,
              color: Theme.of(context).colorScheme.outline,
            ),
            const SizedBox(height: 16),
            Text(
              '正在查找同一局域网内的设备',
              style: Theme.of(context).textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            const Text(
              '同一子网会自动出现；跨路由网络请使用二维码或手动连接。',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 18),
            OutlinedButton.icon(
              onPressed: onPair,
              icon: const Icon(Icons.qr_code_2),
              label: const Text('二维码 / 手动连接'),
            ),
          ],
        ),
      ),
    );
  }
}
