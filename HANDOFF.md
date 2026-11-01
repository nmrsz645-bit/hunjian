# 自动剪辑桌面版（混剪）交接入口

交接更新日期：2026-11-01（北京时间）。新电脑固定源码/开发目录：`C:\AutoCut\hunjian`。
仓库：<https://github.com/nmrsz645-bit/hunjian>，默认分支 `main`。本文件说明当前状态，详细安装及上传命令见 [发布指南](docs/RELEASE-GUIDE.md)；历史记录见 `TIMEOFF.md`。

## 当前状态

- **已确认**：本轮文档整理前，本机与远端源码基准均为 `bca1be7970c7d9fca193b829246716ecdba33512`，工作树干净。本轮仅更新交接文档；交接完成后的准确提交以 `git rev-parse HEAD` 和远端回读为准。
- **已确认**：GitHub RC 为 [v1.0.68-rc.1](https://github.com/nmrsz645-bit/hunjian/releases/tag/v1.0.68-rc.1)，tag target 为 `97c5ba199c4f5063093cca66b1e66bebb3664445`。它修复 Paraformer 静音/无语音分段导致的批次失败。
- **已确认（2026-11-01 公网回读）**：OSS 正式版本仍是 `1.0.67`。GitHub RC、源码提交、OSS 更新、网站卡片是四项独立交付。
- **待补齐**：生产 `updater/UpdateAgent.exe` 的原始工程、生产外层 `Start.cmd`/`updater-config.json` 模板、OSS 完整/增量制包器及上传器源码。当前仓库不能独立重建生产更新链。
- **本轮范围**：文档交接及源码文档同步；未新发程序、升版本、激活客户端清单或运行真实媒体任务。

## 程序做什么、从哪里改

Windows 本地混剪：监控音频目录 → Paraformer 识别并生成字幕 → 随机选择视频/图片 → FFmpeg 渲染多个成品 → 验证后入完成目录；失败按队列策略保留、重试。

| 文件 | 职责 |
| --- | --- |
| `desktop-src/Program.cs` | .NET 8 Windows Forms 桌面界面、配置、日志、任务状态 |
| `AutoCut.ps1` | 取材、字幕、编码、补剪、超时、成品验证 |
| `Auto-Monitor.ps1` | 音频监控、队列、失败重试与安全清理 |
| `Start-AutoCut.ps1` | 检查环境、初始化运行目录、启动单次/测试任务 |
| `tools/paraformer/paraformer_worker.py` | ASR/VAD/标点模型、批次识别、GPU 异常回退、SRT/JSON |
| `Subtitle-Core.psm1` / `Subtitle-Aliyun.psm1` | 字幕时间轴/排版及可选云端路径 |
| `config.example.ps1` | 本机配置模板，UTF-8 BOM；真实 `config.ps1` 不进 Git |
| `Initialize-NewComputer.ps1` | 普通依赖下载校验；可选 Paraformer 在线初始化 |
| `tools/Build-GitHubRelease.ps1` / `repairs/` | GitHub RC 包及只替换两份源码的一键修复包 |
| `tests/Test-All.ps1` / `tests/Test-Handover.ps1` | 程序回归/交接文件检查 |

已有修复包括：长音频分块全局时间轴、单 worker 一次模型加载、GPU 不兼容/OOM 回退、识别与渲染超时、监控重试、TXT 安全删除、短任务防重入、长素材不重叠取材、空语音分段跳过。以源码和测试为准，不把 UI 展示文字 `V16.1.15` 当成发行版本号。

## 第一条操作

全新电脑先检查 C 盘可用空间，**少于 25GB 立即停止**；再准备 Git/.NET SDK 8，创建 `C:\AutoCut` 并克隆。完整顺序与命令见 [新电脑步骤](docs/RELEASE-GUIDE.md#新-windows-电脑接手)。

已有源码时先核对，不直接拉取覆盖：
```powershell
Set-Location '<你的克隆目录>'
# 本项目约定目录为 C:\AutoCut\hunjian
git status --short --branch
git remote -v
git rev-parse HEAD
```
状态非空就保留修改并确认来源；干净时才 `git pull --ff-only origin main`。不要 reset、强制切换、清空后重来。
阅读顺序：`README.md` → 本文件 → `TIMEOFF.md` 顶部 → `AGENTS.md` → `config.example.ps1`；安装/发布再读对应指南章节。

## 新电脑接手与运行

1. 克隆后先运行交接测试、桌面构建，并报告结果，随后再恢复依赖。源码测试通过不代表 Paraformer/GPU 已可用。
2. 优先使用受控 Paraformer 离线组件。原机实际目录 `C:\软件\混剪所需插件` 直接包含 `runtime`、`model_cache`、`downloads`；它不是 TAR 文件。新电脑需另行取得组件，不能假定原机路径存在。
3. 历史 TAR 为 `Paraformer_离线运行组件_20260831.tar`；用户曾给出的下载路径在本机本轮核对不存在。实际包路径、层级与 SHA-256 均须核实，详见指南。组件不在 GitHub 源码/RC ZIP 中。
4. 恢复后必须直接有 `C:\AutoCut\hunjian\tools\paraformer\runtime\python.exe` 与 `model_cache\models\...`；不允许再套一层文件夹。已有三个保护目录时停止并核查，不能覆盖。
5. 普通依赖命令为：
```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Initialize-NewComputer.ps1 -SkipParaformer
```
**当前限制**：引导脚本的 `finally` 会清理普通依赖临时下载目录，即使失败也如此；若继续新机安装，应先按用户要求解决并验证失败留存，再执行。不能声称现版本已满足“失败保留全部下载”。本轮未修改该行为。
6. 检查 Python、三个非空 `model.pt`、FFmpeg/Whisper/OpenCC；再在受控目录执行一次模型预热和 10 秒测试，查看成片、时长、音轨与字幕。指南列出命令及证据要求。
7. 本机 `config.ps1` 从模板生成，路径全部使用 C 盘。用户素材、输出路径、显卡/编码器、并发数、字幕样式需本机确认；离线字幕无需云端 Key，云端 Key 只能由用户本机重新填写。

## 已完成验证

以下为已保留证据，不等于本轮重新执行全部测试：
- RC：`tests/Test-All.ps1` 20 项通过；桌面 Release 构建 0 警告、0 错误；候选 ZIP/独立修复 ZIP 审计通过。
- RC 主包：107,048,510 字节，SHA-256 `5B15CCEB5B468318720A1A00C6E72F3785DA0A65B9A04427D978A900E1DC60B3`。
- 修复包：31,373 字节，SHA-256 `3D449611E92893FE57ADB9961D7B2BA8DAD007CD55D0514AB4274CE6E37BBCED`。
- 文档整理前基准提交的 [GitHub CI](https://github.com/nmrsz645-bit/hunjian/actions/runs/41198232240) 已通过；该 CI 仅检查交接、PowerShell 解析、桌面构建。
- **未验证**：RC 在全新机器上带完整模型、GPU/NVENC 和真实音视频的端到端运行。
- 历史 2026-08-31 曾生成 905 秒 H.264/AAC 成片、检查字幕及模型缓存 31 文件哈希；该历史验收不能代替 RC 验收，原机 D/E 盘证据不能假定在新机存在。
- 本轮文档整理的检查结果以交付回复和对应提交 CI 为准，不把历史通过记录写成本轮重跑。

## 已知边界

- `Start-AutoCut.ps1 -CheckOnly` 会创建运行目录/版本备份并执行维护逻辑，不是纯只读。
- 监控重试间隔为 5/20/60 分钟、最多 3 次；最终失败进入 `失败音频`，不能拿重试次数当处理速度。
- NVENC 可用检测不等于实际编码成功；驱动不兼容可能报 `cuInit(0) failed`，回退 `libx264` 会增加 CPU 压力。
- Paraformer GPU 不兼容或 OOM 可回退 CPU；日志中的音频拆分 `speed=...` 不是整条视频的处理速度。先区分字幕、取材、渲染阶段，再定位性能。
- 长素材随机取材接近耗尽仍可能因不重叠规则失败；不可因此删除原素材或取消保护。
- 上述初始化失败留存缺口，以及生产更新链缺源，均为后续事项；不能写“所有问题已修完”。

## 严禁误动的数据

保留原件；不删除、覆盖、清空、移动或提交：
- `config.ps1`、`config/`、`视频位置/`、`音频位置/`、`完成/`、`失败音频/`、`work/`、`logs/`、`backups/`、`banbenbeifen/`、`fonts/UserAdded/`。
- `tools/paraformer/runtime`、`tools/paraformer/model_cache`、`tools/paraformer/downloads`。
- 发布对象、线上清单、`app.previous*`、`app.failed-*`、`Dedup-Core.psm1` 兼容壳；实际清单还保护其他媒体/状态路径，见指南。
- Key/token/cookie、浏览器登录态、真实环境文件和业务数据。公有仓库禁止上传私有全项目索引或本机跨项目入口。

## 常用验证命令

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-Handover.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-All.ps1
dotnet build .\desktop-src\AutoCutDesktop.csproj -c Release
git status --short
```
仅文档改动做交接检查即可；修改程序按 `AGENTS.md` 执行完整回归，媒体或更新器变更另需隔离真实验收。

## 上传更新从哪里开始

详见 [docs/RELEASE-GUIDE.md](docs/RELEASE-GUIDE.md)：
- 源码/文档：审查指定文件 → commit → 普通 push → 核对远端提交与 CI。
- GitHub RC：新版本、指定提交构建/包审计 → annotated tag → prerelease → ZIP/修复包/校验值回读。现有 RC 附件保持不变。
- OSS 正式更新：补齐生产原始工具 → 完整包/app 更新包 → 真实旧外层配置隔离升级/回滚 → 上传不可变包并下载验哈希 → 最后切 `latest.json` → 单项目 catalog → 回读。
- 网站：独立仓库及实际卡片配置；不可把 catalog 或源码 push 当网站已更新。
生产工具和授权凭据缺失时停在对应阶段并说明缺项；不能用候选 `Start.cmd` 或其他程序更新器冒充。

## 给另一台电脑 Codex 的接手提示

> 接手仓库 https://github.com/nmrsz645-bit/hunjian.git，固定目录 C:\AutoCut\hunjian。先检查 C 盘，少于25GB停止。按 README、HANDOFF、TIMEOFF 顶部、AGENTS 和 docs/RELEASE-GUIDE.md 接手，先报告 Git 状态、交接测试与桌面构建。Paraformer 组件另行恢复，不覆盖 runtime/model_cache/downloads；初始化前先核对失败留存缺口。正式版1.0.67与GitHub RC 1.0.68-rc.1分开说明。仅在收到对应授权后发布；保留用户数据和日志，不改线上清单或网站。最后报告实际提交、每项验证、缺项和待手动配置事项。
