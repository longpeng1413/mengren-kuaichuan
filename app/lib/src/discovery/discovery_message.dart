import 'dart:convert';
import 'dart:typed_data';

class DiscoveryMessage {
  const DiscoveryMessage({
    required this.deviceId,
    required this.displayName,
    required this.platform,
    required this.transferPort,
  });

  static const protocolVersion = 1;
  static const messageType = 'announce';

  final String deviceId;
  final String displayName;
  final String platform;
  final int transferPort;

  Uint8List encode() {
    return Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'version': protocolVersion,
          'type': messageType,
          'deviceId': deviceId,
          'displayName': displayName,
          'platform': platform,
          'port': transferPort,
        }),
      ),
    );
  }

  static DiscoveryMessage? tryDecode(List<int> bytes) {
    try {
      if (bytes.length > 4096) return null;

      final value = jsonDecode(utf8.decode(bytes));
      if (value is! Map<String, dynamic>) return null;
      if (value['version'] != protocolVersion || value['type'] != messageType) {
        return null;
      }

      final deviceId = value['deviceId'];
      final displayName = value['displayName'];
      final platform = value['platform'];
      final port = value['port'];

      if (deviceId is! String ||
          deviceId.length < 8 ||
          deviceId.length > 128 ||
          displayName is! String ||
          displayName.trim().isEmpty ||
          displayName.length > 80 ||
          platform is! String ||
          platform.length > 32 ||
          port is! int ||
          port < 1 ||
          port > 65535) {
        return null;
      }

      return DiscoveryMessage(
        deviceId: deviceId,
        displayName: displayName.trim(),
        platform: platform,
        transferPort: port,
      );
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }
  }
}
