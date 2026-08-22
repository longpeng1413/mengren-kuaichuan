# AI 快速接手入口

你正在接手“猛人快传”，一个 Flutter 编写的 Android + Windows 纯局域网传输工具。

## 第一步

先完整阅读：

1. `AGENTS.md`
2. `docs/开发交接说明-v1.6.0.md`
3. `CHANGELOG.md`
4. `README.md`

不要仅根据安装包逆向，也不要从头重建项目；完整源代码在 `app/`。

## 当前状态

- 最新版本：v1.6.0+7。
- Flutter analyze 无问题，15 项测试全部通过。
- Android 和 Windows Release 已构建。
- 当前需要用户在家庭网络用手机、四屏台式机和笔记本进行三设备实机回归。
- v1.5.0 曾出现手机与四屏电脑扫码连接闪断；v1.6.0 已加入确定性的重复连接选择和实时路由回退。
- v1.6.0 新增发送端停止按钮，支持等待确认和传输中取消。
- 如果仍出现问题，首先读取 Android 设置页导出的诊断日志，不要先增加新功能。

## 关键限制

- v1.6.0 配对协议为 2，不能与 v1.5.0 混合测试文件传输。
- Android 签名密钥在开发资料包的 `private-signing/debug.keystore`，必须私密保存。
- 主资料包不含 `.tools` SDK 和编译缓存；工具版本及恢复方法在交接文档中。
- 用户明确要求先暂停功能开发，下一次工作应从用户在家中的实机测试结果开始。

## 常用入口

- 主业务：`app/lib/src/app.dart`
- 配对：`app/lib/src/pairing/pairing_relay.dart`
- HTTP 收发：`app/lib/src/transfer/`
- 聊天和停止按钮：`app/lib/src/chat/chat_page.dart`
- Android 原生分享/日志：`app/android/app/src/main/kotlin/com/personal/lantransfer/lan_transfer/MainActivity.kt`
- Windows 单实例：`app/windows/runner/main.cpp`
- 测试：`app/test/`

## 接手后的第一句建议

向用户确认三台设备是否都显示 v1.6.0，并索取复现步骤、发生时间、发送方向和新版诊断日志，然后再决定是否修改代码。
