import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../discovery/discovered_device.dart';
import 'chat_message.dart';

/// Messages and files waiting for an offline peer. Queued items are ordinary
/// chat messages with [ChatDeliveryState.queued]; these limits keep the
/// outbox from growing without bound.
const outboxLimit = 100;
const outboxMaxAge = Duration(days: 7);

bool isOutboxExpired(ChatMessage message, DateTime now) =>
    message.isQueued && now.difference(message.sentAt) > outboxMaxAge;

/// Online devices first (as given), then devices only known from chat history
/// so the user can still open them and queue something.
List<DiscoveredDevice> withOfflineKnownDevices({
  required List<DiscoveredDevice> online,
  required Map<String, List<ChatMessage>> history,
  required Map<String, String> platforms,
  required Set<String> removed,
}) {
  final onlineIds = online.map((device) => device.deviceId).toSet();
  final offline = <DiscoveredDevice>[];
  for (final entry in history.entries) {
    final id = entry.key;
    if (entry.value.isEmpty || onlineIds.contains(id) || removed.contains(id)) {
      continue;
    }
    final last = entry.value.reduce(
      (a, b) => a.sentAt.isAfter(b.sentAt) ? a : b,
    );
    offline.add(
      DiscoveredDevice.offline(
        deviceId: id,
        displayName: last.peerName,
        platform: platforms[id] ?? 'unknown',
        lastSeen: last.sentAt,
      ),
    );
  }
  offline.sort((a, b) => b.lastSeen.compareTo(a.lastSeen));
  return [...online, ...offline];
}

/// Remembers each device's platform so an offline entry shows the right icon.
class KnownDevicePlatformStore {
  static const _key = 'known_device_platforms';
  static const maxEntries = 200;

  Future<Map<String, String>> load() async {
    final preferences = await SharedPreferences.getInstance();
    final raw = preferences.getString(_key);
    if (raw == null) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      return {
        for (final entry in decoded.entries)
          if (entry.key is String && entry.value is String)
            entry.key as String: entry.value as String,
      };
    } on FormatException {
      return {};
    }
  }

  Future<void> save(Map<String, String> platforms) async {
    final entries = platforms.entries.toList();
    final kept = entries.length > maxEntries
        ? entries.sublist(entries.length - maxEntries)
        : entries;
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(
      _key,
      jsonEncode({for (final entry in kept) entry.key: entry.value}),
    );
  }
}
