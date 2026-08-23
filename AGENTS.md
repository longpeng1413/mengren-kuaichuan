# 猛人快传项目代理说明

本文件适用于整个项目。任何编程 AI 或自动化代理在修改代码前，必须按顺序完整阅读：

1. `AI_HANDOFF.md`
2. `docs/开发交接说明-v1.7.0.md`
3. `CHANGELOG.md`
4. 与任务相关的源文件和测试

## 产品边界

- 目标平台只有 Android 和 Windows。
- v1.7.0 在保留纯局域网能力的同时允许接入用户自有 VPS，但不引入 S3、公共账号系统或剪贴板同步。
- 必须保留文字、链接、图片、视频、大文件、二维码配对、自动发现、诊断日志和发送取消能力。
- 不能破坏 Android 已安装版本的升级签名。

## 当前基线

- 最新稳定版：`1.7.0+13`
- 当前发布标签：`v1.7.0`
- 配对协议：`protocolVersion = 2`
- 公网协议：`protocolVersion = 3`，与局域网协议独立；发送成功必须收到接收端处理确认
- 测试数量：应用 24 项、远程协议 3 项、中转服务 6 项
- UDP 发现：53317
- TCP/HTTP/WebSocket：53318
- 所有参与传输的设备必须使用相同协议版本。
- 公网传输必须明确显示实际路线，局域网优先；任意单文件上限 200 MiB，发送必须允许停止并清理未完成文件。
- 公网客户端只接受 `wss://`，家庭加密口令不得发送到 VPS 或写入普通 SharedPreferences。

## 开发规则

- 不要把 `dist` 中的安装包当作源代码。
- 不要提交或公开 `private-signing/debug.keystore`。
- 不要删除聊天历史、用户文件或签名密钥来解决构建问题。
- 使用 `scripts/flutter.ps1`，因为原项目路径包含中文；运行时确保 `L:` 未被占用。
- 修改配对、传输或取消协议时，必须同时修改 Android/Windows 共用代码和集成测试。
- 优先修复稳定性，不要在实机回归完成前扩展无关功能。

## 必须执行的验证

```powershell
.\scripts\flutter.ps1 analyze
.\scripts\flutter.ps1 test
.\scripts\flutter.ps1 build apk --release
.\scripts\flutter.ps1 build windows --release
```

修改公网协议或中转服务时，还必须分别在 `packages/remote_protocol` 和 `relay_server` 执行 `dart analyze` 与 `dart test`。

发布前还要验证 APK 签名、Manifest、Windows 单实例、TCP 53318 监听和 ZIP 文件完整性。

## 版本更新位置

发布新版本时至少同步更新：

- `app/pubspec.yaml`
- `app/lib/src/app_version.dart`
- `app/windows/runner/main.cpp`
- `CHANGELOG.md`
- `docs/开发交接说明-v1.7.0.md` 或对应版本交接文档
- 安装测试说明和最终安装包文件名

完成工作后记录：问题原因、修改文件、验证结果、未实机验证部分和新安装包 SHA-256。
