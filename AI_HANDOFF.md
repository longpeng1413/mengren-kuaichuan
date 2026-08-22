# AI 快速接手入口

你正在接手“猛人快传”，一个 Flutter 编写的 Android + Windows 纯局域网传输工具。

## 第一步

先完整阅读：

1. `AGENTS.md`
2. `docs/开发交接说明-v1.6.1.md`
3. `CHANGELOG.md`
4. `README.md`

不要仅根据安装包逆向，也不要从头重建项目；完整源代码在 `app/`。

## 当前状态

- 最新版本：v1.6.1+8。
- Flutter analyze 无问题，20 项测试全部通过。
- Android 和 Windows Release 已构建。
- 当前需要用两台 Android 手机完成“一台开热点、另一台连接热点”的双向实机回归。
- v1.6.1 枚举 Android 热点/Wi-Fi 网卡及真实前缀，同时发送全局广播和每个网段的定向广播。
- 自动发现失败时，可由任意一台手机显示二维码、另一台手机扫码建立双向连接。
- 用户已完成双手机热点实测；2.4 GHz 约 8 MiB/s，切换 5 GHz 后达到 60–70 MB/s。
- v1.5.0 曾出现手机与四屏电脑扫码连接闪断；v1.6.0 已加入确定性的重复连接选择和实时路由回退。
- v1.6.0 新增发送端停止按钮，支持等待确认和传输中取消。
- 如果仍出现问题，首先读取 Android 设置页导出的诊断日志，不要先增加新功能。

## 关键限制

- v1.6.1 配对协议仍为 2，不能与 v1.5.0 混合测试文件传输。
- Android 签名密钥在开发资料包的 `private-signing/debug.keystore`，必须私密保存。
- 主资料包不含 `.tools` SDK 和编译缓存；工具版本及恢复方法在交接文档中。
- 公网/VPS 远程消息是未来版本范围，不要混入 v1.6.1。

## 常用入口

- 主业务：`app/lib/src/app.dart`
- 配对：`app/lib/src/pairing/pairing_relay.dart`
- 热点网卡：`app/lib/src/network/local_network_service.dart`
- UDP 发现：`app/lib/src/discovery/discovery_service.dart`
- HTTP 收发：`app/lib/src/transfer/`
- 聊天和停止按钮：`app/lib/src/chat/chat_page.dart`
- Android 原生分享/日志：`app/android/app/src/main/kotlin/com/personal/lantransfer/lan_transfer/MainActivity.kt`
- Windows 单实例：`app/windows/runner/main.cpp`
- 测试：`app/test/`

## 接手后的第一句建议

向用户确认两台手机是否都显示 v1.6.1，依次测试热点手机到连接手机、连接手机到热点手机的文字、图片和大文件；失败时导出新版诊断日志。
