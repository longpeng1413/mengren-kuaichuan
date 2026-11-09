# 猛人快传 Flutter 客户端（lan_transfer）

Android 与 Windows 共用的 Flutter 源代码。内部工程名 `lan_transfer`（改名会影响应用数据和 Android 包名，不要改），Windows 便携包里的启动程序名为 `猛人快传.exe`。

- 功能介绍和下载：见仓库首页 [README](../README.md)。
- 代码结构和实现方式：见 [架构说明](../docs/architecture.md)。
- 开发规则、验证步骤和版本号位置：见 [AGENTS.md](../AGENTS.md)。

项目路径含中文，请通过包装脚本运行 Flutter（会临时映射到 `L:` 盘）：

```powershell
..\scripts\flutter.ps1 analyze
..\scripts\flutter.ps1 test
```
