# AI 快速接手入口

你正在接手“猛人快传”，一个 Flutter 编写的 Android + Windows 传输工具；v1.7.0 在局域网高速直传基础上加入用户自有 VPS 的端到端加密远程传输。

## 第一步

先完整阅读：

1. `AGENTS.md`
2. `docs/开发交接说明-v1.7.4.md`
3. `CHANGELOG.md`
4. `README.md`

不要仅根据安装包逆向，也不要从头重建项目；完整源代码在 `app/`。

## 当前状态

- 当前修复版：v1.7.4+17，基于 GitHub `v1.7.3` 继续开发；修复分支为 `codex/fix-v1.7.1-relay-throughput`。
- v1.7.4 将会自动重连的本地配对路线改称“局域网安全连接”，避免误导为本次扫描二维码；设置新增“已移除设备”列表，可恢复单台或全部设备。
- v1.7.3 修复 Windows 把非 `/24` 有线网错误计算为 `/24`、导致跨有线/Wi-Fi 广播目标错误的问题；同时恢复被移除设备的手动扫码再添加，并在直连和二维码通道同时存在时优先直连、失败再回退二维码。
- v1.7.2 将公网文件流水从 4 块扩大到 16 块，客户端回执等待从 25 秒提高到 90 秒，中转记录提高到 120 秒，并把迟到/重复回执降级为服务端日志；公网协议仍为 3。
- v1.7.1 将公网加解密移出 Flutter UI isolate，并新增接收端停止、45 秒无数据清理、进度限频和 8 MiB 写盘背压。
- v1.7.0+10 已修复实机发现的“VPS 已转发但接收端无消息”误确认问题；公网协议已提升为 2，发送端必须等待接收端成功解密并处理后的确认，不再把 VPS 接受误报为送达。
- v1.7.0+13 将公网中转扩展为任意单文件不超过 200 MiB，包含视频、APK、压缩包和未知类型；公网协议为 3，中转服务和客户端必须使用相同版本。
- VPS 已部署 `mengren-relay:1.7.2-ack120`；正式 WSS 域名已完成文字、文件生命周期和 8 MiB 吞吐探测，旧容器已停止保留用于回滚。
- v1.7.0 Android/Windows Release 已构建；VPS、DNS、TLS、WSS、接收回执和 APK 文件生命周期探测已打通，长期跨地区稳定性仍需继续观察。
- 私有验收环境使用用户自有 VPS，实际域名、访问令牌和家庭口令不在公开仓库记录。公开文档统一使用 `relay.example.com`，每位使用者必须部署自己的中转服务。
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

先核对 `docs/开发交接说明-v1.7.4.md` 的修复、发布校验值与 VPS 现状；不得改动原个人网站 Caddy 站点。下一步是完成有线 Windows 与 Wi-Fi Android 的自动发现、局域网安全连接、设备移除恢复和两地 100–200 MiB 实机回归，任何密码、令牌或私钥都不得提交到 Git。
