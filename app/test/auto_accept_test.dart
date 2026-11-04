import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lan_transfer/src/settings/app_settings.dart';
import 'package:lan_transfer/src/settings/settings_page.dart';
import 'package:lan_transfer/src/settings/trusted_devices.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('auto accept follows the chosen mode', () {
    expect(shouldAutoAccept(AutoAcceptMode.all, trusted: false), isTrue);
    expect(shouldAutoAccept(AutoAcceptMode.known, trusted: true), isTrue);
    expect(shouldAutoAccept(AutoAcceptMode.known, trusted: false), isFalse);
    expect(shouldAutoAccept(AutoAcceptMode.ask, trusted: true), isFalse);
  });

  test('receive options default to known devices and no background', () async {
    final store = AppSettingsStore();
    final defaults = await store.load();
    expect(defaults.autoAcceptMode, AutoAcceptMode.known);
    expect(defaults.androidBackgroundReceive, isFalse);

    await store.save(
      defaults.copyWith(
        autoAcceptMode: AutoAcceptMode.ask,
        androidBackgroundReceive: true,
      ),
    );
    final loaded = await store.load();
    expect(loaded.autoAcceptMode, AutoAcceptMode.ask);
    expect(loaded.androidBackgroundReceive, isTrue);
  });

  test('trusted devices persist and keep only the newest entries', () async {
    final store = TrustedDeviceStore();
    expect(await store.load(), isEmpty);
    final many = {
      for (var i = 0; i < TrustedDeviceStore.maxEntries + 5; i++) 'device-$i',
    };
    await store.save(many);
    final loaded = await store.load();
    expect(loaded.length, TrustedDeviceStore.maxEntries);
    expect(loaded, isNot(contains('device-0')));
    expect(loaded, contains('device-${TrustedDeviceStore.maxEntries + 4}'));
  });

  testWidgets('settings lets the user change how files are accepted', (
    tester,
  ) async {
    AppSettings? saved;
    await tester.pumpWidget(
      MaterialApp(
        home: SettingsPage(
          initialSettings: const AppSettings(),
          saveSettings: (settings) async => saved = settings,
        ),
      ),
    );

    final tile = find.byKey(const Key('auto_accept_mode'));
    await tester.ensureVisible(tile);
    await tester.pumpAndSettle();
    expect(find.text('自动接收文件'), findsOneWidget);
    expect(find.text('只限连接过的设备'), findsOneWidget);

    await tester.tap(tile);
    await tester.pumpAndSettle();
    expect(find.textContaining('公网 VPS 中转收到的文件也一直直接接收'), findsOneWidget);
    await tester.tap(find.byKey(const Key('auto_accept_ask')));
    await tester.pumpAndSettle();

    expect(saved?.autoAcceptMode, AutoAcceptMode.ask);
    expect(find.text('每次都询问'), findsOneWidget);
  });
}
