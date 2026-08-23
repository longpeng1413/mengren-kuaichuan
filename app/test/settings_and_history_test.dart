import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lan_transfer/src/chat/chat_message.dart';
import 'package:lan_transfer/src/pairing/pairing_endpoint.dart';
import 'package:lan_transfer/src/remote/remote_access_settings.dart';
import 'package:lan_transfer/src/settings/app_settings.dart';
import 'package:lan_transfer/src/settings/settings_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('remote access requires encrypted WSS and strong secrets', () {
    const insecure = RemoteAccessSettings(
      enabled: true,
      relayUrl: 'ws://relay.example.com/v1/relay',
      accessToken: '123456789012345678901234',
      familySecret: 'family-secret',
    );
    expect(insecure.validate, throwsFormatException);

    const secure = RemoteAccessSettings(
      enabled: true,
      relayUrl: 'wss://relay.example.com/v1/relay',
      accessToken: '123456789012345678901234',
      familySecret: 'family-secret',
    );
    expect(secure.validate, returnsNormally);
    expect(
      const RemoteAccessSettings(
        enabled: true,
        relayUrl: 'wss://relay.example.com/v1/relay',
        accessToken: ' 123456789012345678901234',
        familySecret: 'family-secret',
      ).validate,
      throwsFormatException,
    );
    expect(
      familySecretCheckCode('family-secret'),
      familySecretCheckCode(' family-secret '),
    );
  });

  test('family secret check code ignores surrounding whitespace', () {
    expect(
      familySecretCheckCode('same-family-secret'),
      familySecretCheckCode('  same-family-secret  '),
    );
    expect(
      familySecretCheckCode('same-family-secret'),
      isNot(familySecretCheckCode('different-family-secret')),
    );
  });

  testWidgets('remote secrets can be revealed and compared by check code', (
    tester,
  ) async {
    const remote = RemoteAccessSettings(
      enabled: true,
      relayUrl: 'wss://relay.example.com/v1/relay',
      accessToken: '123456789012345678901234',
      familySecret: 'same-family-secret',
    );
    await tester.pumpWidget(
      MaterialApp(
        home: SettingsPage(
          initialSettings: const AppSettings(),
          saveSettings: (_) async {},
          initialRemoteSettings: remote,
          saveRemoteSettings: (_) async {},
        ),
      ),
    );

    await tester.scrollUntilVisible(
      find.text('已启用 VPS 中转'),
      250,
      scrollable: find.byType(Scrollable),
    );
    await tester.tap(find.text('已启用 VPS 中转'));
    await tester.pumpAndSettle();

    final tokenField = find.byKey(const Key('remote_access_token_field'));
    final secretField = find.byKey(const Key('remote_family_secret_field'));
    expect(tester.widget<TextField>(tokenField).obscureText, isTrue);
    expect(tester.widget<TextField>(secretField).obscureText, isTrue);
    expect(
      find.textContaining(familySecretCheckCode(remote.familySecret)),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('remote_access_token_visibility')));
    await tester.tap(find.byKey(const Key('remote_family_secret_visibility')));
    await tester.pump();
    expect(tester.widget<TextField>(tokenField).obscureText, isFalse);
    expect(tester.widget<TextField>(secretField).obscureText, isFalse);
  });

  test('persists theme and custom receive locations', () async {
    final store = AppSettingsStore();
    const expected = AppSettings(
      themeColor: AppThemeColor.purple,
      themeMode: AppThemeMode.dark,
      launchAtStartup: true,
      windowsSaveDirectory: r'D:\猛人快传',
      androidTreeUri: 'content://tree/downloads',
      androidSaveLabel: '我的接收文件',
    );

    await store.save(expected);
    final loaded = await store.load();

    expect(loaded.themeColor, AppThemeColor.purple);
    expect(loaded.themeMode, AppThemeMode.dark);
    expect(loaded.launchAtStartup, isTrue);
    expect(loaded.windowsSaveDirectory, r'D:\猛人快传');
    expect(loaded.androidTreeUri, 'content://tree/downloads');
    expect(loaded.androidSaveLabel, '我的接收文件');
  });

  test('persists system file URI without treating it as cache', () async {
    final store = ChatHistoryStore();
    final message = ChatMessage(
      id: 'message-1',
      peerId: 'phone-1',
      peerName: '测试手机',
      senderId: 'phone-1',
      senderName: '测试手机',
      kind: ChatMessageKind.file,
      sentAt: DateTime.utc(2026, 8, 22),
      isOutgoing: false,
      fileName: '视频.mp4',
      contentUri: 'content://downloads/video',
      displayLocation: '系统下载/猛人快传/视频.mp4',
      fileSize: 1024,
    );

    await store.save([message]);
    final loaded = (await store.load()).single;

    expect(loaded.contentUri, message.contentUri);
    expect(loaded.displayLocation, message.displayLocation);
    expect(loaded.isCache, isFalse);
  });

  test('persists removed device IDs', () async {
    final store = RemovedDeviceStore();
    await store.save({'phone-1', 'laptop-2'});
    expect(await store.load(), {'phone-1', 'laptop-2'});
  });

  testWidgets('settings explains hotspot connection and 5 GHz speed', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SettingsPage(
          initialSettings: const AppSettings(),
          saveSettings: (_) async {},
        ),
      ),
    );

    expect(find.text('公网远程传输'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('传输时始终显示实际网络路线'),
      180,
      scrollable: find.byType(Scrollable),
    );
    expect(find.text('传输时始终显示实际网络路线'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('连接与高速传输'),
      260,
      scrollable: find.byType(Scrollable),
    );
    expect(find.text('连接与高速传输'), findsOneWidget);
    expect(find.text('手机热点互传'), findsOneWidget);
    expect(find.text('大文件请使用 5 GHz 热点'), findsOneWidget);
    expect(find.text('连接注意事项'), findsOneWidget);
  });
}
