import 'package:shared_preferences/shared_preferences.dart';

import 'app_settings.dart';

/// Devices whose LAN files may skip the "接收文件？" dialog under
/// [AutoAcceptMode.known]. Only the user's own actions add a device: sending
/// it something, pairing with it, or accepting one of its files by hand.
/// Merely receiving a message does not, so a stranger cannot earn trust by
/// sending text first.
class TrustedDeviceStore {
  static const _key = 'trusted_device_ids';

  /// Upper bound so the list cannot grow without limit; the oldest entries
  /// are dropped first.
  static const maxEntries = 200;

  Future<Set<String>> load() async {
    final preferences = await SharedPreferences.getInstance();
    return (preferences.getStringList(_key) ?? const <String>[]).toSet();
  }

  Future<void> save(Set<String> deviceIds) async {
    final preferences = await SharedPreferences.getInstance();
    final ordered = deviceIds.toList();
    final kept = ordered.length > maxEntries
        ? ordered.sublist(ordered.length - maxEntries)
        : ordered;
    await preferences.setStringList(_key, kept);
  }
}

/// Decides whether an incoming LAN file starts without asking.
bool shouldAutoAccept(AutoAcceptMode mode, {required bool trusted}) =>
    switch (mode) {
      AutoAcceptMode.all => true,
      AutoAcceptMode.known => trusted,
      AutoAcceptMode.ask => false,
    };
