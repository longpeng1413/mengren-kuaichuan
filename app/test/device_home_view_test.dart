import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lan_transfer/src/device/device_identity.dart';
import 'package:lan_transfer/src/discovery/discovered_device.dart';
import 'package:lan_transfer/src/ui/device_home_view.dart';

const _identity = DeviceIdentity(
  deviceId: 'abcd1234ef567890',
  displayName: '书房电脑',
  platform: 'windows',
);

DiscoveredDevice _device(String id, String name, String platform) =>
    DiscoveredDevice(
      deviceId: id,
      displayName: name,
      platform: platform,
      address: InternetAddress.loopbackIPv4,
      transferPort: 53318,
      lastSeen: DateTime(2026, 11, 3),
    );

Widget _home({
  List<DiscoveredDevice> devices = const [],
  ValueChanged<DiscoveredDevice>? onOpenDevice,
  VoidCallback? onPair,
  VoidCallback? onRename,
}) => MaterialApp(
  home: DeviceHomeView(
    identity: _identity,
    devices: devices,
    onRename: onRename ?? () {},
    onOpenDevice: onOpenDevice ?? (_) {},
    onPair: onPair ?? () {},
    onRefresh: () {},
    onOpenSettings: () {},
  ),
);

void main() {
  testWidgets('empty home explains discovery and offers manual pairing', (
    tester,
  ) async {
    var paired = 0;
    var renamed = 0;
    await tester.pumpWidget(
      _home(onPair: () => paired++, onRename: () => renamed++),
    );

    expect(find.text('书房电脑'), findsOneWidget);
    expect(find.text('ID ABCD'), findsOneWidget);
    expect(find.text('正在寻找附近的设备'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '二维码 / 手动连接'));
    await tester.tap(find.byTooltip('修改设备名称'));
    expect(paired, 1);
    expect(renamed, 1);
  });

  testWidgets('nearby devices are listed with route and open a chat', (
    tester,
  ) async {
    DiscoveredDevice? opened;
    await tester.pumpWidget(
      _home(
        devices: [
          _device('phone-0001', '我的手机', 'android'),
          _device('pc-0002', '客厅电脑', 'windows'),
        ],
        onOpenDevice: (device) => opened = device,
      ),
    );

    expect(find.text('正在寻找附近的设备'), findsNothing);
    expect(find.text('2'), findsOneWidget);
    expect(find.textContaining('Android · 局域网直连'), findsOneWidget);
    await tester.tap(find.text('客厅电脑'));
    expect(opened?.deviceId, 'pc-0002');
  });
}
