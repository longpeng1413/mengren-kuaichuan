import 'dart:io';

import 'package:flutter/services.dart';

const _platformChannel = MethodChannel(
  'com.personal.lantransfer.lan_transfer/files',
);

class LocalNetworkAddress {
  const LocalNetworkAddress({
    required this.interfaceName,
    required this.address,
    required this.prefixLength,
    this.broadcastAddress,
  });

  final String interfaceName;
  final String address;
  final int prefixLength;
  final String? broadcastAddress;

  bool get isLikelyHotspot => isLikelyHotspotInterface(interfaceName);

  String get displayLabel {
    final kind = isLikelyHotspot ? '热点/Wi-Fi' : interfaceName;
    return '$address  ·  $kind';
  }

  String? get resolvedBroadcastAddress =>
      broadcastAddress ?? calculateIpv4Broadcast(address, prefixLength);
}

class LocalNetworkService {
  const LocalNetworkService();

  Future<List<LocalNetworkAddress>> listAddresses() async {
    if (Platform.isAndroid) {
      try {
        final native = await _platformChannel.invokeListMethod<dynamic>(
          'networkInterfaces',
        );
        final parsed = _parseNativeAddresses(native);
        if (parsed.isNotEmpty) return parsed;
      } on PlatformException {
        // Fall through to Dart enumeration. QR/manual pairing must remain
        // available even when an OEM blocks native interface inspection.
      } on MissingPluginException {
        // Tests and early engine startup may not have the channel registered.
      }
    }
    return _listWithDart();
  }

  Future<List<LocalNetworkAddress>> _listWithDart() async {
    final result = <LocalNetworkAddress>[];
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
    );
    for (final interface in interfaces) {
      if (!isLikelyLanInterface(interface.name)) continue;
      for (final address in interface.addresses) {
        if (!isUsableLanIpv4(address.address)) continue;
        result.add(
          LocalNetworkAddress(
            interfaceName: interface.name,
            address: address.address,
            prefixLength: guessedIpv4PrefixLength(address.address),
          ),
        );
      }
    }
    return sortAndDeduplicateNetworkAddresses(result);
  }
}

List<LocalNetworkAddress> _parseNativeAddresses(List<dynamic>? values) {
  final result = <LocalNetworkAddress>[];
  for (final value in values ?? const <dynamic>[]) {
    if (value is! Map) continue;
    final interfaceName = value['name'];
    final address = value['address'];
    final prefixLength = value['prefixLength'];
    final broadcast = value['broadcast'];
    if (interfaceName is! String ||
        address is! String ||
        prefixLength is! int ||
        prefixLength < 0 ||
        prefixLength > 32 ||
        !isLikelyLanInterface(interfaceName) ||
        !isUsableLanIpv4(address)) {
      continue;
    }
    result.add(
      LocalNetworkAddress(
        interfaceName: interfaceName,
        address: address,
        prefixLength: prefixLength,
        broadcastAddress: broadcast is String && isValidIpv4(broadcast)
            ? broadcast
            : null,
      ),
    );
  }
  return sortAndDeduplicateNetworkAddresses(result);
}

List<LocalNetworkAddress> sortAndDeduplicateNetworkAddresses(
  Iterable<LocalNetworkAddress> addresses,
) {
  final byAddress = <String, LocalNetworkAddress>{};
  for (final address in addresses) {
    byAddress.putIfAbsent(address.address, () => address);
  }
  final result = byAddress.values.toList();
  result.sort((left, right) {
    final priority = _interfacePriority(left.interfaceName)
        .compareTo(_interfacePriority(right.interfaceName));
    if (priority != 0) return priority;
    return compareIpv4Addresses(left.address, right.address);
  });
  return List.unmodifiable(result);
}

List<InternetAddress> discoveryBroadcastTargets(
  Iterable<LocalNetworkAddress> addresses,
) {
  final values = <String>{'255.255.255.255'};
  for (final address in addresses) {
    final broadcast = address.resolvedBroadcastAddress;
    if (broadcast != null && broadcast != address.address) {
      values.add(broadcast);
    }
  }
  return values.map(InternetAddress.new).toList(growable: false);
}

bool isValidIpv4(String value) {
  final parts = value.split('.');
  if (parts.length != 4) return false;
  for (final part in parts) {
    if (part.isEmpty || (part.length > 1 && part.startsWith('0'))) return false;
    final number = int.tryParse(part);
    if (number == null || number < 0 || number > 255) return false;
  }
  return true;
}

bool isUsableLanIpv4(String value) {
  if (!isValidIpv4(value)) return false;
  final parts = value.split('.').map(int.parse).toList(growable: false);
  final first = parts[0];
  final second = parts[1];
  return first == 10 ||
      (first == 100 && second >= 64 && second <= 127) ||
      (first == 172 && second >= 16 && second <= 31) ||
      (first == 192 && second == 168) ||
      (first == 169 && second == 254);
}

bool isLikelyLanInterface(String name) {
  final normalized = name.toLowerCase();
  const rejectedFragments = <String>[
    'rmnet',
    'ccmni',
    'pdp',
    'wwan',
    'cellular',
    'v4-rmnet',
    'clat',
    'ipsec',
    'vpn',
    'tailscale',
    'wireguard',
    'utun',
    'dummy',
    'loopback',
  ];
  return !rejectedFragments.any(normalized.contains) &&
      normalized != 'lo' &&
      !normalized.startsWith('tun') &&
      !normalized.startsWith('wg');
}

bool isLikelyHotspotInterface(String name) {
  final normalized = name.toLowerCase();
  return normalized.contains('softap') ||
      normalized.contains('swlan') ||
      normalized == 'ap0' ||
      normalized.startsWith('wlan') ||
      normalized.contains('wi-fi') ||
      normalized.contains('wifi');
}

int guessedIpv4PrefixLength(String address) {
  final parts = address.split('.').map(int.tryParse).toList(growable: false);
  if (parts.length == 4 && parts[0] == 169 && parts[1] == 254) return 16;
  // Android hotspot and ordinary Wi-Fi networks overwhelmingly use /24.
  // Native Android enumeration supplies the exact value; this is only the
  // cross-platform fallback when a prefix is unavailable.
  return 24;
}

String? calculateIpv4Broadcast(String address, int prefixLength) {
  if (!isValidIpv4(address) || prefixLength < 0 || prefixLength >= 32) {
    return null;
  }
  final addressValue = _ipv4ToInt(address);
  final mask = prefixLength == 0
      ? 0
      : (0xffffffff << (32 - prefixLength)) & 0xffffffff;
  final broadcast = (addressValue & mask) | (~mask & 0xffffffff);
  return _intToIpv4(broadcast);
}

int compareIpv4Addresses(String left, String right) =>
    _ipv4ToInt(left).compareTo(_ipv4ToInt(right));

int _interfacePriority(String name) {
  final normalized = name.toLowerCase();
  if (normalized.contains('softap') ||
      normalized.contains('swlan') ||
      normalized == 'ap0') {
    return 0;
  }
  if (isLikelyHotspotInterface(name)) return 1;
  if (normalized.contains('ethernet') || normalized.startsWith('eth')) {
    return 2;
  }
  return 3;
}

int _ipv4ToInt(String value) {
  var result = 0;
  for (final part in value.split('.')) {
    result = (result << 8) | int.parse(part);
  }
  return result;
}

String _intToIpv4(int value) => <int>[
  (value >> 24) & 0xff,
  (value >> 16) & 0xff,
  (value >> 8) & 0xff,
  value & 0xff,
].join('.');
