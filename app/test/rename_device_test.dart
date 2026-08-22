import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lan_transfer/src/app.dart';
import 'package:lan_transfer/src/device/device_identity.dart';
import 'package:lan_transfer/src/settings/app_settings.dart';

void main() {
  testWidgets('saving a renamed device closes the dialog cleanly', (
    tester,
  ) async {
    DeviceIdentity? savedIdentity;
    const initialIdentity = DeviceIdentity(
      deviceId: '1234567890abcdef',
      displayName: '原设备名',
      platform: 'windows',
    );

    await tester.pumpWidget(
      LanTransferApp(
        initialIdentity: initialIdentity,
        pairingCode: '12345678',
        initialSettings: const AppSettings(),
        saveSettings: (_) async {},
        saveIdentity: (identity) async => savedIdentity = identity,
      ),
    );

    await tester.tap(find.byTooltip('修改设备名称'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '四屏电脑');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(find.text('修改设备名称'), findsNothing);
    expect(find.text('四屏电脑'), findsOneWidget);
    expect(savedIdentity?.displayName, '四屏电脑');
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}
