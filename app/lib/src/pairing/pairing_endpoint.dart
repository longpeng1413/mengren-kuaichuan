import 'dart:convert';
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
  static const _detailsKey = 'removed_devices_v2';

  Future<Set<String>> load() async {
    return (await loadEntries()).map((entry) => entry.deviceId).toSet();
  }

  Future<void> save(Set<String> deviceIds) async {
    final existing = {
      for (final entry in await loadEntries()) entry.deviceId: entry,
    };
    await saveEntries(
      deviceIds.map(
        (deviceId) =>
            existing[deviceId] ??
            RemovedDeviceEntry(deviceId: deviceId, displayName: ''),
      ),
    );
  }

  Future<List<RemovedDeviceEntry>> loadEntries() async {
    final preferences = await SharedPreferences.getInstance();
    final deviceIds = (preferences.getStringList(_key) ?? const <String>[])
        .toSet();
    final entries = <String, RemovedDeviceEntry>{};
    for (final raw in preferences.getStringList(_detailsKey) ?? const []) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is! Map<String, dynamic>) continue;
        final entry = RemovedDeviceEntry.tryFromJson(decoded);
        if (entry != null && deviceIds.contains(entry.deviceId)) {
          entries[entry.deviceId] = entry;
        }
      } on FormatException {
        // Keep legacy IDs available even if one optional display-name record
        // is damaged.
      }
    }
    for (final deviceId in deviceIds) {
      entries.putIfAbsent(
        deviceId,
        () => RemovedDeviceEntry(deviceId: deviceId, displayName: ''),
      );
    }
    final result = entries.values.toList()
      ..sort((left, right) => left.label.compareTo(right.label));
    return result;
  }

  Future<void> saveEntries(Iterable<RemovedDeviceEntry> values) async {
    final preferences = await SharedPreferences.getInstance();
    final entries =
        <String, RemovedDeviceEntry>{
            for (final entry in values) entry.deviceId: entry,
          }.values.toList()
          ..sort((left, right) => left.deviceId.compareTo(right.deviceId));
    await preferences.setStringList(
      _key,
      entries.map((entry) => entry.deviceId).toList(),
    );
    await preferences.setStringList(
      _detailsKey,
      entries.map((entry) => jsonEncode(entry.toJson())).toList(),
    );
  }
}

class RemovedDeviceEntry {
  const RemovedDeviceEntry({required this.deviceId, required this.displayName});

  final String deviceId;
  final String displayName;

  String get label {
    final trimmed = displayName.trim();
    return trimmed.isEmpty ? '设备 ${shortId.toUpperCase()}' : trimmed;
  }

  String get shortId =>
      deviceId.length <= 8 ? deviceId : deviceId.substring(0, 8);

  Map<String, String> toJson() => {
    'deviceId': deviceId,
    'displayName': displayName.trim(),
  };

  static RemovedDeviceEntry? tryFromJson(Map<String, dynamic> value) {
    final deviceId = value['deviceId'];
    final displayName = value['displayName'];
    if (deviceId is! String || deviceId.trim().length < 4) return null;
    return RemovedDeviceEntry(
      deviceId: deviceId.trim(),
      displayName: displayName is String ? displayName.trim() : '',
    );
  }
}
