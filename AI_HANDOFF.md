# AI 快速接手入口

你正在接手“猛人快传”，一个 Flutter 编写的 Android + Windows 传输工具；v1.7.0 在局域网高速直传基础上加入用户自有 VPS 的端到端加密远程传输。

## 第一步

先完整阅读：

1. `AGENTS.md`
2. `docs/开发交接说明-v1.7.0.md`
3. `CHANGELOG.md`
4. `README.md`

不要仅根据安装包逆向，也不要从头重建项目；完整源代码在 `app/`。

## 当前状态

- 最新稳定版：v1.7.0+13；发布标签为 `v1.7.0`，源代码合入 `main`。
- v1.7.0+10 已修复实机发现的“VPS 已转发但接收端无消息”误确认问题；公网协议已提升为 2，发送端必须等待接收端成功解密并处理后的确认，不再把 VPS 接受误报为送达。
- v1.7.0+13 将公网中转扩展为任意单文件不超过 200 MiB，包含视频、APK、压缩包和未知类型；公网协议为 3，中转服务和客户端必须使用相同版本。
- VPS 已部署 `mengren-relay:1.7.0-protocol3`；正式 WSS 域名已完成文字和 APK 文件生命周期的加密、转发、解密及接收确认探测。
- v1.7.0 Android/Windows Release 已构建；VPS、DNS、TLS、WSS、接收回执和 APK 文件生命周期探测已打通，长期跨地区稳定性仍需继续观察。
- 当前中转地址是 `wss://relay.meng1314.de5.net/v1/relay`。`zlp1314.top` 不在当前 Cloudflare 登录账号的域名列表中，故按用户授权使用第一个免费托管域名；原个人网站没有改动。
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
- v1.7.0 已加入用户自有 VPS 的在线密文中转，详细边界见交接文档。

## 常用入口

- 主业务：`app/lib/src/app.dart`
- 配对：`app/lib/src/pairing/pairing_relay.dart`
- 热点网卡：`app/lib/src/network/local_network_service.dart`
- UDP 发现：`app/lib/src/discovery/discovery_service.dart`
- HTTP 收发：`app/lib/src/transfer/`
- 公网客户端与加密：`packages/remote_protocol/`
- VPS 中转服务：`relay_server/`
- 远程设置：`app/lib/src/remote/remote_access_settings.dart`
- 聊天和停止按钮：`app/lib/src/chat/chat_page.dart`
- Android 原生分享/日志：`app/android/app/src/main/kotlin/com/personal/lantransfer/lan_transfer/MainActivity.kt`
- Windows 单实例：`app/windows/runner/main.cpp`
- 测试：`app/test/`

## 接手后的第一句建议

先核对 `docs/开发交接说明-v1.7.0.md` 的 VPS 现状；不得改动原个人网站 Caddy 站点。下一步是两地实机回归，任何密码、令牌或私钥都不得提交到 Git。
