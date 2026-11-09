import 'dart:io';

import 'package:launch_at_startup/launch_at_startup.dart';

/// Passed by the Windows Run entry when 静默启动 is on. The native runner
/// (main.cpp) then keeps the window hidden; the tray icon still appears and
/// LAN discovery/receiving run as usual.
const silentStartArgument = '--silent';

bool isSilentStart(List<String> arguments) =>
    arguments.contains(silentStartArgument);

/// Registers or removes the login entry in HKCU\...\CurrentVersion\Run as
/// `"<exe>" --silent`; the path is quoted so a folder with spaces still gets
/// its argument. Re-run at every start so the entry follows the current EXE
/// path and the 静默启动 choice.
Future<bool> applyLaunchAtStartup({
  required bool enabled,
  required bool silent,
}) async {
  if (!Platform.isWindows) return false;
  launchAtStartup.setup(
    appName: '猛人快传',
    appPath: '"${Platform.resolvedExecutable}"',
    args: silent ? const [silentStartArgument] : const [],
  );
  return enabled ? launchAtStartup.enable() : launchAtStartup.disable();
}
