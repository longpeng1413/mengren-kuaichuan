import 'dart:io';

import 'package:mengren_relay_server/relay_server.dart';

Future<void> main() async {
  final environment = Platform.environment;
  final token = environment['MQT_RELAY_TOKEN'];
  if (token == null || token.length < 24) {
    stderr.writeln('MQT_RELAY_TOKEN must contain at least 24 characters.');
    exitCode = 64;
    return;
  }
  final port = int.tryParse(environment['MQT_RELAY_PORT'] ?? '') ?? 8080;
  final address = InternetAddress(environment['MQT_RELAY_BIND'] ?? '127.0.0.1');
  final server = RelayServer(accessToken: token);
  await server.start(address: address, port: port);
  stdout.writeln(
    'Mengren relay listening on ${address.address}:${server.port}',
  );

  final shutdownSignals = <Future<ProcessSignal>>[
    ProcessSignal.sigint.watch().first,
    if (!Platform.isWindows) ProcessSignal.sigterm.watch().first,
  ];
  await Future.any(shutdownSignals);
  await server.close();
}
