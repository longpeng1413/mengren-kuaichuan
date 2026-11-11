import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:mengren_remote_protocol/remote_protocol.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import 'chat/chat_message.dart';
import 'chat/chat_page.dart';
import 'chat/chat_quote.dart';
import 'chat/clipboard_files.dart';
import 'chat/offline_outbox.dart';
import 'app_version.dart';
import 'background/background_receive.dart';
import 'device/device_identity.dart';
import 'diagnostics/diagnostic_log_service.dart';
import 'discovery/discovered_device.dart';
import 'discovery/device_merge.dart';
import 'discovery/discovery_service.dart';
import 'pairing/pairing_endpoint.dart';
import 'pairing/pairing_page.dart';
import 'pairing/pairing_relay.dart';
import 'remote/remote_access_settings.dart';
import 'settings/app_settings.dart';
import 'settings/settings_page.dart';
import 'settings/trusted_devices.dart';
import 'image_view/desktop_viewer_host.dart';
import 'storage/received_file_service.dart';
import 'transfer/transfer_client.dart';
import 'transfer/transfer_models.dart';
import 'transfer/transfer_server.dart';
import 'ui/app_theme.dart';
import 'ui/device_home_view.dart';
import 'update/app_update_service.dart';
import 'update/update_flow.dart';
import 'voice/voice_level.dart';
import 'voice/voice_store.dart';

typedef SaveIdentity = Future<void> Function(DeviceIdentity identity);

class LanTransferApp extends StatefulWidget {
  const LanTransferApp({
    required this.initialIdentity,
    required this.pairingCode,
    required this.initialSettings,
    required this.initialRemoteSettings,
    required this.saveSettings,
    required this.saveRemoteSettings,
    required this.saveIdentity,
    super.key,
  });

  final DeviceIdentity initialIdentity;
  final String pairingCode;
  final AppSettings initialSettings;
  final RemoteAccessSettings initialRemoteSettings;
  final Future<void> Function(AppSettings settings) saveSettings;
  final Future<void> Function(RemoteAccessSettings settings) saveRemoteSettings;
  final SaveIdentity saveIdentity;

  @override
  State<LanTransferApp> createState() => _LanTransferAppState();
}

class _LanTransferAppState extends State<LanTransferApp> {
  late DeviceIdentity _identity;
  late AppSettings _settings;
  late RemoteAccessSettings _remoteSettings;

  @override
  void initState() {
    super.initState();
    _identity = widget.initialIdentity;
    _settings = widget.initialSettings;
    _remoteSettings = widget.initialRemoteSettings;
  }

  Future<void> _saveSettings(AppSettings settings) async {
    await widget.saveSettings(settings);
    if (mounted) setState(() => _settings = settings);
  }

  Future<void> _saveIdentity(DeviceIdentity identity) async {
    await widget.saveIdentity(identity);
    if (mounted) setState(() => _identity = identity);
  }

  Future<void> _saveRemoteSettings(RemoteAccessSettings settings) async {
    await widget.saveRemoteSettings(settings);
    if (mounted) setState(() => _remoteSettings = settings);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: appVersionLabel,
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(_settings.themeColor.seedColor, Brightness.light),
      darkTheme: buildAppTheme(_settings.themeColor.seedColor, Brightness.dark),
      themeMode: _settings.themeMode.materialMode,
      home: DeviceListPage(
        identity: _identity,
        pairingCode: widget.pairingCode,
        settings: _settings,
        remoteSettings: _remoteSettings,
        saveSettings: _saveSettings,
        saveRemoteSettings: _saveRemoteSettings,
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
    required this.remoteSettings,
    required this.saveSettings,
    required this.saveRemoteSettings,
    required this.saveIdentity,
    super.key,
  });

  final DeviceIdentity identity;
  final String pairingCode;
  final AppSettings settings;
  final RemoteAccessSettings remoteSettings;
  final SaveAppSettings saveSettings;
  final Future<void> Function(RemoteAccessSettings settings) saveRemoteSettings;
  final SaveIdentity saveIdentity;

  @override
  State<DeviceListPage> createState() => _DeviceListPageState();
}

class _DeviceListPageState extends State<DeviceListPage>
    with WidgetsBindingObserver {
  late final DiscoveryService _discovery;
  late final PairingRelay _pairingRelay;
  late final TransferServer _transferServer;
  final TransferClient _transferClient = const TransferClient();
  final PairingStore _pairingStore = PairingStore();
  final RemovedDeviceStore _removedDeviceStore = RemovedDeviceStore();
  final ReceivedFileService _receivedFileService = ReceivedFileService();
  final DiagnosticLogService _diagnostics = DiagnosticLogService.instance;
  final RemoteRelayClient _remoteRelay = RemoteRelayClient();
  final RemoteCryptoWorker _remoteCrypto = RemoteCryptoWorker();
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
  StreamSubscription<String>? _restoreRequestSubscription;
  StreamSubscription<List<RemotePeer>>? _remotePeersSubscription;
  StreamSubscription<void>? _remoteEnvelopeSubscription;
  StreamSubscription<RemoteRelayStatus>? _remoteStatusSubscription;
  StreamSubscription<RemoteRelayException>? _remoteErrorSubscription;
  Timer? _reconnectTimer;
  Timer? _remoteReconnectTimer;
  Timer? _updateCheckTimer;
  Timer? _updatePeriodicTimer;
  bool _androidInForeground = true;
  Future<void> _lifecycleTransition = Future.value();
  final ChatHistoryStore _chatStore = ChatHistoryStore();
  final Map<String, List<ChatMessage>> _chatHistory = {};
  final Map<String, ValueNotifier<List<ChatMessage>>> _chatNotifiers = {};
  final Map<String, ValueNotifier<TransferProgressUpdate?>>
  _incomingProgressNotifiers = {};
  final List<String> _pendingSharedFiles = [];
  final Set<String> _sharedCachePaths = {};
  final Set<String> _removedDeviceIds = {};
  final TrustedDeviceStore _trustedStore = TrustedDeviceStore();
  final Set<String> _trustedDeviceIds = {};
  final KnownDevicePlatformStore _platformStore = KnownDevicePlatformStore();
  final Map<String, String> _knownPlatforms = {};
  final Set<String> _flushingPeers = {};
  List<DiscoveredDevice> _onlineDevices = const [];
  Timer? _outboxTimer;
  int _outboxSequence = 0;
  final Map<String, String> _removedDeviceNames = {};
  PairingEndpoint? _savedPairing;
  List<DiscoveredDevice> _localDevices = const [];
  List<DiscoveredDevice> _pairedDevices = const [];
  List<DiscoveredDevice> _remoteDevices = const [];
  List<DiscoveredDevice> _devices = const [];
  String? _statusError;
  String? _remoteError;
  RemoteRelayStatus _remoteStatus = RemoteRelayStatus.disconnected;
  final Map<String, _RemoteIncomingFile> _remoteIncomingFiles = {};
  final Map<String, Timer> _remoteIncomingTimeouts = {};
  final Map<String, TransferCancellationToken> _remoteOutgoingCancellations =
      {};
  final Set<String> _cancelledRemoteIncomingTransfers = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _discovery = DiscoveryService(
      widget.identity,
      onLog: (message) => unawaited(_diagnostics.log(message)),
    );
    _pairingRelay = PairingRelay(
      identity: widget.identity,
      pairingCode: widget.pairingCode,
    );
    _transferServer = TransferServer(pairingRelay: _pairingRelay);
    if (Platform.isWindows) {
      DesktopImageViewerHost.instance.onSend = _sendFromViewer;
    }
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
    // The other device paired with this one using its pairing code.
    _restoreRequestSubscription = _pairingRelay.restoreRequests.listen(
      (deviceId) => unawaited(() async {
        await _restoreRemovedDevice(deviceId, reason: 'manual_pairing');
        await _trustDevice(deviceId, reason: 'paired_by_peer');
      }()),
    );
    _remotePeersSubscription = _remoteRelay.peerUpdates.listen((peers) {
      if (!mounted) return;
      setState(() {
        _remoteDevices = peers
            .map(
              (peer) => DiscoveredDevice(
                deviceId: peer.deviceId,
                displayName: peer.displayName,
                platform: peer.platform,
                address: InternetAddress.loopbackIPv4,
                transferPort: 0,
                lastSeen: DateTime.now(),
                connectionMode: DeviceConnectionMode.remote,
              ),
            )
            .toList();
        _mergeDevices();
      });
    });
    _remoteEnvelopeSubscription = _remoteRelay.envelopes
        .asyncMap(_handleRemoteEnvelope)
        .listen((_) {});
    _remoteStatusSubscription = _remoteRelay.statuses.listen((status) {
      if (mounted) setState(() => _remoteStatus = status);
      if (status == RemoteRelayStatus.disconnected) {
        unawaited(_handleRemoteDisconnect());
      }
    });
    _remoteErrorSubscription = _remoteRelay.errors.listen((error) {
      if (error.code == 'unknown_receipt') {
        unawaited(_diagnostics.log('remote_late_receipt_ignored'));
        return;
      }
      unawaited(_diagnostics.log('remote_relay_error code=${error.code}'));
      if (mounted) setState(() => _remoteError = _remoteErrorText(error.code));
    });
    _receivedFileService.setSharedFilesListener(_receiveSharedFiles);
    unawaited(_receivedFileService.takeSharedFiles().then(_receiveSharedFiles));
    unawaited(_loadChatHistory());
    unawaited(_loadRemovedDevices());
    unawaited(_startTransferServer());
    unawaited(_applyBackgroundReceive());
    // A peer can stay listed for a few seconds after it became unreachable;
    // retry queued items periodically, not only when the list changes.
    _outboxTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => _scheduleOutboxFlush(),
    );
    unawaited(_configureRemoteRelay());
    _startRemoteReconnectTimer();
    _scheduleUpdateChecks();
    _showPreviousUpdateOutcome();
  }

  void _scheduleUpdateChecks() {
    if (!AppUpdateService.isSupportedPlatform) return;
    _updateCheckTimer = Timer(
      const Duration(seconds: 8),
      () => unawaited(_autoCheckForUpdate()),
    );
    // Windows often stays in the tray for days; shouldAutoCheck still limits
    // real network checks to once per 24 hours.
    _updatePeriodicTimer = Timer.periodic(
      const Duration(hours: 6),
      (_) => unawaited(_autoCheckForUpdate()),
    );
  }

  Future<void> _autoCheckForUpdate() async {
    if (!mounted || !widget.settings.autoCheckUpdates) return;
    if (!_shouldRunNetworkWork) return;
    final updater = AppUpdateService.instance;
    try {
      if (updater.isBusy || !await updater.shouldAutoCheck()) return;
      final result = await updater.check();
      if (!mounted || result is! UpdateFound) return;
      if (await updater.skippedVersion() == result.update.version) return;
      if (!mounted) return;
      await UpdateFlow.offer(context, result.update, automatic: true);
    } catch (_) {
      // Automatic checks stay silent; the reason is in the diagnostics log.
    }
  }

  void _showPreviousUpdateOutcome() {
    final outcome = AppUpdateService.instance.takePreviousOutcome();
    if (outcome == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          duration: Duration(seconds: outcome.succeeded ? 4 : 12),
          content: Text(
            outcome.succeeded
                ? '已更新到 v${outcome.version}'
                : '自动更新到 v${outcome.version} 没有完成，已保留原来的版本。'
                      '可以在设置里重试，或去发布页手动下载。',
          ),
        ),
      );
    });
  }

  bool get _shouldRunNetworkWork =>
      !Platform.isAndroid ||
      _androidInForeground ||
      _keepsReceivingInBackground;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!Platform.isAndroid) return;
    _lifecycleTransition = _lifecycleTransition.then(
      (_) => _applyAndroidLifecycleState(state),
      onError: (error, stackTrace) => _applyAndroidLifecycleState(state),
    );
  }

  Future<void> _applyAndroidLifecycleState(AppLifecycleState state) async {
    if (!mounted) return;
    switch (state) {
      case AppLifecycleState.resumed:
        await _resumeAndroidNetworkWork();
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        await _pauseAndroidNetworkWork(state);
    }
  }

  Future<void> _pauseAndroidNetworkWork(AppLifecycleState state) async {
    if (!_androidInForeground) return;
    _androidInForeground = false;
    final keepRunning = _keepsReceivingInBackground;
    await _diagnostics.log(
      'app_lifecycle_paused state=${state.name} keep_receiving=$keepRunning',
    );
    // With background receiving on, the foreground service keeps the process
    // alive, so discovery and reconnects simply carry on.
    if (keepRunning) return;
    _stopReconnectTimers();
    await _discovery.pause();
  }

  Future<void> _resumeAndroidNetworkWork() async {
    if (_androidInForeground) return;
    _androidInForeground = true;
    await _diagnostics.log('app_lifecycle_resumed');
    await _discovery.resume();
    await _restorePairing();
    await _connectRemoteRelay();
    _startRemoteReconnectTimer();
  }

  void _startPairingReconnectTimer() {
    if (!_shouldRunNetworkWork || _reconnectTimer != null) return;
    _reconnectTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => unawaited(_tryReconnect()),
    );
  }

  void _startRemoteReconnectTimer() {
    if (!_shouldRunNetworkWork || _remoteReconnectTimer != null) return;
    _remoteReconnectTimer = Timer.periodic(
      const Duration(seconds: 10),
      (_) => unawaited(_connectRemoteRelay()),
    );
  }

  void _stopReconnectTimers() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _remoteReconnectTimer?.cancel();
    _remoteReconnectTimer = null;
  }

  Future<void> _loadRemovedDevices() async {
    final removed = await _removedDeviceStore.loadEntries();
    if (!mounted) return;
    setState(() {
      _removedDeviceIds
        ..clear()
        ..addAll(removed.map((entry) => entry.deviceId));
      _removedDeviceNames
        ..clear()
        ..addEntries(
          removed.map((entry) => MapEntry(entry.deviceId, entry.displayName)),
        );
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
    await _loadTrustedDevices();
    _knownPlatforms.addAll(await _platformStore.load());
    // Show offline peers from history and send whatever is still queued.
    if (mounted) setState(_mergeDevices);
  }

  /// Loads the trusted list and, on the first run with it, trusts every
  /// device the user has already sent something to.
  Future<void> _loadTrustedDevices() async {
    _trustedDeviceIds.addAll(await _trustedStore.load());
    final before = _trustedDeviceIds.length;
    for (final entry in _chatHistory.entries) {
      if (entry.value.any((message) => message.isOutgoing)) {
        _trustedDeviceIds.add(entry.key);
      }
    }
    if (_trustedDeviceIds.length != before) {
      await _trustedStore.save(_trustedDeviceIds);
    }
  }

  Future<void> _trustDevice(String deviceId, {required String reason}) async {
    if (!_trustedDeviceIds.add(deviceId)) return;
    await _trustedStore.save(_trustedDeviceIds);
    await _diagnostics.log(
      'device_trusted peer=${deviceId.substring(0, 8)} reason=$reason',
    );
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
    if (!message.isOutgoing) _notifyIfInBackground(message);
  }

  /// Only when the foreground service really started: it holds the multicast
  /// lock that makes background discovery safe (see DiscoveryService.pause).
  bool get _keepsReceivingInBackground =>
      Platform.isAndroid &&
      widget.settings.androidBackgroundReceive &&
      _backgroundServiceRunning;

  bool _backgroundServiceRunning = false;

  Future<void> _applyBackgroundReceive({bool askPermission = false}) async {
    if (!Platform.isAndroid) return;
    if (widget.settings.androidBackgroundReceive) {
      _backgroundServiceRunning = await BackgroundReceive.start(
        askPermission: askPermission,
      );
      await BackgroundReceive.logStatus();
    } else {
      _backgroundServiceRunning = false;
      await BackgroundReceive.stop();
    }
  }

  /// While the app is in the background (background receiving on), a system
  /// notification is the only sign that something arrived.
  void _notifyIfInBackground(ChatMessage message) {
    if (!_keepsReceivingInBackground || _androidInForeground) return;
    final isText = message.kind == ChatMessageKind.text;
    final preview = isText
        ? (message.text ?? '').trim()
        : (message.fileName ?? '一个文件');
    unawaited(
      BackgroundReceive.notify(
        '收到 ${message.peerName} 的${isText ? '消息' : '文件'}',
        preview.length > 80 ? '${preview.substring(0, 80)}…' : preview,
      ),
    );
  }

  void _mergeDevices() {
    _onlineDevices = mergeDiscoveredDevices(
      localDevices: _localDevices,
      pairedDevices: _pairedDevices,
      remoteDevices: _remoteDevices,
    ).where((device) => !_removedDeviceIds.contains(device.deviceId)).toList();
    _rememberPlatforms(_onlineDevices);
    _devices = withOfflineKnownDevices(
      online: _onlineDevices,
      history: _chatHistory,
      platforms: _knownPlatforms,
      removed: _removedDeviceIds,
    );
    _scheduleOutboxFlush();
  }

  DiscoveredDevice? _onlineDeviceFor(String deviceId) {
    for (final device in _onlineDevices) {
      if (device.deviceId == deviceId) return device;
    }
    return null;
  }

  void _rememberPlatforms(List<DiscoveredDevice> devices) {
    var changed = false;
    for (final device in devices) {
      if (_knownPlatforms[device.deviceId] != device.platform) {
        _knownPlatforms[device.deviceId] = device.platform;
        changed = true;
      }
    }
    if (changed) unawaited(_platformStore.save(_knownPlatforms));
  }

  Map<String, int> get _queuedCounts => {
    for (final entry in _chatHistory.entries)
      if (entry.value.any((message) => message.isQueued))
        entry.key: entry.value.where((message) => message.isQueued).length,
  };

  // ------------------------------------------------------------ offline outbox

  /// Sends queued items to every peer that is online again; also expires
  /// items older than [outboxMaxAge]. Runs on device changes and every 30 s.
  void _scheduleOutboxFlush() {
    final now = DateTime.now();
    for (final entry in _chatHistory.entries) {
      for (final message
          in entry.value.where((item) => isOutboxExpired(item, now)).toList()) {
        _updateChatMessage(
          message.withDelivery(
            ChatDeliveryState.failed,
            note: '对方 7 天没有上线，已取消发送',
          ),
        );
      }
      if (!entry.value.any((message) => message.isQueued)) continue;
      if (_onlineDeviceFor(entry.key) == null) continue;
      unawaited(_flushOutbox(entry.key));
    }
  }

  Future<void> _flushOutbox(String peerId) async {
    if (!_flushingPeers.add(peerId)) return;
    try {
      while (mounted) {
        final device = _onlineDeviceFor(peerId);
        if (device == null) return;
        final queued =
            (_chatHistory[peerId] ?? const <ChatMessage>[])
                .where((message) => message.isQueued)
                .toList()
              ..sort((left, right) => left.sentAt.compareTo(right.sentAt));
        if (queued.isEmpty) return;
        final next = queued.first;
        try {
          if (next.kind == ChatMessageKind.text) {
            await _sendTextNow(device, next.text ?? '');
          } else {
            final filePath = next.filePath;
            if (filePath == null || !await File(filePath).exists()) {
              _updateChatMessage(
                next.withDelivery(
                  ChatDeliveryState.failed,
                  note: '文件已不存在，没有发送',
                ),
              );
              continue;
            }
            await _sendSelectedFiles(
              device,
              [
                (
                  name: next.fileName ?? path.basename(filePath),
                  path: filePath,
                ),
              ],
              (_, _, _) {},
              queueWhenUnreachable: false,
            );
          }
          // The normal send path recorded the delivered copy.
          _removeChatMessage(peerId, next.id);
          await _diagnostics.log(
            'outbox_delivered peer=${peerId.substring(0, 8)} '
            'kind=${next.kind.name}',
          );
        } on TransferException catch (error) {
          if (error.unreachable) {
            await _diagnostics.log(
              'outbox_still_unreachable peer=${peerId.substring(0, 8)}',
            );
            return;
          }
          _updateChatMessage(
            next.withDelivery(ChatDeliveryState.failed, note: error.message),
          );
        } catch (error) {
          _updateChatMessage(
            next.withDelivery(ChatDeliveryState.failed, note: '$error'),
          );
        }
      }
    } finally {
      _flushingPeers.remove(peerId);
      if (mounted) setState(() {});
    }
  }

  int get _queuedTotal => _chatHistory.values
      .expand((messages) => messages)
      .where((message) => message.isQueued)
      .length;

  Future<void> _queueOutgoing(
    DiscoveredDevice device, {
    String? text,
    String? filePath,
    String? fileName,
  }) async {
    if (_queuedTotal >= outboxLimit) {
      throw const TransferException('排队等待发送的内容已经有 $outboxLimit 条，请等对方上线后再发');
    }
    int? fileSize;
    if (filePath != null) {
      final file = File(filePath);
      if (!await file.exists()) {
        throw TransferException('文件不存在或无法读取：$filePath');
      }
      fileSize = await file.length();
    }
    _outboxSequence++;
    _appendChat(
      ChatMessage(
        id: 'queued-${DateTime.now().microsecondsSinceEpoch}-$_outboxSequence',
        peerId: device.deviceId,
        peerName: device.displayName,
        senderId: widget.identity.deviceId,
        senderName: widget.identity.displayName,
        kind: text != null ? ChatMessageKind.text : ChatMessageKind.file,
        sentAt: DateTime.now(),
        isOutgoing: true,
        text: text,
        fileName: fileName,
        filePath: filePath,
        displayLocation: filePath,
        fileSize: fileSize,
        deliveryState: ChatDeliveryState.queued,
      ),
    );
    await _diagnostics.log(
      'outbox_queued peer=${device.deviceId.substring(0, 8)} '
      'kind=${text != null ? 'text' : 'file'}',
    );
    if (mounted) setState(() {});
  }

  Future<void> _queueFiles(
    DiscoveredDevice device,
    Iterable<({String name, String path})> files,
  ) async {
    for (final file in files) {
      await _queueOutgoing(device, filePath: file.path, fileName: file.name);
    }
  }

  void _updateChatMessage(ChatMessage updated) {
    final conversation = _chatHistory[updated.peerId];
    if (conversation == null) return;
    final index = conversation.indexWhere(
      (message) => message.id == updated.id,
    );
    if (index < 0) return;
    conversation[index] = updated;
    _messagesFor(updated.peerId).value = List.unmodifiable(conversation);
    unawaited(_chatStore.save(_chatHistory.values.expand((items) => items)));
  }

  void _removeChatMessage(String peerId, String messageId) {
    final conversation = _chatHistory[peerId];
    if (conversation == null) return;
    conversation.removeWhere((message) => message.id == messageId);
    _messagesFor(peerId).value = List.unmodifiable(conversation);
    unawaited(_chatStore.save(_chatHistory.values.expand((items) => items)));
    if (mounted) setState(() {});
  }

  Future<void> _restoreRemovedDevice(
    String deviceId, {
    required String reason,
  }) async {
    if (!_removedDeviceIds.remove(deviceId)) return;
    _removedDeviceNames.remove(deviceId);
    await _saveRemovedDevices();
    await _diagnostics.log(
      'removed_device_restored reason=$reason peer=${deviceId.substring(0, 8)}',
    );
    if (mounted) setState(_mergeDevices);
  }

  Future<void> _restoreAllRemovedDevices() async {
    if (_removedDeviceIds.isEmpty) return;
    final count = _removedDeviceIds.length;
    _removedDeviceIds.clear();
    _removedDeviceNames.clear();
    await _saveRemovedDevices();
    await _diagnostics.log('removed_devices_restored_all count=$count');
    if (mounted) setState(_mergeDevices);
  }

  Future<void> _saveRemovedDevices() => _removedDeviceStore.saveEntries(
    _removedDeviceIds.map(
      (deviceId) => RemovedDeviceEntry(
        deviceId: deviceId,
        displayName: _removedDeviceNames[deviceId] ?? '',
      ),
    ),
  );

  List<RemovedDeviceEntry> _removedDeviceEntries() {
    final entries = _removedDeviceIds
        .map(
          (deviceId) => RemovedDeviceEntry(
            deviceId: deviceId,
            displayName: _removedDeviceNames[deviceId] ?? '',
          ),
        )
        .toList();
    entries.sort((left, right) => left.label.compareTo(right.label));
    return entries;
  }

  Future<void> _configureRemoteRelay() async {
    if (!_shouldRunNetworkWork) return;
    await _remoteRelay.disconnect();
    if (!mounted) return;
    setState(() {
      _remoteDevices = const [];
      _remoteError = null;
      _mergeDevices();
    });
    await _connectRemoteRelay();
  }

  Future<void> _connectRemoteRelay() async {
    final settings = widget.remoteSettings;
    if (!_shouldRunNetworkWork ||
        !settings.enabled ||
        !settings.isConfigured ||
        _remoteRelay.status != RemoteRelayStatus.disconnected) {
      return;
    }
    final relayUri = settings.relayUri;
    if (relayUri == null) return;
    try {
      await _diagnostics.log('remote_relay_connecting host=${relayUri.host}');
      await _remoteRelay.connect(
        relayUri: relayUri,
        accessToken: settings.accessToken,
        deviceId: widget.identity.deviceId,
        displayName: widget.identity.displayName,
        platform: widget.identity.platform,
      );
      await _diagnostics.log('remote_relay_connected host=${relayUri.host}');
      if (mounted) setState(() => _remoteError = null);
    } catch (error, stackTrace) {
      await _diagnostics.log(
        'remote_relay_connect_failed',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted) setState(() => _remoteError = '公网 VPS 暂时无法连接，正在自动重试');
    }
  }

  Future<void> _handleRemoteEnvelope(EncryptedRemoteEnvelope envelope) async {
    late final RemotePayload payload;
    try {
      payload = await _remoteCrypto.decrypt(
        envelope: envelope,
        familySecret: widget.remoteSettings.familySecret,
      );
    } catch (error, stackTrace) {
      await _diagnostics.log(
        'remote_decrypt_failed',
        error: error,
        stackTrace: stackTrace,
      );
      await _acknowledgeRemoteEnvelope(
        envelope.messageId,
        failureCode: 'decrypt_failed',
      );
      _showRemoteReceiveError('收到一条无法解密的公网消息，请核对所有设备的家庭加密口令');
      return;
    }
    final shouldLogEnvelope = payload.kind != RemotePayloadKind.fileChunk;
    if (shouldLogEnvelope) {
      await _diagnostics.log(
        'remote_envelope_received '
        'message=${envelope.messageId.substring(0, 8)} '
        'sender=${envelope.senderId.substring(0, 8)} '
        'bytes=${envelope.cipherText.length} '
        'kind=${payload.kind.name}',
      );
    }
    final peerName = _remotePeerName(envelope.senderId);
    try {
      switch (payload.kind) {
        case RemotePayloadKind.text:
        case RemotePayloadKind.link:
          _appendChat(
            ChatMessage(
              id: envelope.messageId,
              peerId: envelope.senderId,
              peerName: peerName,
              senderId: envelope.senderId,
              senderName: peerName,
              kind: ChatMessageKind.text,
              sentAt: envelope.sentAt,
              isOutgoing: false,
              text: payload.text,
            ),
          );
        case RemotePayloadKind.fileStart:
          await _startRemoteFile(envelope.senderId, peerName, payload);
        case RemotePayloadKind.fileChunk:
          await _writeRemoteFileChunk(envelope.senderId, peerName, payload);
        case RemotePayloadKind.fileEnd:
          await _completeRemoteFile(envelope.senderId, peerName, payload);
        case RemotePayloadKind.cancel:
          await _handleRemoteCancel(payload.transferId!);
      }
    } catch (error, stackTrace) {
      await _diagnostics.log(
        'remote_processing_failed kind=${payload.kind.name}',
        error: error,
        stackTrace: stackTrace,
      );
      await _acknowledgeRemoteEnvelope(
        envelope.messageId,
        failureCode: 'processing_failed',
      );
      _showRemoteReceiveError('公网消息已经收到，但保存或处理失败，请导出诊断日志');
      return;
    }
    if (shouldLogEnvelope) {
      await _diagnostics.log(
        'remote_envelope_processed '
        'message=${envelope.messageId.substring(0, 8)} '
        'kind=${payload.kind.name}',
      );
    }
    await _acknowledgeRemoteEnvelope(envelope.messageId);
  }

  Future<void> _handleRemoteCancel(String transferId) async {
    final outgoing = _remoteOutgoingCancellations[transferId];
    if (outgoing != null) {
      outgoing.cancel();
      await _diagnostics.log(
        'remote_file_cancelled_by_receiver transfer=${transferId.substring(0, 8)}',
      );
      return;
    }
    await _cancelRemoteFile(transferId);
  }

  Future<void> _acknowledgeRemoteEnvelope(
    String messageId, {
    String? failureCode,
  }) async {
    try {
      await _remoteRelay.acknowledgeEnvelope(
        messageId,
        failureCode: failureCode,
      );
    } catch (error, stackTrace) {
      await _diagnostics.log(
        'remote_receipt_failed message=${messageId.substring(0, 8)}',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  void _showRemoteReceiveError(String message) {
    if (!mounted) return;
    setState(() => _remoteError = message);
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  String _remotePeerName(String deviceId) {
    for (final device in _remoteDevices) {
      if (device.deviceId == deviceId) return device.displayName;
    }
    return '远程设备 ${deviceId.substring(0, 4).toUpperCase()}';
  }

  Future<void> _startRemoteFile(
    String senderId,
    String senderName,
    RemotePayload payload,
  ) async {
    final transferId = payload.transferId!;
    await _cancelRemoteFile(transferId);
    try {
      final incoming = await _RemoteIncomingFile.create(
        transferId: transferId,
        senderId: senderId,
        senderName: senderName,
        fileName: payload.fileName!,
        totalBytes: payload.totalBytes!,
      );
      _remoteIncomingFiles[transferId] = incoming;
      _refreshRemoteIncomingTimeout(transferId);
      _receiveProgress(
        TransferProgressUpdate(
          transferId: transferId,
          peerId: senderId,
          peerName: senderName,
          fileName: incoming.fileName,
          transferredBytes: 0,
          totalBytes: incoming.totalBytes,
        ),
      );
    } catch (error, stackTrace) {
      await _diagnostics.log(
        'remote_file_prepare_failed',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  Future<void> _writeRemoteFileChunk(
    String senderId,
    String senderName,
    RemotePayload payload,
  ) async {
    final transferId = payload.transferId!;
    if (_cancelledRemoteIncomingTransfers.contains(transferId)) return;
    final incoming = _remoteIncomingFiles[transferId];
    if (incoming == null ||
        incoming.senderId != senderId ||
        payload.chunkIndex != incoming.nextChunkIndex) {
      await _cancelRemoteFile(transferId);
      throw const TransferException('远程文件分块顺序无效');
    }
    final bytes = payload.bytes!;
    if (incoming.receivedBytes + bytes.length > incoming.totalBytes) {
      await _cancelRemoteFile(transferId);
      throw const TransferException('远程文件大小超过声明值');
    }
    await incoming.add(bytes);
    _refreshRemoteIncomingTimeout(transferId);
    if (incoming.shouldReportProgress) {
      _receiveProgress(
        TransferProgressUpdate(
          transferId: transferId,
          peerId: senderId,
          peerName: senderName,
          fileName: incoming.fileName,
          transferredBytes: incoming.receivedBytes,
          totalBytes: incoming.totalBytes,
        ),
      );
    }
  }

  Future<void> _completeRemoteFile(
    String senderId,
    String senderName,
    RemotePayload payload,
  ) async {
    final transferId = payload.transferId!;
    if (_cancelledRemoteIncomingTransfers.remove(transferId)) return;
    _remoteIncomingTimeouts.remove(transferId)?.cancel();
    final incoming = _remoteIncomingFiles.remove(transferId);
    if (incoming == null ||
        incoming.senderId != senderId ||
        incoming.receivedBytes != incoming.totalBytes) {
      await incoming?.abort();
      _incomingProgressFor(senderId).value = null;
      throw const TransferException('远程文件不完整');
    }
    try {
      final file = await incoming.complete();
      await _finalizeCompletedTransfer(
        CompletedTransfer(
          transferId: transferId,
          senderId: senderId,
          senderName: senderName,
          file: file,
          fileSize: incoming.totalBytes,
        ),
      );
    } catch (error, stackTrace) {
      await incoming.abort();
      await _diagnostics.log(
        'remote_file_finalize_failed',
        error: error,
        stackTrace: stackTrace,
      );
      _incomingProgressFor(senderId).value = null;
      rethrow;
    }
  }

  Future<void> _cancelRemoteFile(String transferId) async {
    _remoteIncomingTimeouts.remove(transferId)?.cancel();
    final incoming = _remoteIncomingFiles.remove(transferId);
    if (incoming == null) return;
    await incoming.abort();
    _receiveProgress(
      TransferProgressUpdate(
        transferId: transferId,
        peerId: incoming.senderId,
        peerName: incoming.senderName,
        fileName: incoming.fileName,
        transferredBytes: incoming.receivedBytes,
        totalBytes: incoming.totalBytes,
        cancelled: true,
      ),
    );
  }

  void _refreshRemoteIncomingTimeout(String transferId) {
    _remoteIncomingTimeouts.remove(transferId)?.cancel();
    _remoteIncomingTimeouts[transferId] = Timer(
      const Duration(seconds: 45),
      () => unawaited(_expireRemoteFile(transferId)),
    );
  }

  Future<void> _expireRemoteFile(String transferId) async {
    if (!_remoteIncomingFiles.containsKey(transferId)) return;
    await _diagnostics.log(
      'remote_file_receive_timeout transfer=${transferId.substring(0, 8)}',
    );
    await _cancelRemoteFile(transferId);
    _showRemoteReceiveError('公网文件超过 45 秒没有收到新数据，已停止接收并清理临时文件');
  }

  Future<void> _cancelIncomingRemoteTransfer(
    String senderId,
    String transferId,
  ) async {
    final incoming = _remoteIncomingFiles[transferId];
    if (incoming == null || incoming.senderId != senderId) return;
    _cancelledRemoteIncomingTransfers.add(transferId);
    Timer(
      const Duration(minutes: 5),
      () => _cancelledRemoteIncomingTransfers.remove(transferId),
    );
    await _cancelRemoteFile(transferId);
    try {
      await _sendRemotePayload(
        senderId,
        RemotePayload.cancel(transferId: transferId),
      ).timeout(const Duration(seconds: 5));
    } on Object {
      // Local cleanup is authoritative; the sender will also stop on timeout or
      // delivery failure if the cancellation notice cannot be delivered.
    }
    await _diagnostics.log(
      'remote_file_cancelled_by_receiver_ui '
      'transfer=${transferId.substring(0, 8)}',
    );
  }

  Future<void> _handleRemoteDisconnect() async {
    for (final cancellation in _remoteOutgoingCancellations.values.toList()) {
      cancellation.cancel();
    }
    for (final transferId in _remoteIncomingFiles.keys.toList()) {
      await _cancelRemoteFile(transferId);
    }
  }

  void _showCompletedTransfer(CompletedTransfer transfer) {
    unawaited(_finalizeCompletedTransfer(transfer));
  }

  /// Files the app owns (pasted pictures, forwarded copies, voice
  /// messages): deleting the message or clearing the chat removes them.
  bool _isAppCacheFile(String filePath) =>
      OutgoingCache.instance.contains(filePath) ||
      VoiceStore.instance.contains(filePath);

  /// Voice messages are kept in the app's voice folder (like WeChat), not
  /// in the download folder, so they can be played and transcribed.
  Future<void> _finalizeVoiceMessage(CompletedTransfer transfer) async {
    final stored = await VoiceStore.instance.adoptReceived(transfer.file);
    // Senders before v1.11.2 sent quiet recordings as they were.
    var gain = 0.0;
    try {
      gain = await normalizeVoiceFile(stored);
    } catch (_) {}
    unawaited(
      _diagnostics.log(
        'voice_received bytes=${transfer.fileSize} '
        'gain_db=${gain.toStringAsFixed(1)}',
      ),
    );
    if (!mounted) return;
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
        filePath: stored.path,
        displayLocation: '语音消息',
        fileSize: transfer.fileSize,
        isCache: true,
      ),
    );
  }

  Future<void> _setTranscript(ChatMessage message, String? text) async {
    final current = _chatHistory[message.peerId]
        ?.where((item) => item.id == message.id)
        .firstOrNull;
    if (current == null) return;
    _updateChatMessage(current.withTranscript(text));
  }

  Future<void> _finalizeCompletedTransfer(CompletedTransfer transfer) async {
    if (isVoiceFileName(transfer.file.path)) {
      await _finalizeVoiceMessage(transfer);
      return;
    }
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
    if (!mounted || !_shouldRunNetworkWork) return;
    await _tryReconnect();
    _startPairingReconnectTimer();
  }

  Future<void> _tryReconnect() async {
    final endpoint = _savedPairing;
    if (!_shouldRunNetworkWork ||
        endpoint == null ||
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
      device = await _pairingRelay.connect(endpoint, requestRestore: true);
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
    await _restoreRemovedDevice(device.deviceId, reason: 'manual_pairing');
    await _trustDevice(device.deviceId, reason: 'paired');
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
    if (oldWidget.remoteSettings != widget.remoteSettings ||
        oldWidget.identity != widget.identity) {
      unawaited(_configureRemoteRelay());
    }
    if (oldWidget.settings.androidBackgroundReceive !=
        widget.settings.androidBackgroundReceive) {
      unawaited(_applyBackgroundReceive(askPermission: true));
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _outboxTimer?.cancel();
    _updateCheckTimer?.cancel();
    _updatePeriodicTimer?.cancel();
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
    _restoreRequestSubscription?.cancel();
    _remotePeersSubscription?.cancel();
    _remoteEnvelopeSubscription?.cancel();
    _remoteStatusSubscription?.cancel();
    _remoteErrorSubscription?.cancel();
    _stopReconnectTimers();
    _discovery.dispose();
    _transferServer.dispose();
    _receivedFileService.setSharedFilesListener(null);
    unawaited(_remoteRelay.dispose());
    unawaited(_remoteCrypto.dispose());
    for (final cancellation in _remoteOutgoingCancellations.values) {
      cancellation.cancel();
    }
    _remoteOutgoingCancellations.clear();
    for (final timer in _remoteIncomingTimeouts.values) {
      timer.cancel();
    }
    _remoteIncomingTimeouts.clear();
    for (final incoming in _remoteIncomingFiles.values) {
      unawaited(incoming.abort());
    }
    _remoteIncomingFiles.clear();
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

    final automatic = shouldAutoAccept(
      widget.settings.autoAcceptMode,
      trusted: _trustedDeviceIds.contains(request.senderId),
    );
    if (automatic) {
      unawaited(
        _diagnostics.log(
          'incoming_transfer_auto_accepted '
          'mode=${widget.settings.autoAcceptMode.name} '
          'bytes=${request.fileSize}',
        ),
      );
      await _acceptIncomingTransfer(request);
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
    await _trustDevice(request.senderId, reason: 'accepted_file');
    await _acceptIncomingTransfer(request);
  }

  Future<void> _acceptIncomingTransfer(IncomingTransferRequest request) async {
    try {
      final destination = await _receiveDirectory();
      await _restoreRemovedDevice(
        request.senderId,
        reason: 'accepted_incoming_transfer',
      );
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
    DiscoveredDevice requested,
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
    await _trustDevice(requested.deviceId, reason: 'sent_file');
    final device = _onlineDeviceFor(requested.deviceId);
    if (device == null) {
      await _queueFiles(requested, selectedFiles);
      return;
    }
    await _sendSelectedFiles(
      device,
      selectedFiles,
      onProgress,
      cancellation: cancellation,
      queueWhenUnreachable: true,
    );
  }

  /// [queueWhenUnreachable]: a file that fails before any byte left (peer
  /// gone) is queued together with the ones after it instead of failing.
  Future<void> _sendSelectedFiles(
    DiscoveredDevice device,
    List<({String name, String path})> selectedFiles,
    void Function(String fileName, int sentBytes, int totalBytes) onProgress, {
    TransferCancellationToken? cancellation,
    required bool queueWhenUnreachable,
  }) async {
    if (device.isRemote) {
      await _sendRemoteFiles(
        device,
        selectedFiles,
        onProgress,
        cancellation: cancellation,
      );
      return;
    }

    for (var index = 0; index < selectedFiles.length; index++) {
      final selectedFile = selectedFiles[index];
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
      final preferDirect = directDevice != null;
      var sentBytes = 0;
      await _diagnostics.log(
        'send_start bytes=$fileSize route=${preferDirect ? 'direct' : 'paired'}',
      );
      try {
        if (preferDirect) {
          try {
            result = await _transferClient.sendFile(
              receiver: directDevice,
              senderId: widget.identity.deviceId,
              senderName: widget.identity.displayName,
              file: file,
              onProgress: (sent, total) {
                sentBytes = sent;
                onProgress(selectedFile.name, sent, total);
              },
              cancellation: cancellation,
            );
          } on TransferException catch (error) {
            if (sentBytes != 0 || !usePaired) rethrow;
            await _diagnostics.log(
              'direct_send_unavailable_fallback_to_paired',
              error: error,
            );
            result = await _pairingRelay.sendFile(
              receiverId: device.deviceId,
              file: file,
              onProgress: (sent, total) {
                sentBytes = sent;
                onProgress(selectedFile.name, sent, total);
              },
              cancellation: cancellation,
            );
          }
        } else if (usePaired) {
          result = await _pairingRelay.sendFile(
            receiverId: device.deviceId,
            file: file,
            onProgress: (sent, total) {
              sentBytes = sent;
              onProgress(selectedFile.name, sent, total);
            },
            cancellation: cancellation,
          );
        } else {
          throw const TransferException('设备连接已经断开，请等待重新连接', unreachable: true);
        }
      } catch (error, stackTrace) {
        await _diagnostics.log(
          'send_failed route=${preferDirect ? 'direct' : 'paired'}',
          error: error,
          stackTrace: stackTrace,
        );
        if (queueWhenUnreachable &&
            error is TransferException &&
            error.unreachable &&
            sentBytes == 0) {
          await _queueFiles(device, selectedFiles.sublist(index));
          return;
        }
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
          isCache: !isSharedCache && _isAppCacheFile(file.path),
        ),
      );
      if (_sharedCachePaths.remove(file.path) && await file.exists()) {
        await file.delete();
      }
    }
  }

  /// Sends now when the peer is reachable; otherwise queues the text until it
  /// is seen again (see [_flushOutbox]).
  Future<void> _sendText(DiscoveredDevice requested, String text) async {
    await _trustDevice(requested.deviceId, reason: 'sent_text');
    final device = _onlineDeviceFor(requested.deviceId);
    if (device == null) {
      await _queueOutgoing(requested, text: text.trim());
      return;
    }
    try {
      await _sendTextNow(device, text);
    } on TransferException catch (error) {
      if (!error.unreachable) rethrow;
      await _queueOutgoing(requested, text: text.trim());
    }
  }

  Future<void> _sendTextNow(DiscoveredDevice device, String text) async {
    if (device.isRemote) {
      final trimmed = text.trim();
      final uri = Uri.tryParse(trimmed);
      final isLink =
          uri != null &&
          (uri.scheme == 'http' || uri.scheme == 'https') &&
          uri.host.isNotEmpty;
      final messageId = await _sendRemotePayload(
        device.deviceId,
        isLink ? RemotePayload.link(trimmed) : RemotePayload.text(trimmed),
      );
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
          text: trimmed,
        ),
      );
      return;
    }
    late String messageId;
    final directDevice = _directDeviceFor(device.deviceId);
    if (directDevice != null) {
      try {
        messageId = await _transferClient.sendText(
          receiver: directDevice,
          senderId: widget.identity.deviceId,
          senderName: widget.identity.displayName,
          text: text,
        );
      } on TransferException {
        if (!_pairingRelay.hasSession(device.deviceId)) rethrow;
        messageId = await _pairingRelay.sendText(
          receiverId: device.deviceId,
          text: text,
        );
      }
    } else if (_pairingRelay.hasSession(device.deviceId)) {
      messageId = await _pairingRelay.sendText(
        receiverId: device.deviceId,
        text: text,
      );
    } else {
      throw const TransferException('设备连接已经断开，请等待重新连接', unreachable: true);
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

  Future<String> _sendRemotePayload(
    String recipientId,
    RemotePayload payload,
  ) async {
    final queued = await _queueRemotePayload(recipientId, payload);
    final outcome = await _RemoteDeliveryOutcome.capture(queued.delivery);
    outcome.throwIfFailed();
    return queued.messageId;
  }

  Future<_RemoteQueuedPayload> _queueRemotePayload(
    String recipientId,
    RemotePayload payload, {
    TransferCancellationToken? cancellation,
  }) async {
    cancellation?.throwIfCancelled();
    if (_remoteRelay.status != RemoteRelayStatus.connected) {
      throw const TransferException('公网 VPS 尚未连接，请稍后重试');
    }
    final envelope = await _remoteCrypto.encrypt(
      payload: payload,
      familySecret: widget.remoteSettings.familySecret,
      senderId: widget.identity.deviceId,
      recipientId: recipientId,
    );
    cancellation?.throwIfCancelled();
    return _RemoteQueuedPayload(
      messageId: envelope.messageId,
      delivery: _deliverRemoteEnvelope(envelope, payload),
    );
  }

  Future<void> _deliverRemoteEnvelope(
    EncryptedRemoteEnvelope envelope,
    RemotePayload payload,
  ) async {
    try {
      await _remoteRelay.sendEnvelope(envelope);
    } on RemoteRelayException catch (error) {
      throw TransferException(_remoteDeliveryErrorText(error.code));
    }
    if (payload.kind != RemotePayloadKind.fileChunk) {
      await _diagnostics.log(
        'remote_delivery_confirmed '
        'message=${envelope.messageId.substring(0, 8)} '
        'recipient=${envelope.recipientId.substring(0, 8)} '
        'kind=${payload.kind.name}',
      );
    }
  }

  Future<void> _sendRemoteFiles(
    DiscoveredDevice device,
    List<({String name, String path})> selectedFiles,
    void Function(String fileName, int sentBytes, int totalBytes) onProgress, {
    TransferCancellationToken? cancellation,
  }) async {
    for (final selectedFile in selectedFiles) {
      cancellation?.throwIfCancelled();
      final mimeType = _remoteFileMimeType(selectedFile.name);
      final file = File(selectedFile.path);
      if (!await file.exists()) {
        throw TransferException('文件不存在或无法读取：${selectedFile.path}');
      }
      final fileSize = await file.length();
      if (fileSize < 1 || fileSize > RemotePayload.maxRemoteFileBytes) {
        throw const TransferException('公网中转单个文件最大支持 200 MiB，请改用局域网发送');
      }
      final transferId = randomRemoteId();
      final activeCancellation = cancellation ?? TransferCancellationToken();
      var remoteStarted = false;
      var completed = false;
      Future<void>? cancelDelivery;
      Future<void> notifyCancel() {
        return cancelDelivery ??= _sendRemotePayload(
          device.deviceId,
          RemotePayload.cancel(transferId: transferId),
        ).then((_) {}).catchError((Object _) {});
      }

      _remoteOutgoingCancellations[transferId] = activeCancellation;
      final removeCancellationListener = activeCancellation.addListener(() {
        if (remoteStarted) unawaited(notifyCancel());
      });
      RandomAccessFile? source;
      try {
        onProgress(selectedFile.name, 0, fileSize);
        await _diagnostics.log(
          'remote_file_send_start '
          'transfer=${transferId.substring(0, 8)} bytes=$fileSize',
        );
        final start = await _queueRemotePayload(
          device.deviceId,
          RemotePayload.fileStart(
            transferId: transferId,
            fileName: selectedFile.name,
            mimeType: mimeType,
            totalBytes: fileSize,
          ),
          cancellation: activeCancellation,
        );
        remoteStarted = true;
        final startOutcome = await _waitForRemoteDelivery(
          _RemoteDeliveryOutcome.capture(start.delivery),
          activeCancellation,
        );
        startOutcome.throwIfFailed();
        source = await file.open();
        var queuedBytes = 0;
        var confirmedBytes = 0;
        var chunkIndex = 0;
        var lastProgressAt = DateTime.now();
        final pending = <_RemoteChunkDelivery>[];

        Future<void> confirmOldestChunk() async {
          final oldest = pending.removeAt(0);
          final outcome = await _waitForRemoteDelivery(
            oldest.outcome,
            activeCancellation,
          );
          outcome.throwIfFailed();
          confirmedBytes = oldest.endBytes;
          final now = DateTime.now();
          if (confirmedBytes == fileSize ||
              now.difference(lastProgressAt) >=
                  const Duration(milliseconds: 100)) {
            lastProgressAt = now;
            onProgress(selectedFile.name, confirmedBytes, fileSize);
          }
        }

        while (queuedBytes < fileSize) {
          activeCancellation.throwIfCancelled();
          final bytes = await source.read(RemotePayload.remoteFileChunkBytes);
          if (bytes.isEmpty) {
            throw const TransferException('读取文件时意外结束');
          }
          final queued = await _queueRemotePayload(
            device.deviceId,
            RemotePayload.fileChunk(
              transferId: transferId,
              chunkIndex: chunkIndex,
              bytes: bytes,
            ),
            cancellation: activeCancellation,
          );
          queuedBytes += bytes.length;
          chunkIndex += 1;
          pending.add(
            _RemoteChunkDelivery(
              endBytes: queuedBytes,
              outcome: _RemoteDeliveryOutcome.capture(queued.delivery),
            ),
          );
          if (pending.length >= remoteFileDeliveryWindow) {
            await confirmOldestChunk();
          }
        }
        while (pending.isNotEmpty) {
          await confirmOldestChunk();
        }
        activeCancellation.throwIfCancelled();
        final end = await _queueRemotePayload(
          device.deviceId,
          RemotePayload.fileEnd(transferId: transferId),
          cancellation: activeCancellation,
        );
        final endOutcome = await _waitForRemoteDelivery(
          _RemoteDeliveryOutcome.capture(end.delivery),
          activeCancellation,
        );
        endOutcome.throwIfFailed();
        completed = true;
        onProgress(selectedFile.name, fileSize, fileSize);
        unawaited(
          _diagnostics.log(
            'remote_file_send_complete '
            'transfer=${transferId.substring(0, 8)} bytes=$fileSize',
          ),
        );
        final isSharedCache = _sharedCachePaths.contains(file.path);
        _appendChat(
          ChatMessage(
            id: transferId,
            peerId: device.deviceId,
            peerName: device.displayName,
            senderId: widget.identity.deviceId,
            senderName: widget.identity.displayName,
            kind: ChatMessageKind.file,
            sentAt: DateTime.now(),
            isOutgoing: true,
            fileName: selectedFile.name,
            filePath: isSharedCache ? null : file.path,
            displayLocation: isSharedCache ? '系统共享缓存已自动清理' : file.path,
            fileSize: fileSize,
            isCache: !isSharedCache && _isAppCacheFile(file.path),
          ),
        );
        if (_sharedCachePaths.remove(file.path) && await file.exists()) {
          await file.delete();
        }
      } finally {
        removeCancellationListener();
        await source?.close();
        if (remoteStarted && !completed) {
          await notifyCancel().timeout(
            const Duration(seconds: 5),
            onTimeout: () {},
          );
        }
        if (identical(
          _remoteOutgoingCancellations[transferId],
          activeCancellation,
        )) {
          _remoteOutgoingCancellations.remove(transferId);
        }
      }
    }
  }

  Future<_RemoteDeliveryOutcome> _waitForRemoteDelivery(
    Future<_RemoteDeliveryOutcome> delivery,
    TransferCancellationToken cancellation,
  ) async {
    if (cancellation.isCancelled) {
      throw const TransferCancelledException();
    }
    final cancelled = Completer<_RemoteDeliveryOutcome>();
    final removeCancellationListener = cancellation.addListener(() {
      if (!cancelled.isCompleted) {
        cancelled.complete(const _RemoteDeliveryOutcome.cancelled());
      }
    });
    final _RemoteDeliveryOutcome outcome;
    try {
      outcome = await Future.any<_RemoteDeliveryOutcome>([
        delivery,
        cancelled.future,
      ]);
    } finally {
      removeCancellationListener();
    }
    if (outcome.cancelled) throw const TransferCancelledException();
    return outcome;
  }

  DiscoveredDevice? _directDeviceFor(String deviceId) {
    for (final device in _localDevices) {
      if (device.deviceId == deviceId) return device;
    }
    return null;
  }

  /// [forwardFiles]: files forwarded from another conversation, sent as soon
  /// as this one opens so its progress and stop button are visible.
  Future<void> _openChat(
    DiscoveredDevice device, {
    List<String> forwardFiles = const [],
  }) async {
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
          initialFilePaths: [...sharedFiles, ...forwardFiles],
          onClearConversation: (deleteCache) =>
              _clearConversation(device.deviceId, deleteCache: deleteCache),
          onRemoveDevice: () => _removeDevice(device),
          onDiscardUndelivered: (messageId) =>
              _removeChatMessage(device.deviceId, messageId),
          onDeleteMessage: (message) => _deleteChatMessage(message),
          onTranscribed: _setTranscript,
          onForward: _forwardMessage,
          forwardTargets: () => _devices,
          onCancelIncomingTransfer: device.isRemote
              ? (transferId) =>
                    _cancelIncomingRemoteTransfer(device.deviceId, transferId)
              : null,
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

  /// Long-press 删除. A cache file (pasted picture, forwarded copy, Android
  /// fallback copy) goes with the message unless another message uses it.
  Future<void> _deleteChatMessage(ChatMessage message) async {
    _removeChatMessage(message.peerId, message.id);
    await _diagnostics.log('chat_message_deleted kind=${message.kind.name}');
    final filePath = message.filePath;
    if (!message.isCache || filePath == null || _isFileReferenced(filePath)) {
      return;
    }
    final file = File(filePath);
    if (await file.exists()) await file.delete();
  }

  bool _isFileReferenced(String filePath) => _chatHistory.values.any(
    (messages) => messages.any((message) => message.filePath == filePath),
  );

  /// Long-press 转发. Text goes out in the background (queued if the target
  /// is offline). A file opens the target conversation and is sent there, so
  /// its progress and stop button are visible.
  Future<String?> _forwardMessage(
    ChatMessage message,
    DiscoveredDevice target,
  ) async {
    await _diagnostics.log(
      'chat_forward kind=${message.kind.name} '
      'route=${target.connectionMode.name}',
    );
    if (message.kind == ChatMessageKind.text) {
      final text = parseQuotedText(message.text ?? '').reply.trim();
      if (text.isEmpty) throw const TransferException('这条消息没有可以转发的文字');
      await _sendText(target, text);
      return _onlineDeviceFor(target.deviceId) == null
          ? '${target.displayName} 不在线，上线后自动发送'
          : '已转发给 ${target.displayName}';
    }
    final filePath = await _forwardableFile(message);
    if (!mounted) return null;
    Navigator.of(context).popUntil((route) => route.isFirst);
    unawaited(_openChat(target, forwardFiles: [filePath]));
    return null;
  }

  /// 图片查看 window → 发送: the edited picture goes into that conversation
  /// the same way as a forward (progress, offline queue and errors as usual).
  Future<void> _sendFromViewer(String peerId, String filePath) async {
    final target = _devices
        .where((device) => device.deviceId == peerId)
        .firstOrNull;
    await _diagnostics.log('image_viewer_send found=${target != null}');
    if (target == null || !mounted) return;
    Navigator.of(context).popUntil((route) => route.isFirst);
    unawaited(_openChat(target, forwardFiles: [filePath]));
  }

  /// A readable local copy of a file message. Android files saved through
  /// 系统下载 only have a content URI and are copied to the outgoing cache.
  Future<String> _forwardableFile(ChatMessage message) async {
    final filePath = message.filePath;
    if (filePath != null && await File(filePath).exists()) return filePath;
    final contentUri = message.contentUri;
    if (Platform.isAndroid && contentUri != null) {
      return PlatformClipboardFiles.instance.copyContentUriToCache(contentUri);
    }
    throw const TransferException('文件已被移动或删除，无法转发');
  }

  Future<void> _clearConversation(
    String deviceId, {
    required bool deleteCache,
  }) async {
    final messages = _chatHistory.remove(deviceId) ?? const <ChatMessage>[];
    if (deleteCache) {
      for (final message in messages.where((message) => message.isCache)) {
        final filePath = message.filePath;
        // The same pasted picture may have been sent to another device too.
        if (filePath == null || _isFileReferenced(filePath)) continue;
        final file = File(filePath);
        if (await file.exists()) await file.delete();
      }
    }
    _messagesFor(deviceId).value = const [];
    await _chatStore.save(_chatHistory.values.expand((items) => items));
    // An offline peer with no history left drops out of the list.
    if (mounted) setState(_mergeDevices);
  }

  Future<void> _removeDevice(DiscoveredDevice device) async {
    await _clearConversation(device.deviceId, deleteCache: true);
    if (_pairingRelay.hasSession(device.deviceId)) {
      await _pairingRelay.disconnect(device.deviceId);
      await _pairingStore.clearEndpoint();
      _savedPairing = null;
    }
    _removedDeviceIds.add(device.deviceId);
    _removedDeviceNames[device.deviceId] = device.displayName;
    await _saveRemovedDevices();
    if (_trustedDeviceIds.remove(device.deviceId)) {
      await _trustedStore.save(_trustedDeviceIds);
    }
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
          initialRemoteSettings: widget.remoteSettings,
          saveRemoteSettings: widget.saveRemoteSettings,
          removedDevices: _removedDeviceEntries(),
          restoreRemovedDevice: (deviceId) =>
              _restoreRemovedDevice(deviceId, reason: 'settings'),
          restoreAllRemovedDevices: _restoreAllRemovedDevices,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return DeviceHomeView(
      identity: widget.identity,
      devices: _devices,
      onRename: _renameDevice,
      onOpenDevice: _openChat,
      onPair: _openPairingPage,
      onRefresh: _discovery.announce,
      onOpenSettings: _openSettings,
      remoteEnabled: widget.remoteSettings.enabled,
      remoteConnected: _remoteStatus == RemoteRelayStatus.connected,
      statusError: _statusError,
      onDismissStatusError: () => setState(() => _statusError = null),
      remoteError: _remoteError,
      onRetryRemote: _connectRemoteRelay,
      onDismissRemoteError: () => setState(() => _remoteError = null),
      pendingSharedFileCount: _pendingSharedFiles.length,
      onDiscardSharedFiles: _discardSharedFiles,
      queuedCounts: _queuedCounts,
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

// Sixteen 256 KiB chunks keep 4 MiB of source data in flight. This is large
// enough to cover common cross-region latency and packet-loss recovery without
// allowing a 200 MiB transfer to accumulate unbounded WebSocket buffers.
const remoteFileDeliveryWindow = 16;

class _RemoteQueuedPayload {
  const _RemoteQueuedPayload({required this.messageId, required this.delivery});

  final String messageId;
  final Future<void> delivery;
}

class _RemoteChunkDelivery {
  const _RemoteChunkDelivery({required this.endBytes, required this.outcome});

  final int endBytes;
  final Future<_RemoteDeliveryOutcome> outcome;
}

class _RemoteDeliveryOutcome {
  const _RemoteDeliveryOutcome._({
    this.error,
    this.stackTrace,
    this.cancelled = false,
  });

  const _RemoteDeliveryOutcome.cancelled() : this._(cancelled: true);

  final Object? error;
  final StackTrace? stackTrace;
  final bool cancelled;

  static Future<_RemoteDeliveryOutcome> capture(Future<void> delivery) async {
    try {
      await delivery;
      return const _RemoteDeliveryOutcome._();
    } catch (error, stackTrace) {
      return _RemoteDeliveryOutcome._(error: error, stackTrace: stackTrace);
    }
  }

  void throwIfFailed() {
    final failure = error;
    if (failure == null) return;
    Error.throwWithStackTrace(failure, stackTrace ?? StackTrace.current);
  }
}

String _remoteFileMimeType(String fileName) {
  return switch (path.extension(fileName).toLowerCase()) {
    '.jpg' || '.jpeg' => 'image/jpeg',
    '.png' => 'image/png',
    '.gif' => 'image/gif',
    '.webp' => 'image/webp',
    '.bmp' => 'image/bmp',
    '.mp4' => 'video/mp4',
    '.mkv' => 'video/x-matroska',
    '.mov' => 'video/quicktime',
    '.avi' => 'video/x-msvideo',
    '.mp3' => 'audio/mpeg',
    '.wav' => 'audio/wav',
    '.pdf' => 'application/pdf',
    '.apk' => 'application/vnd.android.package-archive',
    '.zip' => 'application/zip',
    '.7z' => 'application/x-7z-compressed',
    '.rar' => 'application/vnd.rar',
    '.txt' => 'text/plain',
    _ => 'application/octet-stream',
  };
}

String _remoteErrorText(String code) => switch (code) {
  'recipient_offline' => '对方远程设备已经离线',
  'protocol_mismatch' => '远程协议版本不一致，请升级两端软件',
  'connection_closed' || 'connection_error' => '公网 VPS 连接已断开，正在自动重试',
  _ => '公网 VPS 返回错误：$code',
};

String _remoteDeliveryErrorText(String code) => switch (code) {
  'recipient_offline' || 'recipient_disconnected' => '对方远程设备已经离线',
  'delivery_timeout' => '对方没有确认收到，请确认对方软件保持运行并升级到同一版本',
  'decrypt_failed' => '对方无法解密，请重新核对所有设备的家庭加密口令',
  'processing_failed' => '对方已收到密文，但保存或处理失败，请导出对方诊断日志',
  'protocol_mismatch' => '远程协议版本不一致，请升级两端软件',
  _ => '公网传输失败：$code',
};

class _RemoteIncomingFile {
  _RemoteIncomingFile._({
    required this.transferId,
    required this.senderId,
    required this.senderName,
    required this.fileName,
    required this.totalBytes,
    required this.partFile,
    required this.sink,
  });

  final String transferId;
  final String senderId;
  final String senderName;
  final String fileName;
  final int totalBytes;
  final File partFile;
  final IOSink sink;
  int receivedBytes = 0;
  int nextChunkIndex = 0;
  int _bytesSinceFlush = 0;
  DateTime _lastProgressAt = DateTime.now();
  bool _closed = false;

  static Future<_RemoteIncomingFile> create({
    required String transferId,
    required String senderId,
    required String senderName,
    required String fileName,
    required int totalBytes,
  }) async {
    final root = await getTemporaryDirectory();
    final directory = Directory(
      path.join(root.path, 'remote-incoming', transferId),
    );
    await directory.create(recursive: true);
    final safeName = path
        .basename(fileName)
        .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), '_');
    final finalName = safeName.isEmpty ? 'remote-file' : safeName;
    final partFile = File(path.join(directory.path, '$finalName.part'));
    return _RemoteIncomingFile._(
      transferId: transferId,
      senderId: senderId,
      senderName: senderName,
      fileName: finalName,
      totalBytes: totalBytes,
      partFile: partFile,
      sink: partFile.openWrite(),
    );
  }

  Future<void> add(List<int> bytes) async {
    if (_closed) throw StateError('remote file is already closed');
    sink.add(bytes);
    receivedBytes += bytes.length;
    nextChunkIndex += 1;
    _bytesSinceFlush += bytes.length;
    if (_bytesSinceFlush >= 8 * 1024 * 1024) {
      await sink.flush();
      _bytesSinceFlush = 0;
    }
  }

  bool get shouldReportProgress {
    final now = DateTime.now();
    if (receivedBytes == totalBytes ||
        now.difference(_lastProgressAt) >= const Duration(milliseconds: 100)) {
      _lastProgressAt = now;
      return true;
    }
    return false;
  }

  Future<File> complete() async {
    if (_closed) throw StateError('remote file is already closed');
    _closed = true;
    await sink.flush();
    await sink.close();
    if (receivedBytes != totalBytes) {
      throw const FileSystemException('remote file size mismatch');
    }
    final target = File(
      partFile.path.substring(0, partFile.path.length - '.part'.length),
    );
    return partFile.rename(target.path);
  }

  Future<void> abort() async {
    if (!_closed) {
      _closed = true;
      await sink.close();
    }
    final directory = partFile.parent;
    if (await directory.exists()) await directory.delete(recursive: true);
  }
}
