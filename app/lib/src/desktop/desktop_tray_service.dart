import 'dart:async';
import 'dart:io';

import 'package:flutter/painting.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../app_version.dart';

class DesktopTrayService with WindowListener, TrayListener {
  DesktopTrayService._();

  static final DesktopTrayService instance = DesktopTrayService._();
  bool _initialized = false;

  Future<void> initialize() async {
    if (!Platform.isWindows || _initialized) return;
    _initialized = true;
    await windowManager.ensureInitialized();
    windowManager.addListener(this);
    trayManager.addListener(this);
    await windowManager.setPreventClose(true);
    await trayManager.setIcon('assets/icon/mengren_tray.ico');
    await trayManager.setToolTip(appVersionLabel);
    await trayManager.setContextMenu(
      Menu(
        items: [
          MenuItem(key: 'show', label: '打开猛人快传'),
          MenuItem.separator(),
          MenuItem(key: 'exit', label: '彻底退出'),
        ],
      ),
    );
  }

  Future<void> showWindow() async {
    if (!Platform.isWindows) return;
    await windowManager.restore();
    await windowManager.show();
    await windowManager.focus();
  }

  Future<void> exitApplication() async {
    if (!Platform.isWindows) return;
    windowManager.removeListener(this);
    trayManager.removeListener(this);
    await trayManager.destroy();
    await windowManager.setPreventClose(false);
    await windowManager.destroy();
  }

  @override
  void onWindowClose() {
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
    unawaited(windowManager.hide());
  }

  @override
  void onTrayIconMouseDown() {
    unawaited(showWindow());
  }

  @override
  void onTrayIconRightMouseDown() {
    unawaited(trayManager.popUpContextMenu());
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'show':
        unawaited(showWindow());
      case 'exit':
        unawaited(exitApplication());
    }
  }
}
