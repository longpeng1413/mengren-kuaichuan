import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

class PairingEndpoint {
  const PairingEndpoint({
    required this.host,
    required this.port,
    required this.code,
  });

  final String host;
  final int port;
  final String code;

  Uri get payload => Uri(
    scheme: 'mqt',
    host: 'pair',
    queryParameters: {'host': host, 'port': port.toString(), 'code': code},
  );

  static PairingEndpoint? tryParse(String value) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null || uri.scheme != 'mqt' || uri.host != 'pair') return null;
    final host = uri.queryParameters['host']?.trim();
    final port = int.tryParse(uri.queryParameters['port'] ?? '');
    final code = normalizePairingCode(uri.queryParameters['code'] ?? '');
    if (host == null ||
        host.isEmpty ||
        port == null ||
        port < 1 ||
        port > 65535 ||
        code == null) {
      return null;
    }
    return PairingEndpoint(host: host, port: port, code: code);
  }
}

String? normalizePairingCode(String input) {
  final value = input.replaceAll(RegExp(r'\s+'), '');
  return RegExp(r'^\d{8}$').hasMatch(value) ? value : null;
}

String formatPairingCode(String code) =>
    '${code.substring(0, 4)} ${code.substring(4)}';

class PairingStore {
  static const _codeKey = 'pairing_code';
  static const _hostKey = 'paired_host';
  static const _portKey = 'paired_port';
  static const _remoteCodeKey = 'paired_code';

  Future<String> loadOrCreateCode() async {
    final preferences = await SharedPreferences.getInstance();
    final existing = normalizePairingCode(
      preferences.getString(_codeKey) ?? '',
    );
    if (existing != null) return existing;

    final random = Random.secure();
    final code = List.generate(8, (_) => random.nextInt(10)).join();
    await preferences.setString(_codeKey, code);
    return code;
  }

  Future<PairingEndpoint?> loadEndpoint() async {
    final preferences = await SharedPreferences.getInstance();
    final host = preferences.getString(_hostKey)?.trim();
    final port = preferences.getInt(_portKey);
    final code = normalizePairingCode(
      preferences.getString(_remoteCodeKey) ?? '',
    );
    if (host == null || host.isEmpty || port == null || code == null) {
      return null;
    }
    return PairingEndpoint(host: host, port: port, code: code);
  }

  Future<void> saveEndpoint(PairingEndpoint endpoint) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_hostKey, endpoint.host);
    await preferences.setInt(_portKey, endpoint.port);
    await preferences.setString(_remoteCodeKey, endpoint.code);
  }

  Future<void> clearEndpoint() async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.remove(_hostKey);
    await preferences.remove(_portKey);
    await preferences.remove(_remoteCodeKey);
  }
}

class RemovedDeviceStore {
  static const _key = 'removed_device_ids';

  Future<Set<String>> load() async {
    final preferences = await SharedPreferences.getInstance();
    return (preferences.getStringList(_key) ?? const []).toSet();
  }

  Future<void> save(Set<String> deviceIds) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setStringList(_key, deviceIds.toList()..sort());
  }
}
