# 自动剪辑桌面版完整交接

本文件是新会话和新电脑的单一接手入口；历史细节见 `TIMEOFF.md`。原开发电脑的规范源目录为 `E:\自动化\混剪\自动剪辑桌面版_V16`；新电脑以自己的克隆目录为项目根目录。Git 远端为 `https://github.com/nmrsz645-bit/hunjian.git`。

## 当前状态与目标

- Git `main` 是唯一源码版本依据；接手时执行 `git status --short`、`git pull --ff-only` 和 `git rev-parse HEAD` 获取当前提交。不要依赖文档中会过期的固定提交号。
- 当前目标是维持已验证的源码与交接能力。**没有待发布版本**；除非用户明确授权，不创建更新包、不上传 OSS、不改 `latest.json`/catalog，也不通知更新程序。
- 已完成最后一轮稳定性修复：监控 TXT 安全删除、渲染总超时、短任务防重入、单长素材不重叠取材、示例配置模型路径和源码 CI。

## 第一条操作

在项目根目录运行（新电脑将 `<你的克隆目录>` 改为实际 `git clone` 后的目录）：

```powershell
Set-Location '<你的克隆目录>'
git status --short
git pull --ff-only
git rev-parse HEAD
```

然后阅读 `AGENTS.md`、`README.md`、本文件和 `TIMEOFF.md` 顶部的“当前交接快照”。若 Git 状态非空，先保留并确认这些改动来源，不要重置或覆盖。

## 新电脑接手与运行

1. 克隆仓库：`git clone https://github.com/nmrsz645-bit/hunjian.git`。
2. 优先向维护者取得 Paraformer 离线包，校验 SHA-256 后解压到 `tools\paraformer`，使该目录直接含有 `runtime`、`model_cache`、`downloads`。然后运行以下命令；它会创建本机 `config.ps1` 并下载、校验其余运行依赖，且不会覆盖已有配置、模型或运行时：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Initialize-NewComputer.ps1 -SkipParaformer
```

3. 没有离线包时，才删除 `-SkipParaformer` 让引导脚本在线下载 Paraformer；中断后保留日志和已有目录，不能手工删除或覆盖。无网络时，**直接复制** `config.example.ps1` 为 `config.ps1`，保留 UTF-8 BOM；不要用会转换编码的编辑器另存，并从受控备份恢复这些目录到项目同名位置：

   - `tools\ffmpeg`
   - `tools\whisper`
   - `tools\opencc`
   - `tools\models`
   - `tools\paraformer\runtime`
   - `tools\paraformer\model_cache`
   - `tools\paraformer\downloads`
   - 可选用户字幕字体：`fonts\UserAdded`

4. 只在上述依赖下载或恢复完成后运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Start-AutoCut.ps1 -CheckOnly
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Start-AutoCut.ps1 -Test
```

`-CheckOnly` 会创建首次运行目录和本地版本备份；它不是纯只读命令。源码 Git 不包含二进制依赖、模型、个人配置和媒体数据，这是保护规则，不是遗漏。

## 已完成验证

- Windows PowerShell：`tests\Test-All.ps1` 20 项通过。
- 桌面端：`dotnet build .\desktop-src\AutoCutDesktop.csproj -c Release`，0 警告、0 错误。
- GitHub 远端新克隆：`tests\Test-Handover.ps1` 与桌面构建通过；示例配置 BOM 正确，模型/用户数据未进入仓库。
- 真实隔离验证：15 分 05 秒 MP3，唯一 15 分 10 秒素材，Paraformer-large、NVENC、随机不重叠取材，输出 905 秒 H.264/AAC 成片。字幕在第 7 分 30 秒和第 15 分钟画面已确认烧录；Paraformer 模型缓存 31 文件 SHA-256 无差异。
- 证据目录：`D:\ui\temp\hun_jian_long_source_stability_20260831`；真实成片：`完成\《真实长音频单素材》\真实长音频单素材.mp4`。

## 关键文件

| 文件 | 职责 |
| --- | --- |
| `AutoCut.ps1` | 剪辑、字幕、渲染、长音频和任务超时 |
| `Auto-Monitor.ps1` | 监控、队列、临时失败重试和音频清理 |
| `desktop-src\Program.cs` | 桌面界面、日志限流、状态刷新、短任务防重入 |
| `Start-AutoCut.ps1` | 环境检测、启动和首次配置修复 |
| `config.example.ps1` | 新电脑默认配置，不含密钥 |
| `tests\Test-All.ps1` | 完整本地回归入口 |
| `tests\Test-Handover.ps1` | 无个人配置的新克隆交接检查 |
| `UPDATER_HANDOFF.md` | 更新发布边界和隔离升级规则 |

## 已知边界

- 监控有 5/20/60 分钟重试和最多 3 次策略；最终失败会进入 `失败音频`。
- 单素材长音频已真实通过；渲染任务上限为 `max(30 分钟, 音频时长×3+10 分钟)`，最大 12 小时，超时后按原补剪流程处理。
- GitHub Actions 工作流只检查源码、交接文件和桌面构建；它无法替代含真实模型、GPU、音视频的隔离验收。
- 历史线上版本记录可能不同步；需要发布时必须重新读取公网清单和对象 SHA-256。

## 严禁误动的数据

未经明确授权，不得删除、清空、覆盖、移动或提交：

- `config.ps1`、`config\`、`视频位置\`、`音频位置\`、`完成\`、`失败音频\`、`work\`、`logs\`、`backups\`、`banbenbeifen\`；
- `tools\paraformer\runtime`、`tools\paraformer\model_cache`、`tools\paraformer\downloads`；
- `fonts\UserAdded`、当前线上包/清单、更新器 `app.previous`、`Dedup-Core.psm1` 兼容壳。

## 常用验证命令

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-All.ps1
dotnet build .\desktop-src\AutoCutDesktop.csproj -c Release
git status --short
git log --oneline -4
```

涉及模型、字幕、长音频、GPU、更新器或发布时，必须额外做隔离真实运行或隔离升级，不可只凭测试通过或进程启动宣布完成。
