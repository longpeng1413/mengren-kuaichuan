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

  test('direct discovery replies are rate limited per peer', () {
    final firstReplyAt = DateTime.utc(2026, 9, 17, 8);
    const cooldown = Duration(seconds: 1);

    expect(
      shouldReplyToDiscoveryAnnouncement(
        lastReplyAt: null,
        now: firstReplyAt,
        cooldown: cooldown,
      ),
      isTrue,
    );
    expect(
      shouldReplyToDiscoveryAnnouncement(
        lastReplyAt: firstReplyAt,
        now: firstReplyAt.add(const Duration(milliseconds: 999)),
        cooldown: cooldown,
      ),
      isFalse,
    );
    expect(
      shouldReplyToDiscoveryAnnouncement(
        lastReplyAt: firstReplyAt,
        now: firstReplyAt.add(cooldown),
        cooldown: cooldown,
      ),
      isTrue,
    );
  });

  test('direct discovery replies recover after a wall-clock rollback', () {
    final lastReplyAt = DateTime.utc(2026, 9, 17, 8, 0, 10);

    expect(
      shouldReplyToDiscoveryAnnouncement(
        lastReplyAt: lastReplyAt,
        now: lastReplyAt.subtract(const Duration(seconds: 5)),
        cooldown: const Duration(seconds: 1),
      ),
      isTrue,
    );
  });
}

class _CountingNetworkService extends LocalNetworkService {
  @override
  Future<List<LocalNetworkAddress>> listAddresses() async {
    calls += 1;
    return const [];
  }

  int calls = 0;
}
