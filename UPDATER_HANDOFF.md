# 更新发布交接

本文件只说明混剪桌面版的发布和更新边界；当前交接以 `HANDOFF.md` 为准，实际上传步骤、OSS对象路径和缺失工具详见 [docs/RELEASE-GUIDE.md](docs/RELEASE-GUIDE.md)。历史进度保留在 `TIMEOFF.md`。

2026-11-01 已确认：源码包含 GitHub RC 构建器，缺少生产 `updater/UpdateAgent.exe` 的原始工程、生产外层 `Start.cmd`/`updater-config.json` 模板及 OSS 完整/增量制包器和上传器。不得用候选入口或其他产品更新器代替。下面的生产验证记录不是宣称当前仓库能独立重建生产链。

## 当前已验证状态

- 线上版本：`1.0.67`。
- 该版本的更新包 SHA-256：`FFFDC8A339BFDCD5667C65D546A75709097B5550CF0C63A4CB5796D8373A897A`。
- 该版本的完整包 SHA-256：`C767BB4774F63E00CC9C73F4A0EC721D0EDC225E57E124481DC229A130471E4D`。
- 已验证行为：应用运行时不执行更新；应用完全退出后，用户从启动入口启动时再检查、下载和替换更新。
- GitHub `v1.0.68-rc.1` 是**独立候选发布**，用于提供已修复的源码和可下载 Windows 包；它不上传 OSS 更新对象，不改本文件所述线上版本，也不会触发老用户自动更新。

## 发布硬性规则

1. 只从当前已验证源码构建，不把本仓库当作包含用户运行时的完整安装包。
2. 更新包递归排除 `config.ps1`、配置/日志/素材/work/成品/失败音频/备份，以及 `tools\paraformer\runtime`、`model_cache`、`downloads` 和 `fonts\UserAdded`。
3. 先解压到隔离目录，逐文件核对应用文件、用户数据和 Paraformer 目录；保留 `app.previous`，并验证失败回滚。
4. 上传后先回读每个对象的长度和 SHA-256；所有包可读且完整后，才更新 `latest.json` 与 catalog。
5. 发布后以一份旧版隔离副本做真实升级验证；不得让运行中的程序自动替换自身或重启。

## 接手前检查

```powershell
git status --short
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-All.ps1
dotnet build .\desktop-src\AutoCutDesktop.csproj -c Release
```

如需发布，请先完整阅读 `TIMEOFF.md`、本文件和更新器脚本，确认线上版本、发布源、受保护目录和回滚路径后再操作。

GitHub Release 与 OSS 正式更新是两条不同发布链：GitHub 候选可上传 Release 附件，但只要没有完成隔离旧版升级、对象回读和用户明确授权，就不得修改 OSS `updates/hun-jian/*`、`latest.json` 或任一 catalog。
