import 'package:flutter_test/flutter_test.dart';
import 'package:lan_transfer/src/chat/chat_message.dart';
import 'package:lan_transfer/src/pairing/pairing_endpoint.dart';
import 'package:lan_transfer/src/settings/app_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('persists theme and custom receive locations', () async {
    final store = AppSettingsStore();
    const expected = AppSettings(
      themeColor: AppThemeColor.purple,
      themeMode: AppThemeMode.dark,
      launchAtStartup: true,
      windowsSaveDirectory: r'D:\猛人快传',
      androidTreeUri: 'content://tree/downloads',
      androidSaveLabel: '我的接收文件',
    );

    await store.save(expected);
    final loaded = await store.load();

    expect(loaded.themeColor, AppThemeColor.purple);
    expect(loaded.themeMode, AppThemeMode.dark);
    expect(loaded.launchAtStartup, isTrue);
    expect(loaded.windowsSaveDirectory, r'D:\猛人快传');
    expect(loaded.androidTreeUri, 'content://tree/downloads');
    expect(loaded.androidSaveLabel, '我的接收文件');
  });

  test('persists system file URI without treating it as cache', () async {
    final store = ChatHistoryStore();
    final message = ChatMessage(
      id: 'message-1',
      peerId: 'phone-1',
      peerName: '测试手机',
      senderId: 'phone-1',
      senderName: '测试手机',
      kind: ChatMessageKind.file,
      sentAt: DateTime.utc(2026, 8, 22),
      isOutgoing: false,
      fileName: '视频.mp4',
      contentUri: 'content://downloads/video',
      displayLocation: '系统下载/猛人快传/视频.mp4',
      fileSize: 1024,
    );

    await store.save([message]);
    final loaded = (await store.load()).single;

    expect(loaded.contentUri, message.contentUri);
    expect(loaded.displayLocation, message.displayLocation);
    expect(loaded.isCache, isFalse);
  });

  test('persists removed device IDs', () async {
    final store = RemovedDeviceStore();
    await store.save({'phone-1', 'laptop-2'});
    expect(await store.load(), {'phone-1', 'laptop-2'});
  });
}
