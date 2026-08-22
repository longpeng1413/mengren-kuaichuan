import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class RemoteAccessSettings {
  const RemoteAccessSettings({
    this.enabled = false,
    this.relayUrl = '',
    this.accessToken = '',
    this.familySecret = '',
  });

  final bool enabled;
  final String relayUrl;
  final String accessToken;
  final String familySecret;

  bool get isConfigured =>
      relayUrl.trim().isNotEmpty &&
      accessToken.length >= 24 &&
      familySecret.length >= 12;

  Uri? get relayUri => Uri.tryParse(relayUrl.trim());

  RemoteAccessSettings copyWith({
    bool? enabled,
    String? relayUrl,
    String? accessToken,
    String? familySecret,
  }) {
    return RemoteAccessSettings(
      enabled: enabled ?? this.enabled,
      relayUrl: relayUrl ?? this.relayUrl,
      accessToken: accessToken ?? this.accessToken,
      familySecret: familySecret ?? this.familySecret,
    );
  }

  void validate() {
    if (!enabled) return;
    final uri = relayUri;
    if (uri == null || uri.scheme != 'wss' || uri.host.isEmpty) {
      throw const FormatException('公网中转地址必须是 wss:// 加密地址');
    }
    if (accessToken.length < 24) {
      throw const FormatException('VPS 访问令牌至少需要 24 个字符');
    }
    if (familySecret.length < 12 || familySecret.length > 256) {
      throw const FormatException('家庭加密口令需要 12-256 个字符');
    }
  }
}

class RemoteAccessSettingsStore {
  RemoteAccessSettingsStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  static const _enabledKey = 'remote_enabled_v1';
  static const _urlKey = 'remote_relay_url_v1';
  static const _tokenKey = 'remote_access_token_v1';
  static const _secretKey = 'remote_family_secret_v1';

  final FlutterSecureStorage _storage;

  Future<RemoteAccessSettings> load() async {
    final values = await _storage.readAll();
    return RemoteAccessSettings(
      enabled: values[_enabledKey] == 'true',
      relayUrl: values[_urlKey] ?? '',
      accessToken: values[_tokenKey] ?? '',
      familySecret: values[_secretKey] ?? '',
    );
  }

  Future<void> save(RemoteAccessSettings settings) async {
    settings.validate();
    await Future.wait([
      _storage.write(key: _enabledKey, value: settings.enabled.toString()),
      _storage.write(key: _urlKey, value: settings.relayUrl.trim()),
      _storage.write(key: _tokenKey, value: settings.accessToken),
      _storage.write(key: _secretKey, value: settings.familySecret),
    ]);
  }
}
