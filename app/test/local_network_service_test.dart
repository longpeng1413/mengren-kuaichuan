import 'package:lan_transfer/src/network/local_network_service.dart';
import 'package:test/test.dart';

void main() {
  group('local network addresses', () {
    test('accepts local-network IPv4 ranges only', () {
      expect(isUsableLanIpv4('192.168.43.1'), isTrue);
      expect(isUsableLanIpv4('10.42.0.1'), isTrue);
      expect(isUsableLanIpv4('172.20.10.2'), isTrue);
      expect(isUsableLanIpv4('169.254.8.9'), isTrue);
      expect(isUsableLanIpv4('100.96.1.2'), isTrue);
      expect(isUsableLanIpv4('8.8.8.8'), isFalse);
      expect(isUsableLanIpv4('192.168.1.999'), isFalse);
    });

    test('calculates directed broadcasts from the actual prefix', () {
      expect(calculateIpv4Broadcast('192.168.43.1', 24), '192.168.43.255');
      expect(calculateIpv4Broadcast('172.20.10.2', 28), '172.20.10.15');
      expect(calculateIpv4Broadcast('10.42.7.12', 16), '10.42.255.255');
      expect(calculateIpv4Broadcast('10.42.7.12', 32), isNull);
    });

    test('rejects cellular interfaces and prioritizes hotspot interfaces', () {
      expect(isLikelyLanInterface('rmnet_data0'), isFalse);
      expect(isLikelyLanInterface('ccmni0'), isFalse);
      expect(isLikelyLanInterface('wlan0'), isTrue);
      expect(isLikelyHotspotInterface('ap0'), isTrue);

      final sorted = sortAndDeduplicateNetworkAddresses(const [
        LocalNetworkAddress(
          interfaceName: 'Ethernet',
          address: '192.168.1.30',
          prefixLength: 24,
        ),
        LocalNetworkAddress(
          interfaceName: 'ap0',
          address: '192.168.43.1',
          prefixLength: 24,
        ),
        LocalNetworkAddress(
          interfaceName: 'duplicate',
          address: '192.168.43.1',
          prefixLength: 24,
        ),
      ]);

      expect(sorted.map((item) => item.address), [
        '192.168.43.1',
        '192.168.1.30',
      ]);
    });

    test('announces to global and every directed broadcast once', () {
      final targets = discoveryBroadcastTargets(const [
        LocalNetworkAddress(
          interfaceName: 'ap0',
          address: '192.168.43.1',
          prefixLength: 24,
          broadcastAddress: '192.168.43.255',
        ),
        LocalNetworkAddress(
          interfaceName: 'wlan0',
          address: '192.168.43.20',
          prefixLength: 24,
          broadcastAddress: '192.168.43.255',
        ),
        LocalNetworkAddress(
          interfaceName: 'Ethernet',
          address: '10.1.2.3',
          prefixLength: 24,
        ),
      ]);

      expect(targets.map((target) => target.address), [
        '255.255.255.255',
        '192.168.43.255',
        '10.1.2.255',
      ]);
    });
  });
}
