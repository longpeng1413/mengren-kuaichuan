import 'dart:convert';

import 'package:lan_transfer/src/discovery/discovery_message.dart';
import 'package:test/test.dart';

void main() {
  group('DiscoveryMessage', () {
    test('round-trips a valid announcement', () {
      const original = DiscoveryMessage(
        deviceId: '0123456789abcdef0123456789abcdef',
        displayName: '书房电脑',
        platform: 'windows',
        transferPort: 53318,
      );

      final decoded = DiscoveryMessage.tryDecode(original.encode());

      expect(decoded, isNotNull);
      expect(decoded!.deviceId, original.deviceId);
      expect(decoded.displayName, original.displayName);
      expect(decoded.platform, original.platform);
      expect(decoded.transferPort, original.transferPort);
    });

    test('rejects malformed or unsupported announcements', () {
      expect(DiscoveryMessage.tryDecode(utf8.encode('not-json')), isNull);
      expect(
        DiscoveryMessage.tryDecode(
          utf8.encode(
            jsonEncode({
              'version': 99,
              'type': 'announce',
              'deviceId': '0123456789abcdef',
              'displayName': '设备',
              'platform': 'windows',
              'port': 53318,
            }),
          ),
        ),
        isNull,
      );
    });

    test('rejects invalid ports and empty names', () {
      List<int> message({required String name, required int port}) {
        return utf8.encode(
          jsonEncode({
            'version': 1,
            'type': 'announce',
            'deviceId': '0123456789abcdef',
            'displayName': name,
            'platform': 'android',
            'port': port,
          }),
        );
      }

      expect(
        DiscoveryMessage.tryDecode(message(name: '', port: 53318)),
        isNull,
      );
      expect(DiscoveryMessage.tryDecode(message(name: '手机', port: 0)), isNull);
      expect(
        DiscoveryMessage.tryDecode(message(name: '手机', port: 70000)),
        isNull,
      );
    });
  });
}
