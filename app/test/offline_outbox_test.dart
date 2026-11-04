import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lan_transfer/src/chat/chat_message.dart';
import 'package:lan_transfer/src/chat/chat_page.dart';
import 'package:lan_transfer/src/chat/offline_outbox.dart';
import 'package:lan_transfer/src/device/device_identity.dart';
import 'package:lan_transfer/src/discovery/discovered_device.dart';
import 'package:lan_transfer/src/transfer/transfer_models.dart';
import 'package:lan_transfer/src/ui/device_home_view.dart';
import 'package:shared_preferences/shared_preferences.dart';

ChatMessage _message(
  String id,
  String peerId,
  String peerName,
  DateTime sentAt, {
  bool outgoing = true,
  ChatDeliveryState? state,
}) => ChatMessage(
  id: id,
  peerId: peerId,
  peerName: peerName,
  senderId: outgoing ? 'me' : peerId,
  senderName: outgoing ? '我' : peerName,
  kind: ChatMessageKind.text,
  sentAt: sentAt,
  isOutgoing: outgoing,
  text: '你好',
  deliveryState: state,
);

DiscoveredDevice _online(String id, String name) => DiscoveredDevice(
  deviceId: id,
  displayName: name,
  platform: 'android',
  address: InternetAddress.loopbackIPv4,
  transferPort: 53318,
  lastSeen: DateTime(2026, 11, 5),
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('offline peers from history follow online ones, newest first', () {
    final devices = withOfflineKnownDevices(
      online: [_online('phone', '在线手机')],
      history: {
        'phone': [_message('1', 'phone', '在线手机', DateTime(2026, 11, 1))],
        'old-pc': [_message('2', 'old-pc', '旧电脑', DateTime(2026, 10, 1))],
        'huawei': [_message('3', 'huawei', '华为手机', DateTime(2026, 11, 4))],
        'gone': [_message('4', 'gone', '已移除', DateTime(2026, 11, 4))],
        'empty': const [],
      },
      platforms: const {'huawei': 'android'},
      removed: const {'gone'},
    );
    expect(devices.map((device) => device.deviceId), [
      'phone',
      'huawei',
      'old-pc',
    ]);
    expect(devices[0].isOffline, isFalse);
    expect(devices[1].isOffline, isTrue);
    expect(devices[1].displayName, '华为手机');
    expect(devices[1].platform, 'android');
    expect(devices[2].platform, 'unknown');
    expect(devices[1].routeLabel, '离线');
  });

  test('queued items expire after seven days', () {
    final now = DateTime(2026, 11, 12, 12);
    final fresh = _message(
      'a',
      'p',
      'P',
      now.subtract(const Duration(days: 6)),
      state: ChatDeliveryState.queued,
    );
    final stale = _message(
      'b',
      'p',
      'P',
      now.subtract(const Duration(days: 8)),
      state: ChatDeliveryState.queued,
    );
    final delivered = _message('c', 'p', 'P', DateTime(2026, 1, 1));
    expect(isOutboxExpired(fresh, now), isFalse);
    expect(isOutboxExpired(stale, now), isTrue);
    expect(isOutboxExpired(delivered, now), isFalse);
  });

  test('delivery state survives storage and old records still load', () async {
    final store = ChatHistoryStore();
    final queued = _message(
      'q',
      'p',
      'P',
      DateTime(2026, 11, 5),
      state: ChatDeliveryState.queued,
    );
    final failed = _message(
      'f',
      'p',
      'P',
      DateTime(2026, 11, 5, 1),
    ).withDelivery(ChatDeliveryState.failed, note: '文件已不存在，没有发送');
    final legacy = _message('l', 'p', 'P', DateTime(2026, 11, 5, 2));
    await store.save([queued, failed, legacy]);
    final loaded = {for (final m in await store.load()) m.id: m};
    expect(loaded['q']!.isQueued, isTrue);
    expect(loaded['f']!.deliveryState, ChatDeliveryState.failed);
    expect(loaded['f']!.deliveryNote, '文件已不存在，没有发送');
    expect(loaded['l']!.deliveryState, isNull);
    expect(legacy.toJson().containsKey('deliveryState'), isFalse);
  });

  test('platform memory round-trips', () async {
    final store = KnownDevicePlatformStore();
    await store.save({'a': 'android', 'b': 'windows'});
    expect(await store.load(), {'a': 'android', 'b': 'windows'});
  });

  testWidgets('a queued message says it waits and can be cancelled', (
    tester,
  ) async {
    String? discarded;
    final messages = ValueNotifier([
      _message(
        'queued-1',
        'huawei',
        '华为手机',
        DateTime(2026, 11, 5, 9),
        state: ChatDeliveryState.queued,
      ),
    ]);
    await tester.pumpWidget(
      MaterialApp(
        home: ChatPage(
          device: DiscoveredDevice.offline(
            deviceId: 'huawei',
            displayName: '华为手机',
            platform: 'android',
            lastSeen: DateTime(2026, 11, 5),
          ),
          messages: messages,
          incomingProgress: ValueNotifier<TransferProgressUpdate?>(null),
          onSendText: (_) async {},
          onSendFiles: (_, _, _) async {},
          onClearConversation: (_) async {},
          onRemoveDevice: () async {},
          onDiscardUndelivered: (id) => discarded = id,
        ),
      ),
    );
    expect(find.text('离线 · 发的内容会在对方上线后自动送达'), findsOneWidget);
    expect(find.text('等待对方上线，上线后自动发送'), findsOneWidget);
    await tester.tap(find.text('取消'));
    expect(discarded, 'queued-1');
  });

  testWidgets('after Enter sends, the input keeps focus for the next line', (
    tester,
  ) async {
    final sent = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: ChatPage(
          device: _online('phone', '在线手机'),
          messages: ValueNotifier(const []),
          incomingProgress: ValueNotifier<TransferProgressUpdate?>(null),
          onSendText: (text) async => sent.add(text),
          onSendFiles: (_, _, _) async {},
          onClearConversation: (_) async {},
          onRemoveDevice: () async {},
        ),
      ),
    );
    await tester.pump();
    final editable = find.byType(EditableText);
    expect(tester.widget<EditableText>(editable).focusNode.hasFocus, isTrue);

    await tester.enterText(find.byType(TextField), '第一句');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(sent, ['第一句']);
    expect(tester.widget<EditableText>(editable).focusNode.hasFocus, isTrue);

    await tester.enterText(find.byType(TextField), '第二句');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(sent, ['第一句', '第二句']);
  });

  testWidgets('home shows offline peers and how much waits for them', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: DeviceHomeView(
          identity: const DeviceIdentity(
            deviceId: 'abcd1234ef567890',
            displayName: '书房电脑',
            platform: 'windows',
          ),
          devices: [
            _online('phone', '在线手机'),
            DiscoveredDevice.offline(
              deviceId: 'huawei',
              displayName: '华为手机',
              platform: 'android',
              lastSeen: DateTime(2026, 11, 5),
            ),
          ],
          queuedCounts: const {'huawei': 2},
          onRename: () {},
          onOpenDevice: (_) {},
          onPair: () {},
          onRefresh: () {},
          onOpenSettings: () {},
        ),
      ),
    );
    expect(find.text('离线 · 发的内容会在对方上线后自动送达'), findsOneWidget);
    expect(find.text('2 条待发送'), findsOneWidget);
    // Only the online device counts as "nearby".
    expect(find.text('1'), findsOneWidget);
  });
}
