import 'package:flutter/material.dart';

import '../app_version.dart';
import '../device/device_identity.dart';
import '../discovery/discovered_device.dart';

/// The home screen: this device on top, nearby devices below. Pure layout;
/// all state and actions are owned by DeviceListPage.
class DeviceHomeView extends StatelessWidget {
  const DeviceHomeView({
    required this.identity,
    required this.devices,
    required this.onRename,
    required this.onOpenDevice,
    required this.onPair,
    required this.onRefresh,
    required this.onOpenSettings,
    this.remoteEnabled = false,
    this.remoteConnected = false,
    this.statusError,
    this.onDismissStatusError,
    this.remoteError,
    this.onRetryRemote,
    this.onDismissRemoteError,
    this.pendingSharedFileCount = 0,
    this.onDiscardSharedFiles,
    this.queuedCounts = const {},
    super.key,
  });

  final DeviceIdentity identity;
  final List<DiscoveredDevice> devices;
  final VoidCallback onRename;
  final ValueChanged<DiscoveredDevice> onOpenDevice;
  final VoidCallback onPair;
  final VoidCallback onRefresh;
  final VoidCallback onOpenSettings;
  final bool remoteEnabled;
  final bool remoteConnected;
  final String? statusError;
  final VoidCallback? onDismissStatusError;
  final String? remoteError;
  final VoidCallback? onRetryRemote;
  final VoidCallback? onDismissRemoteError;
  final int pendingSharedFileCount;
  final VoidCallback? onDiscardSharedFiles;

  /// Device ID → number of messages and files waiting for it to come online.
  final Map<String, int> queuedCounts;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 20,
        title: Text(isUpdateTestBuild ? appVersionLabel : '猛人快传'),
        actions: [
          IconButton(
            tooltip: '二维码 / 手动连接',
            onPressed: onPair,
            icon: const Icon(Icons.qr_code_2),
          ),
          IconButton(
            tooltip: '立即重新发现',
            onPressed: onRefresh,
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: '设置',
            onPressed: onOpenSettings,
            icon: const Icon(Icons.settings_outlined),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: CustomScrollView(
            slivers: [
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                sliver: SliverList.list(
                  children: [
                    _IdentityCard(
                      identity: identity,
                      onRename: onRename,
                      remoteEnabled: remoteEnabled,
                      remoteConnected: remoteConnected,
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(6, 10, 6, 0),
                      child: Row(
                        children: [
                          Icon(
                            Icons.lock_outline,
                            size: 14,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              remoteEnabled
                                  ? '局域网优先；仅远程设备使用加密 VPS 中转'
                                  : '默认纯局域网传输，不经过公网服务器',
                              key: const Key('route_privacy_note'),
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (statusError != null)
                      _Notice(
                        icon: Icons.error_outline,
                        tone: _NoticeTone.error,
                        message: statusError!,
                        actions: [
                          TextButton(
                            onPressed: onDismissStatusError,
                            child: const Text('知道了'),
                          ),
                        ],
                      ),
                    if (remoteError != null)
                      _Notice(
                        icon: Icons.cloud_off_outlined,
                        tone: _NoticeTone.error,
                        message: remoteError!,
                        actions: [
                          TextButton(
                            onPressed: onRetryRemote,
                            child: const Text('立即重试'),
                          ),
                          TextButton(
                            onPressed: onDismissRemoteError,
                            child: const Text('知道了'),
                          ),
                        ],
                      ),
                    if (pendingSharedFileCount > 0)
                      _Notice(
                        icon: Icons.share_outlined,
                        tone: _NoticeTone.info,
                        message:
                            '已从系统分享或“其他应用打开”接收 $pendingSharedFileCount 个文件，'
                            '请点击一个设备发送',
                        actions: [
                          TextButton(
                            onPressed: onDiscardSharedFiles,
                            child: const Text('取消发送'),
                          ),
                        ],
                      ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(4, 18, 4, 10),
                      child: Row(
                        children: [
                          Text(
                            '附近设备',
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          if (devices.any((device) => !device.isOffline)) ...[
                            const SizedBox(width: 8),
                            _CountBadge(
                              count: devices
                                  .where((device) => !device.isOffline)
                                  .length,
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              if (devices.isEmpty)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: _EmptyDevices(onPair: onPair),
                )
              else
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                  sliver: SliverList.separated(
                    itemCount: devices.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (context, index) => _DeviceTile(
                      device: devices[index],
                      queuedCount: queuedCounts[devices[index].deviceId] ?? 0,
                      onTap: () => onOpenDevice(devices[index]),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

IconData _platformIcon(String platform) => platform == 'android'
    ? Icons.smartphone_rounded
    : Icons.laptop_windows_rounded;

String _platformName(String platform) =>
    platform == 'android' ? 'Android' : 'Windows';

class _IdentityCard extends StatelessWidget {
  const _IdentityCard({
    required this.identity,
    required this.onRename,
    required this.remoteEnabled,
    required this.remoteConnected,
  });

  final DeviceIdentity identity;
  final VoidCallback onRename;
  final bool remoteEnabled;
  final bool remoteConnected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    // Dark mode's primary is a light pink; a deep tinted card fits there.
    final dark = theme.brightness == Brightness.dark;
    final onHero = dark ? Colors.white : colors.onPrimary;
    final brand = dark ? colors.inversePrimary : colors.primary;
    final gradient = [
      brand,
      Color.lerp(brand, Colors.black, dark ? 0.4 : 0.28)!,
    ];
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: gradient,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 16, 8, 16),
        child: Row(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: onHero.withValues(alpha: 0.16),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(_platformIcon(identity.platform), color: onHero),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    identity.displayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: onHero,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      _HeroChip(
                        dotColor: const Color(0xFF5BE38E),
                        label: '本机 · 局域网可见',
                        foreground: onHero,
                      ),
                      _HeroChip(
                        label: 'ID ${identity.shortId}',
                        foreground: onHero,
                      ),
                      if (remoteEnabled)
                        _HeroChip(
                          icon: remoteConnected
                              ? Icons.cloud_done_outlined
                              : Icons.cloud_sync_outlined,
                          label: remoteConnected ? 'VPS 已连接' : 'VPS 连接中',
                          foreground: onHero,
                        ),
                    ],
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: '修改设备名称',
              onPressed: onRename,
              color: onHero,
              icon: const Icon(Icons.edit_outlined),
            ),
          ],
        ),
      ),
    );
  }
}

class _HeroChip extends StatelessWidget {
  const _HeroChip({
    required this.label,
    required this.foreground,
    this.dotColor,
    this.icon,
  });

  final String label;
  final Color foreground;
  final Color? dotColor;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: foreground.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (dotColor != null) ...[
            Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(
                color: dotColor,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 5),
          ],
          if (icon != null) ...[
            Icon(icon, size: 13, color: foreground),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            style: Theme.of(context).textTheme.labelSmall
                ?.copyWith(color: foreground),
          ),
        ],
      ),
    );
  }
}

class _CountBadge extends StatelessWidget {
  const _CountBadge({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
      decoration: BoxDecoration(
        color: colors.primaryContainer,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        '$count',
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: colors.onPrimaryContainer,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _DeviceTile extends StatelessWidget {
  const _DeviceTile({
    required this.device,
    required this.onTap,
    this.queuedCount = 0,
  });

  final DiscoveredDevice device;
  final VoidCallback onTap;
  final int queuedCount;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    // Fixed route colours, independent of the accent colour: green = direct,
    // blue = saved secure link, amber = public VPS relay.
    final routeColor = switch (device.connectionMode) {
      DeviceConnectionMode.direct => const Color(0xFF2E9E5B),
      DeviceConnectionMode.paired => const Color(0xFF3B7DDD),
      DeviceConnectionMode.remote => const Color(0xFFE0A21B),
      DeviceConnectionMode.offline => colors.outline,
    };
    final tile = Card(
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: colors.primaryContainer,
                  borderRadius: BorderRadius.circular(13),
                ),
                child: Icon(
                  device.isRemote
                      ? Icons.cloud_outlined
                      : _platformIcon(device.platform),
                  color: colors.onPrimaryContainer,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      device.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Container(
                          width: 7,
                          height: 7,
                          decoration: BoxDecoration(
                            color: routeColor,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            device.isOffline
                                ? '离线 · 发的内容会在对方上线后自动送达'
                                : '${device.isRemote ? '远程 ' : ''}'
                                      '${_platformName(device.platform)}'
                                      ' · ${device.routeLabel} · ${device.shortId}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              if (queuedCount > 0)
                Container(
                  margin: const EdgeInsets.only(left: 8),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: colors.primaryContainer,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    '$queuedCount 条待发送',
                    key: Key('queued_${device.deviceId}'),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: colors.onPrimaryContainer,
                    ),
                  ),
                ),
              Icon(Icons.chevron_right, color: colors.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
    return device.isOffline ? Opacity(opacity: 0.6, child: tile) : tile;
  }
}

enum _NoticeTone { info, error }

class _Notice extends StatelessWidget {
  const _Notice({
    required this.icon,
    required this.tone,
    required this.message,
    required this.actions,
  });

  final IconData icon;
  final _NoticeTone tone;
  final String message;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final background = tone == _NoticeTone.error
        ? colors.errorContainer
        : colors.secondaryContainer;
    final foreground = tone == _NoticeTone.error
        ? colors.onErrorContainer
        : colors.onSecondaryContainer;
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Material(
        color: background,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 8, 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(icon, size: 20, color: foreground),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      message,
                      style: TextStyle(color: foreground, height: 1.4),
                    ),
                  ),
                ],
              ),
              Row(mainAxisSize: MainAxisSize.min, children: actions),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyDevices extends StatelessWidget {
  const _EmptyDevices({required this.onPair});

  final VoidCallback onPair;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 8, 32, 40),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // Static "radar" rings: no endless animation, so idle CPU stays low.
          SizedBox(
            width: 148,
            height: 148,
            child: Stack(
              alignment: Alignment.center,
              children: [
                for (final (size, alpha) in [
                  (148.0, 0.10),
                  (108.0, 0.16),
                  (70.0, 0.28),
                ])
                  Container(
                    width: size,
                    height: size,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: colors.primary.withValues(alpha: alpha),
                    ),
                  ),
                Icon(Icons.wifi_tethering, size: 30, color: colors.primary),
              ],
            ),
          ),
          const SizedBox(height: 20),
          Text(
            '正在寻找附近的设备',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '手机和电脑连上同一个 Wi-Fi 或热点，打开猛人快传就会自动出现。\n'
            '跨网段找不到时，可以扫码或手动输入地址连接。',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: colors.onSurfaceVariant,
              height: 1.6,
            ),
          ),
          const SizedBox(height: 20),
          FilledButton.tonalIcon(
            onPressed: onPair,
            icon: const Icon(Icons.qr_code_2),
            label: const Text('二维码 / 手动连接'),
          ),
        ],
      ),
    );
  }
}
