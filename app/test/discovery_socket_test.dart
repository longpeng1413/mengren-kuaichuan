import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import 'package:lan_transfer/src/device/device_identity.dart';
import 'package:lan_transfer/src/discovery/discovery_service.dart';
import 'package:lan_transfer/src/discovery/discovery_message.dart';
import 'package:lan_transfer/src/network/local_network_service.dart';
import 'package:test/test.dart';

const _identity = DeviceIdentity(
  deviceId: '0123456789abcdef0123456789abcdef',
  displayName: 'Test desktop',
  platform: 'windows',
);

void main() {
  test('concurrent starts share a single pending UDP bind', () async {
    final binding = Completer<RawDatagramSocket>();
    var calls = 0;
    final service = DiscoveryService(
      _identity,
      networkService: _EmptyNetwork(),
      bindSocket: () {
        calls++;
        return binding.future;
      },
    );
    addTearDown(service.dispose);
    final first = service.start();
    final second = service.start();
    binding.complete(_FakeSocket());
    await Future.wait([first, second]);
    expect(calls, 1);
  });

  test('empty read disables readiness until an event-loop timer', () async {
    final socket = _FakeSocket();
    final service = _service(socket);
    addTearDown(service.dispose);
    await service.start();
    socket.events.add(RawSocketEvent.read);
    expect(socket.readEventsEnabled, isFalse);
    expect(socket.receiveCalls, 1);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(socket.readEventsEnabled, isTrue);
  });

  test('a busy UDP receive queue yields after a bounded batch', () async {
    final socket = _FakeSocket();
    for (var i = 0; i < 100; i++) {
      socket.datagrams.add(
        Datagram(Uint8List.fromList([0]), InternetAddress.loopbackIPv4, 53317),
      );
    }
    final service = _service(socket);
    addTearDown(service.dispose);
    await service.start();
    socket.events.add(RawSocketEvent.read);
    expect(socket.receiveCalls, 32);
    expect(socket.readEventsEnabled, isFalse);
  });

  test('pause closes a pending bind instead of publishing it', () async {
    final binding = Completer<RawDatagramSocket>();
    final socket = _FakeSocket();
    final service = DiscoveryService(
      _identity,
      networkService: _EmptyNetwork(),
      bindSocket: () => binding.future,
    );
    addTearDown(service.dispose);
    final starting = service.start();
    await service.pause();
    binding.complete(socket);
    await starting;
    expect(socket.closed, isTrue);
    expect(socket.listenCalls, 0);
  });

  test(
    'dispose prevents a late UDP bind from resurrecting discovery',
    () async {
      final binding = Completer<RawDatagramSocket>();
      final socket = _FakeSocket();
      final service = DiscoveryService(
        _identity,
        networkService: _EmptyNetwork(),
        bindSocket: () => binding.future,
      );
      final starting = service.start();
      await service.dispose();
      binding.complete(socket);
      await starting;
      expect(socket.closed, isTrue);
      expect(socket.listenCalls, 0);
    },
  );

  test('pause cancels pending read re-enable timers', () async {
    final socket = _FakeSocket();
    final service = _service(socket);
    addTearDown(service.dispose);
    await service.start();
    socket.events.add(RawSocketEvent.read);
    await service.pause();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(socket.closed, isTrue);
    expect(socket.readEventsEnabled, isFalse);
  });

  test(
    'repeated empty reads restart with bounded delay, not a hot loop',
    () async {
      final socket = _FakeSocket();
      var binds = 0;
      final logs = <String>[];
      final service = DiscoveryService(
        _identity,
        networkService: _EmptyNetwork(),
        onLog: logs.add,
        bindSocket: () async {
          binds++;
          return socket;
        },
      );
      addTearDown(service.dispose);
      await service.start();
      for (var i = 0; i < 8; i++) {
        socket.events.add(RawSocketEvent.read);
        if (i < 7) {
          await Future<void>.delayed(
            Duration(milliseconds: 20 * (1 << i) + 10),
          );
        }
      }
      await Future<void>.delayed(Duration.zero);
      expect(socket.closed, isTrue);
      expect(logs, contains('discovery_read_stalled action=restart_socket'));
      await service.announce();
      expect(binds, 1, reason: 'announce must not bypass the retry backoff');
    },
  );

  test('a retired listener cannot consume the replacement socket', () async {
    final old = _FakeSocket();
    final replacement = _FakeSocket();
    var binds = 0;
    final service = DiscoveryService(
      _identity,
      networkService: _EmptyNetwork(),
      bindSocket: () async => binds++ == 0 ? old : replacement,
    );
    addTearDown(service.dispose);
    await service.start();
    await service.pause();
    await service.resume();
    old.lastOnData!(RawSocketEvent.read);
    old.lastOnError!(const SocketException('late error'));
    old.lastOnDone!();
    await Future<void>.delayed(Duration.zero);
    expect(replacement.receiveCalls, 0);
    expect(replacement.closed, isFalse);
    expect(binds, 2);
  });

  test('pause/resume invalidates a bind begun before the pause', () async {
    final binding = Completer<RawDatagramSocket>();
    final old = _FakeSocket();
    final replacement = _FakeSocket();
    var binds = 0;
    final service = DiscoveryService(
      _identity,
      networkService: _EmptyNetwork(),
      bindSocket: () =>
          binds++ == 0 ? binding.future : Future.value(replacement),
    );
    addTearDown(service.dispose);
    final starting = service.start();
    await service.pause();
    final resuming = service.resume();
    binding.complete(old);
    await Future.wait([starting, resuming]);
    await Future<void>.delayed(Duration.zero);
    expect(old.closed, isTrue);
    expect(old.listenCalls, 0);
    expect(replacement.listenCalls, 1);
  });

  test(
    'real UDP receives announcements after empty and invalid packets',
    () async {
      final receiver = await RawDatagramSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final sender = await RawDatagramSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final port = receiver.port;
      var firstBind = true;
      final service = DiscoveryService(
        _identity,
        networkService: _EmptyNetwork(),
        bindSocket: () async {
          final socket = firstBind
              ? receiver
              : await RawDatagramSocket.bind(
                  InternetAddress.loopbackIPv4,
                  port,
                );
          firstBind = false;
          return _ReceiveOnlySocket(socket);
        },
      );
      addTearDown(service.dispose);
      addTearDown(sender.close);
      await service.start();
      final seen = service.devices
          .firstWhere(
            (devices) =>
                devices.any((device) => device.deviceId == 'peer12345678'),
          )
          .timeout(const Duration(seconds: 10));
      sender.send([], InternetAddress.loopbackIPv4, port);
      for (var i = 0; i < 100; i++) {
        sender.send([0], InternetAddress.loopbackIPv4, port);
      }
      final announcement = const DiscoveryMessage(
        deviceId: 'peer12345678',
        displayName: 'UDP peer',
        platform: 'android',
        transferPort: 53318,
      ).encode();
      // Announcements are periodic in production; UDP does not guarantee a
      // burst's last packet survives queue overflow or a stalled-socket reset.
      final retry = Timer.periodic(const Duration(milliseconds: 100), (_) {
        sender.send(announcement, InternetAddress.loopbackIPv4, port);
      });
      addTearDown(retry.cancel);
      final devices = await seen;
      expect(devices.single.displayName, 'UDP peer');
    },
  );

  test(
    'continuous background discovery keeps a peer and accepts a late newcomer',
    () async {
      final receiver = await RawDatagramSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final sender = await RawDatagramSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final port = receiver.port;
      final isolatedReceiver = _ReceiveOnlySocket(receiver);
      final service = DiscoveryService(
        _identity,
        networkService: _EmptyNetwork(),
        bindSocket: () async => isolatedReceiver,
      );
      addTearDown(service.dispose);
      addTearDown(sender.close);
      var latest = <String>[];
      final subscription = service.devices.listen((devices) {
        latest = devices.map((device) => device.deviceId).toList();
      });
      addTearDown(subscription.cancel);
      await service.start();
      void announce(String id) => sender.send(
        DiscoveryMessage(
          deviceId: id,
          displayName: id,
          platform: 'android',
          transferPort: 53318,
        ).encode(),
        InternetAddress.loopbackIPv4,
        port,
      );
      final initial = service.devices
          .firstWhere(
            (devices) =>
                devices.any((device) => device.deviceId == 'existing12345'),
          )
          .timeout(const Duration(seconds: 5));
      final heartbeat = Timer.periodic(const Duration(seconds: 2), (_) {
        announce('existing12345');
      });
      addTearDown(heartbeat.cancel);
      announce('existing12345');
      await initial;
      // Exceed the seven-second offline cutoff with no foreground/UI activity.
      await Future<void>.delayed(const Duration(seconds: 8));
      expect(latest, contains('existing12345'));
      expect(
        isolatedReceiver.sends,
        greaterThanOrEqualTo(4),
        reason: 'periodic announcements must continue without foreground UI',
      );
      final newcomer = service.devices
          .firstWhere(
            (devices) =>
                devices.any((device) => device.deviceId == 'newcomer12345'),
          )
          .timeout(const Duration(seconds: 3));
      announce('newcomer12345');
      final newcomerRetry = Timer.periodic(const Duration(milliseconds: 100), (
        _,
      ) {
        announce('newcomer12345');
      });
      addTearDown(newcomerRetry.cancel);
      final devices = await newcomer;
      expect(
        devices.map((device) => device.deviceId),
        containsAll(['existing12345', 'newcomer12345']),
      );
    },
  );
}

DiscoveryService _service(_FakeSocket socket) => DiscoveryService(
  _identity,
  networkService: _EmptyNetwork(),
  bindSocket: () async => socket,
);

class _EmptyNetwork extends LocalNetworkService {
  @override
  Future<List<LocalNetworkAddress>> listAddresses() async => const [];
}

// Real loopback receives, but suppress outbound discovery broadcasts so tests
// cannot reach the user's running app/phones or depend on loopback broadcast.
class _ReceiveOnlySocket extends Stream<RawSocketEvent>
    implements RawDatagramSocket {
  _ReceiveOnlySocket(this.socket);
  final RawDatagramSocket socket;
  int sends = 0;
  @override
  bool get readEventsEnabled => socket.readEventsEnabled;
  @override
  set readEventsEnabled(bool value) => socket.readEventsEnabled = value;
  @override
  bool get writeEventsEnabled => socket.writeEventsEnabled;
  @override
  set writeEventsEnabled(bool value) => socket.writeEventsEnabled = value;
  @override
  bool get broadcastEnabled => socket.broadcastEnabled;
  @override
  set broadcastEnabled(bool value) => socket.broadcastEnabled = value;
  @override
  StreamSubscription<RawSocketEvent> listen(
    void Function(RawSocketEvent)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => socket.listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
  @override
  Datagram? receive() => socket.receive();
  @override
  int send(List<int> buffer, InternetAddress address, int port) {
    sends++;
    return buffer.length;
  }

  @override
  void close() => socket.close();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeSocket extends Stream<RawSocketEvent> implements RawDatagramSocket {
  final events = StreamController<RawSocketEvent>(sync: true);
  final datagrams = Queue<Datagram>();
  var closed = false;
  var listenCalls = 0;
  var receiveCalls = 0;
  void Function(RawSocketEvent)? lastOnData;
  Function? lastOnError;
  void Function()? lastOnDone;
  @override
  bool readEventsEnabled = true;
  @override
  bool writeEventsEnabled = true;
  @override
  bool broadcastEnabled = false;

  @override
  StreamSubscription<RawSocketEvent> listen(
    void Function(RawSocketEvent)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    listenCalls++;
    lastOnData = onData;
    lastOnError = onError;
    lastOnDone = onDone;
    return events.stream.listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }

  @override
  Datagram? receive() {
    receiveCalls++;
    return datagrams.isEmpty ? null : datagrams.removeFirst();
  }

  @override
  int send(List<int> buffer, InternetAddress address, int port) =>
      buffer.length;

  @override
  void close() {
    closed = true;
    unawaited(events.close());
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
