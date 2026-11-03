# 猛人快传项目代理说明

本文件适用于整个项目。任何编程 AI 或自动化代理在修改代码前，必须按顺序完整阅读：

1. `AI_HANDOFF.md`
2. `docs/开发交接说明-v1.8.1.md`、`docs/开发交接说明-v1.8.0.md`，再读 `docs/开发交接说明-v1.7.8.md`、`docs/开发交接说明-v1.7.7.md`（v1.7.5 文档保留为历史资料）
3. `CHANGELOG.md`
4. 与任务相关的源文件和测试

## 产品边界

- 目标平台只有 Android 和 Windows。
- v1.7.0 在保留纯局域网能力的同时允许接入用户自有 VPS，但不引入 S3、公共账号系统或剪贴板同步。
- 必须保留文字、链接、图片、视频、大文件、二维码配对、自动发现、诊断日志和发送取消能力。
- 不能破坏 Android 已安装版本的升级签名。

## 当前基线

- 开发中版本：`1.8.4+31`，修复手机端一键更新下载不动（Android 改为读取系统代理，Dart `HttpClient` 默认不读）、进度显示速度；发布前等用户确认。手机 v1.8.3 及更早没有此修复，需手动装一次。
- 当前正式版：`1.8.3+30` / `v1.8.3`（2026-11-03 发布），设置页底部显示作者 longpeng1413 与 GitHub 链接，「默认纯局域网传输」说明移到首页。
- 上一个正式版：`1.8.2+29` / `v1.8.2`（2026-11-03 发布），二维码永远白底黑码（修复深色模式扫不出）、Windows 记住窗口大小（首次默认 750×760）、设置「使用帮助」新增公网远程传输配置步骤。
- 更早的正式版：`1.8.1+28` / `v1.8.1`（2026-11-03 发布，用户看过界面预览后确认），界面升级（小窗口居中、主界面/设置页/聊天页重新设计、宝石红默认强调色、Windows 微软雅黑）、`创建桌面快捷方式.cmd`、GitHub 附件改用拼音名。用户确认两台电脑都已从 v1.8.0 一键更新到本版成功。
- 更早的正式版：`1.8.0+27` / `v1.8.0`（2026-11-03 发布），新增检查更新与一键自动更新；用户已实测 Windows 一键更新（下载、替换、自动重启）通过。Android 一键更新尚未实机验证。
- 更早的正式版：`1.7.8+26` / `v1.7.8`，功能代码与 rc.2 相同，只更换了图标（红宝石配色，源图 `app/assets/icon/mengren_icon.png`）。
- 上一个修复候选版：`1.7.7+25` / `v1.7.7-rc.2`；用户已确认本轮交互修复可用，且上次 Windows 后台卡死修复已连续使用几天正常。历史 rc.1 保留。
- 实机验收：2026-10-14 用户确认 v1.7.8 实机验收通过：电脑休眠/唤醒、断网/切换 Wi-Fi 恢复、Android 后台返回与双向文字/文件/停止发送、Android 长按拖选复制均正常。
- 更早的正式版：`1.7.6+23` / `v1.7.6`。
- 本机正在使用的程序固定在 `dist\猛人快传`（文件夹名不带版本号，2026-11-03 起），桌面快捷方式永远指向这里。Windows 防火墙放行按程序完整路径记录，换文件夹就会重新弹「是否允许访问此应用」，所以新版本一律原地升级（软件内一键更新，或退出程序后把新包文件覆盖进去），不换文件夹、不改快捷方式。`dist` 里另外只保留最新版本的 apk、zip 和校验清单；打包生成的带版本号临时文件夹打包后可删，**不要删 `dist\猛人快传`**。
- 配对协议：`protocolVersion = 2`
- 公网协议：`protocolVersion = 3`，与局域网协议独立；发送成功必须收到接收端处理确认
- 测试数量：应用 77 项（含 11 项 UDP socket 回归、8 项文本选择复制回归、17 项更新回归、2 项主界面回归；另有 1 项需 `MENGREN_LIVE_UPDATE_TEST=1` 手动运行的真实 GitHub 更新测试）、远程协议 5 项、中转服务 7 项
- Windows 隐藏到托盘后必须保持 UDP 监听、公告、新设备发现和已知设备单播保活；不得复用 Android 的后台暂停策略。新增设备回归必须同时验证已有设备仍被保活。
- UDP 发现：53317
- TCP/HTTP/WebSocket：53318
- 所有参与传输的设备必须使用相同协议版本。
- 公网传输必须明确显示实际路线，局域网优先；任意单文件上限 200 MiB，发送必须允许停止并清理未完成文件。
- 公网客户端只接受 `wss://`，家庭加密口令不得发送到 VPS 或写入普通 SharedPreferences。

## 自动更新规则（v1.8.0 起）

- 客户端只读取 `longpeng1413/mengren-kuaichuan` 的 GitHub `releases/latest`：标签必须是 `vX.Y.Z` 正式版且高于当前版本；预发布、草稿和 `-rc` 标签不会推送给用户。
- 从 v1.8.1 起发布附件文件名必须是 `mengren-kuaichuan-android-vX.Y.Z.apk`、`mengren-kuaichuan-windows-x64-vX.Y.Z.zip`、`SHA256SUMS-vX.Y.Z.txt`（与仓库名一致；GitHub 会把中文文件名改成点号，所以不能用中文）。v1.8.0 客户端只认旧名 `mengren-transfer-…`，但在找不到时会退回「该 Release 中唯一的 .apk / 唯一含 windows 的 .zip」，所以每个 Release 里每个平台只能有一个安装包。客户端同时认新旧两种名字。
- Windows ZIP 根目录必须直接包含 `猛人快传.exe` 和 `data/app.so`（`scripts/package_windows.ps1` 已保证）。
- 发布正式 Release 即等于向所有已安装用户推送更新：必须先完成验证并经用户确认；APK 必须使用原签名。
- 不要更改 `update_cache` 的位置或启动清理逻辑而不同步测试；不要让自动检查上传任何用户数据。
- Windows 替换脚本不要用 Dart 的 `ProcessStartMode.detached` 启动：PowerShell 5.1 在无控制台模式下会立刻退出、什么都不执行（2026-11-03 实测出过问题）。保持中转 `Start-Process` + 「已启动」标记的方式，并保留按真实启动方式运行的测试。

## 开发规则

- 不要把 `dist` 中的安装包当作源代码。
- 不要提交或公开 `private-signing/debug.keystore`。
- 不要删除聊天历史、用户文件或签名密钥来解决构建问题。
- 使用 `scripts/flutter.ps1`，因为原项目路径包含中文；运行时确保 `L:` 未被占用。
- 修改配对、传输或取消协议时，必须同时修改 Android/Windows 共用代码和集成测试。
- 优先修复稳定性，不要在实机回归完成前扩展无关功能。
- Windows 窗口大小记忆在 `app/windows/runner/window_size_store.cpp`（注册表 `HKCU\Software\MengrenKuaichuan`），首次默认 750×760。
- 界面统一用 `app/lib/src/ui/app_theme.dart` 的主题；主界面布局在 `app/lib/src/ui/device_home_view.dart`（纯展示组件，状态仍在 `DeviceListPage`）。Windows 默认窗口尺寸和居中逻辑在 `app/windows/runner/main.cpp`，最小尺寸在 `desktop_tray_service.dart`。
- Windows 便携包不做安装程序（用户 2026-11-03 决定）；包内 `创建桌面快捷方式.cmd` + `create_desktop_shortcut.ps1` 负责建桌面快捷方式，源文件在 `packaging/windows/`。

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
- 对应版本交接文档（当前 `docs/开发交接说明-v1.8.1.md`，v1.8.2 补丁记录在其末尾）
- 安装测试说明和最终安装包文件名

完成工作后记录：问题原因、修改文件、验证结果、未实机验证部分和新安装包 SHA-256。
