import 'package:lan_transfer/src/device/device_identity.dart';
import 'package:lan_transfer/src/discovery/discovery_service.dart';
import 'package:lan_transfer/src/network/local_network_service.dart';
import 'package:test/test.dart';

void main() {
  test(
    'paused discovery does not enumerate or announce network interfaces',
    () async {
      final network = _CountingNetworkService();
      final discovery = DiscoveryService(
        const DeviceIdentity(
          deviceId: '0123456789abcdef0123456789abcdef',
          displayName: '测试手机',
          platform: 'android',
        ),
        networkService: network,
      );
      addTearDown(discovery.dispose);

      await discovery.pause();
      await discovery.announce();
      discovery.updateIdentity(
        const DeviceIdentity(
          deviceId: '0123456789abcdef0123456789abcdef',
          displayName: '恢复后的测试手机',
          platform: 'android',
        ),
      );

      expect(network.calls, 0);
    },
  );
}

class _CountingNetworkService extends LocalNetworkService {
  @override
  Future<List<LocalNetworkAddress>> listAddresses() async {
    calls += 1;
    return const [];
  }

  int calls = 0;
}
