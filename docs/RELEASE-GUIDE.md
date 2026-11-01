# 自动剪辑桌面版：新电脑、GitHub 与生产发布指南

交接更新：2026-11-01（北京时间）；源码文档整理前基准为 `bca1be7970c7d9fca193b829246716ecdba33512`。下文命令供接手后按阶段执行，本轮没有安装、重新构建或发布程序。

本指南是本项目的操作边界，不是发布授权。它以当前仓库源码、已上线对象和下载站仓库的只读核对为依据；任何生产 OSS、客户端清单或网站变更仍须获得单独授权。

## 当前发布关系

| 渠道 | 当前已知版本 | 作用 | 不要误判为 |
| --- | --- | --- | --- |
| GitHub `main` | 以 `git rev-parse origin/main` 为准 | 完整可维护源码、测试与文档 | 已推送给所有客户端 |
| GitHub Release `v1.0.68-rc.1` | 候选版本 | Windows x64 启动包、空语音修复包和校验值 | OSS 正式更新或模型离线全量包 |
| OSS 生产 | `1.0.67` | 已安装客户端更新清单和完整下载包 | 包含 GitHub RC 的空语音修复 |

`git push`、GitHub Release、OSS 客户端更新清单和下载站卡片是四件独立的事。本仓库的 `.github/workflows/source-check.yml` 只执行源码交接检查、PowerShell 解析和 .NET 构建，权限为 `contents: read`，不会上传 OSS 或部署网站。

## 新 Windows 电脑接手

### 1. 先检查空间，再准备开发工具

只使用 C 盘。先执行：
```powershell
$free = (Get-PSDrive -Name C).Free
if ($null -eq $free) { throw '无法读取 C 盘空间，停止安装' }
'C 盘可用：{0:N2} GiB' -f ($free / 1GB)
if ($free -lt 25GB) { throw 'C 盘不足 25GB，停止安装并报告' }
```
这里按 PowerShell `25GB`（25 GiB）保守检查。离线包、解压、构建和成品都会继续占空间，不能把 25GB 当成全流程空间保证。

开发需要 [Git for Windows](https://git-scm.com/install/windows) 和 [.NET SDK 8 x64](https://dotnet.microsoft.com/en-us/download/dotnet/8.0)；不要只安装 .NET Runtime。Windows 10/11 x64 自带 Windows PowerShell 5.1；还需系统 `curl.exe`、`tar.exe`。缺失时从上述官方入口安装，安装后重开终端，检查 `git --version`、`dotnet --list-sdks` 和 `powershell.exe -NoProfile -Command '$PSVersionTable.PSVersion'`。本项目不要求全局 Python、Node.js 或 npm，Paraformer 使用便携 Python。

### 2. 创建目录、克隆、阅读文件

仅在全新目标目录执行：
```powershell
New-Item -ItemType Directory -Path C:\AutoCut -Force | Out-Null
if (Test-Path -LiteralPath C:\AutoCut\hunjian) { throw '目标已存在，先核查 Git 和用户数据，禁止覆盖克隆' }
git clone https://github.com/nmrsz645-bit/hunjian.git C:\AutoCut\hunjian
if ($LASTEXITCODE -ne 0) { throw '克隆失败；保留现场并报告' }
Set-Location C:\AutoCut\hunjian
git status --short --branch
git remote -v
git rev-parse HEAD
```
按 `README.md`、`HANDOFF.md`、`TIMEOFF.md` 顶部、`AGENTS.md`、`config.example.ps1` 顺序阅读。已有克隆先检查状态；干净时才 `git pull --ff-only origin main`，不盲目切换分支或覆盖修改。
核对候选提交可执行 `git fetch --tags origin` 与 `git rev-list -n 1 v1.0.68-rc.1`，不必切换工作树。

### 3. 先做交接测试和桌面构建，并报告

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-Handover.ps1
if ($LASTEXITCODE -ne 0) { throw '交接测试失败，报告后处理' }
dotnet build .\desktop-src\AutoCutDesktop.csproj -c Release
if ($LASTEXITCODE -ne 0) { throw '桌面构建失败，报告后处理' }
```
先报告源码路径、HEAD、Git 状态、测试及构建结果，再做以下恢复。测试不要求下载模型；通过不等于模型/媒体端到端通过。

### 4. 恢复 Paraformer 离线组件

本机已确认 `C:\软件\混剪所需插件` 是**已解压的目录**，直接含 `runtime`、`model_cache`、`downloads`，不是 TAR 路径；新电脑要由维护者单独提供这些组件。
用户最初给出的 `C:\Users\Public\Downloads\Paraformer\_离线运行组件\_20260831.tar` 在本机 2026-11-01 核对不存在。以新电脑实际收到的文件为准，勿假定旧路径有效或扫描整盘寻找。

若收到原始 `Paraformer_离线运行组件_20260831.tar`，历史记录为 7,683,095,552 字节，SHA-256：
`9568A560A361077816123856D15289B817F7C5A40CD833F24F9F77601CA699B3`。
这是历史原包基准，不能冒充本轮已重新计算。不同包先核实其受控来源、清单和哈希，不能忽略不匹配强行使用。

TAR 路径恢复示例（先把变量改为实际存在的包）：
```powershell
$offline = 'C:\Users\Public\Downloads\Paraformer\_离线运行组件\_20260831.tar'
Get-Item -LiteralPath $offline | Select-Object FullName,Length
Get-FileHash -LiteralPath $offline -Algorithm SHA256
$entries = @(& tar.exe -tf $offline)
if ($LASTEXITCODE -ne 0) { throw 'TAR 清单读取失败' }
$entries | Select-Object -First 12
```
人工/程序检查完整清单：只能恢复 `runtime/`、`model_cache/`、`downloads/`，不得有绝对路径、`..` 逃逸、异常链接或用户数据。若有外层 `Paraformer/_离线运行组件/`，先确认前缀，按已核实层数剥离到隔离目录再复制；不猜测 `--strip-components` 数值。下面仅适用于三个目录位于归档根的包：
```powershell
$dest = 'C:\AutoCut\hunjian\tools\paraformer'
foreach ($name in @('runtime','model_cache','downloads')) {
    if (Test-Path -LiteralPath (Join-Path $dest $name)) { throw "已有保护目录，停止恢复：$name" }
}
New-Item -ItemType Directory -Path $dest -Force | Out-Null
& tar.exe -xf $offline -C $dest
if ($LASTEXITCODE -ne 0) { throw '解压失败，保留已解压文件和原包，停止' }
```
若提供的是已解压文件夹，则核对源与目标不同、三个源目录完整且目标三目录均不存在，再逐个复制（不得使用 `-Force` 覆盖）：
```powershell
$componentSource = 'C:\软件\混剪所需插件'
$dest = 'C:\AutoCut\hunjian\tools\paraformer'
foreach ($name in @('runtime','model_cache','downloads')) {
    if (-not (Test-Path -LiteralPath (Join-Path $componentSource $name) -PathType Container)) { throw "源目录缺失：$name" }
    if (Test-Path -LiteralPath (Join-Path $dest $name)) { throw "目标已存在，停止：$name" }
}
foreach ($name in @('runtime','model_cache','downloads')) {
    Copy-Item -LiteralPath (Join-Path $componentSource $name) -Destination (Join-Path $dest $name) -Recurse -ErrorAction Stop
}
```
最终必须直接存在 `tools\paraformer\runtime\python.exe` 和 `tools\paraformer\model_cache\models`，不能多套一层文件夹。保留原包、源目录及复制中断现场。

### 5. 初始化普通依赖与本机配置

固定普通依赖：FFmpeg 8.1.2 essentials、whisper.cpp `b4938`、OpenCC 1.4.2、Whisper `ggml-tiny.bin`；URL 和 SHA-256 以 `Initialize-NewComputer.ps1` 为准，不手工跳过校验。
Paraformer 备用在线安装使用 Python 3.10.11 embedded；PyTorch/Torchaudio 为 2.7.1+cu128（RTX50/计算能力10或12）或 2.6.0+cu124，FunASR 1.4.1、ModelScope 1.39.1、soundfile 0.14.0。离线包实际版本以便携 Python 查询为准。

**待处理缺口**：当前 `Initialize-NewComputer.ps1` 的 `finally` 无条件删除自身 `hunjian_bootstrap_*` 临时目录，普通依赖下载失败后也会清理。它保护已有 Paraformer 三目录，但尚不满足“任何失败都保留已下载文件”。后续 Codex 应先完成并验证最小失败留存修复，再按用户要求执行初始化；不得在文档中虚报已修复。不要删除用户目录来绕开不完整依赖检测。

上述缺口处理后，在项目根执行：
```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Initialize-NewComputer.ps1 -SkipParaformer
```
保存完整终端输出/退出码；在线 Paraformer 下载日志为 `logs\paraformer_setup.log`。已有组件或配置保持不覆盖。
已恢复离线包时**不要双击**会省略 `-SkipParaformer` 的 `Initialize-Dependencies.bat`，应在 `app`（安装 ZIP）或项目根（源码）运行上述命令。
无离线包时，在线初始化仍是需要网络和新机验收的备用方案，不在本交接中默认执行。

`config.ps1` 从 UTF-8 BOM 的 `config.example.ps1` 复制/生成。默认使用 `$PSScriptRoot` 拼接 C 盘素材、输出、work 和模型路径；不得复用旧 D/E 盘路径或提交真实配置。
可迁移受控依赖；不通过公有 Git 迁移配置/素材/日志/工作队列/成品/密钥/用户字体或登录态。用户原件保留本机。
`config\aliyun-key.dat` 使用 DPAPI `CurrentUser`，换机须用户在字幕设置重新输入；本地 Paraformer 无需该 Key。

### 6. 验证依赖能运行，再做本地测试

文件存在/非空检查：
```powershell
$root = 'C:\AutoCut\hunjian'
$required = @(
 'tools\paraformer\runtime\python.exe',
 'tools\paraformer\model_cache\models\iic--speech_seaco_paraformer_large_asr_nat-zh-cn-16k-common-vocab8404-pytorch\snapshots\master\model.pt',
 'tools\paraformer\model_cache\models\iic--speech_fsmn_vad_zh-cn-16k-common-pytorch\snapshots\master\model.pt',
 'tools\paraformer\model_cache\models\iic--punc_ct-transformer_cn-en-common-vocab471067-large\snapshots\master\model.pt',
 'tools\ffmpeg\bin\ffmpeg.exe','tools\whisper\whisper-cli.exe',
 'tools\models\ggml-tiny.bin','tools\opencc\bin\opencc.exe',
 'tools\opencc\share\opencc\t2s.json'
)
foreach ($relative in $required) {
    $file = Get-Item -LiteralPath (Join-Path $root $relative) -ErrorAction Stop
    if ($file.Length -le 0) { throw "空文件：$relative" }
    $file | Select-Object FullName,Length
}
.\tools\paraformer\runtime\python.exe -c "import sys,torch,funasr,modelscope,soundfile; print(sys.version); print('torch',torch.__version__,'cuda',torch.version.cuda,'available',torch.cuda.is_available())"
.\tools\ffmpeg\bin\ffmpeg.exe -version
.\tools\whisper\whisper-cli.exe --help
.\tools\opencc\bin\opencc.exe --help
```
分别记录每条退出码/输出。CUDA available=false 不等于组件损坏，但可能导致 CPU 识别变慢；不要仅凭 `nvidia-smi` 或 help 成功宣称真实任务通过。

真正加载离线三模型（会占 CPU/GPU，单独运行一次，不对每条音频重复预热）：
```powershell
$priorCache = $env:MODELSCOPE_CACHE
try {
    $env:MODELSCOPE_CACHE = Join-Path $root 'tools\paraformer\model_cache'
    & .\tools\paraformer\runtime\python.exe .\tools\paraformer\paraformer_worker.py --warmup
    if ($LASTEXITCODE -ne 0) { throw '离线模型加载失败；保留日志并报告' }
} finally { $env:MODELSCOPE_CACHE = $priorCache }
```
有明确授权的测试视频和可听懂的人声音频时，再运行：
```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Start-AutoCut.ps1 -CheckOnly
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Start-AutoCut.ps1 -Test
```
`-CheckOnly` 会写运行目录/备份并维护旧日志；`-Test` 不是纯只读。全新机器可在空素材目录中只放测试副本；若已有真实任务，先用独立安装/输出配置隔离，勿把测试投入真实监控队列。无测试素材就报告“待验证”，不启动监控或用静音音调冒充人声识别通过。

验收记录：输入及成片路径、执行日志、SRT/JSON、ffprobe 时长/视频音频流、字幕与人声同步、编码器/设备、模型哈希前后对比；另测“人声后接静音”不应整批失败。仅退出码0或 help 有输出不够。
日常视频/图片放 `视频位置`、音频放 `音频位置`、成品在 `完成`；通过测试后才按用户要求开始监控。
最终报告实际安装路径/提交、交接测试/构建、每个组件/三个模型、真实测试结果、未验证项和待用户配置项。

### 新机仍需用户或接手 Codex 确认

- Paraformer 受控组件从哪里取得、包/文件清单与哈希；GitHub RC 不提供约7GB离线模型包。
- 视频/图片、音频和成品目录的 C 盘路径及可用空间；没有业务素材时只用测试副本，不自动投入监控。
- NVIDIA 型号/驱动、PyTorch/CUDA 是否实际兼容、NVENC 真实编码是否成功；CPU 回退可用但会影响速度。
- 模板默认 `VideosPerAudio=6`、`ParallelRenders=6`，不同电脑负载差别大；先测单任务再决定本机并发，不能仅凭显卡型号断言性能。
- 字幕样式/字体、横竖屏及输出分辨率；仅需要云端字幕时，由用户本机输入 Key 并确认 Endpoint，离线 Paraformer 不需要云端 Key。
- 发布者的 GitHub/OSS 权限和缺失生产源码来源；这些不能随公开文档移交账号凭据。

### 出错或处理慢时保留哪些证据

保留失败时间对应的 `logs/run_*.log`、`logs/monitor_*.log`、`banbenbeifen/logs/launcher_*.log`，以及失败任务 `work/<任务>/paraformer_batch.log` 或 `paraformer.log`、`paraformer_batch_manifest.json`、SRT/JSON；文件名以错误中实际路径为准。批次退出码1只是外层结果，需看 worker 日志最后的异常/traceback；界面把 FFmpeg stderr 标作“错误”也不代表进程失败。

这些日志只在本机/受控渠道诊断，分享前排除 Key、个人路径和业务内容，不提交公开仓库。不清空 work、队列、日志或模型来“重试”。比较快慢需同音频/素材/参数，按字幕/取材/渲染分别计时，并记录 CPU、显卡型号/驱动、实际编码器、CPU回退/OOM日志、并发和磁盘类型；单张 GPU 占用图或 FFmpeg 音频拆分 speed 不能证明整条性能瓶颈。

## 本地开发、测试与打包

```powershell
Set-Location C:\AutoCut\hunjian
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-All.ps1
dotnet build .\desktop-src\AutoCutDesktop.csproj -c Release
```

GitHub 候选包由实际存在的 `tools\Build-GitHubRelease.ps1` 构建。该脚本的 `-Version` 参数是 GitHub 候选包文件名和生成的 `app\version.json` 的版本来源；当前源码没有一个可安全直接修改的“OSS 正式版本号”文件。

```powershell
$out = 'C:\AutoCut\release-artifacts\candidate-1.0.68-rc.1'
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Build-GitHubRelease.ps1 -OutputDirectory $out -Version '1.0.68-rc.1'
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-GitHubReleasePackage.ps1 `
  -ArchivePath "$out\hun-jian-v1.0.68-rc.1-windows-x64.zip" `
  -ChecksumPath "$out\hun-jian-v1.0.68-rc.1-windows-x64.sha256" `
  -RepairPath "$out\hun-jian-paraformer-empty-speech-repair-1.0.68-rc.1.zip"
```

脚本拒绝覆盖同名输出，并生成完整 ZIP、独立空语音修复 ZIP 和 SHA-256 文件。它排除个人配置、素材、日志和 Paraformer 三个大型运行时目录。候选包是“初始化后可运行”的 Windows 包，不是包含 7GB 模型的离线全量包。

## GitHub 候选发布

源码/文档上传使用普通 Git 提交。先确认 `origin` 是本项目、分支是预期维护分支；逐文件检查后显式暂存，禁止 `git add .`。例如只更新交接文档时：

```powershell
git diff -- README.md HANDOFF.md TIMEOFF.md UPDATER_HANDOFF.md docs/RELEASE-GUIDE.md
git add -- README.md HANDOFF.md TIMEOFF.md UPDATER_HANDOFF.md docs/RELEASE-GUIDE.md
git diff --cached --check
git diff --cached --name-only
git commit -m "docs: refresh cross-computer handoff"
git push origin main
git ls-remote origin refs/heads/main
```

维护程序时将暂存清单换为实际安全代码/测试文件，并先完成 `AGENTS.md` 要求的验证；不要把新机配置、模型或诊断日志加入提交。推送拒绝时先读远端差异，不能 force push 或覆盖他人改动。推送后核对本地 HEAD 与远端相同、对应 GitHub Actions 通过；这只证明源码文档同步，不激活客户端更新。

只有在包审计、敏感信息检查和用户授权均完成后，才可创建新的 prerelease。先确认待推送内容仅为预期源码/文档：

```powershell
git status --short
git diff --cached --check
git diff --cached --name-only
git push origin main
```

使用 GitHub CLI（新电脑先从 [官方仓库](https://github.com/cli/cli#installation) 安装并执行 `gh auth login`）。已有 RC 资产不用重复上传；新候选必须使用新的用户确认版本，禁止覆盖原 tag/同名附件。

以下模板中的占位符须先替换为实际已审计值；`<已验证源码提交>` 必须是制作 ZIP 时的源码 HEAD，不能默认取当时可能已变化的分支头。先确认 tag 不存在，再执行：

```powershell
git tag -a "v<候选版本>" "<已验证源码提交>" -m "AutoCut <候选版本> prerelease"
git push origin "refs/tags/v<候选版本>"
gh release create "v<候选版本>" `
  "<完整ZIP路径>" "<修复ZIP路径>" "<SHA256文件路径>" `
  --repo nmrsz645-bit/hunjian --verify-tag --prerelease --title "AutoCut <候选版本>" --notes-file "<已审查的发行说明文件>"
```

发行说明需写明修复内容、来源提交、依赖/模型不随包提供、实测范围与 OSS 正式版本仍未切换。构建器的 `app/version.json.sourceCommit` 必须和 tag target 一致，且构建前工作树干净；有未提交代码时该字段不足以证明真实来源。

发布后回读 tag 指向的提交、Release 是否为 prerelease、三个附件的 HTTP 200/长度/SHA-256。GitHub `v1.0.68-rc.1` 与 OSS `1.0.67` 必须分开报告。

## 本机可恢复工具链复核（2026-10-31）

应分开处理 GitHub 候选包与 OSS 生产更新，不能把两者合称为“全部工具缺失”：

- **已有且可恢复的候选制包链**：`desktop-src/AutoCutDesktop.csproj`、`desktop-src/Program.cs` 和 `tools/Build-GitHubRelease.ps1`。后者实际调用 .NET 8 `dotnet publish`，生成候选根 `Start.cmd`、`Initialize-Dependencies.bat`、`app/version.json`、完整 ZIP、SHA-256 及 Paraformer 修复 ZIP。这些生成器、初始化与修复脚本均有源码；不是只能复制历史二进制。
- **已有运行依赖**：本机原源码目录 `C:\AutoCut\hunjian` 已核对 .NET SDK 8.0.425、PowerShell 5.1、FFmpeg、Whisper、OpenCC、Paraformer 便携 Python 与三套模型；依赖版本及迁移限制见本指南前文。本轮仅复用此前候选构建与 20 项测试记录，没有再次构建、加载模型或处理真实媒体。
- **源码确实尚缺的生产链**：生成生产 `updater/UpdateAgent.exe` 的原始工程及构建输入（源文件的实际原名未确认）、生产 `updater/updater-config.json` 与外层 `Start.cmd` 的可审计模板/生成器、OSS 完整包/增量 `app.zip` 制包器及其 manifest/上传实现。当前候选生成的 `Start.cmd` 是隔离候选入口，不能冒充生产旧客户端入口。`AutoUpdate.ps1` 只是禁用运行中更新的告知脚本，不是外层生产更新器。
- **本轮核对范围**：当前仓库全部受控脚本与工程文件、`C:\AutoCut` 下已有发布/修复目录，以及“更新”项目中已授权相关候选/工具目录。跨项目目录仅发现混剪 catalog 条目，没有找到可恢复的混剪生产工程；已打包候选、其他程序的更新器及合成 manifest 均不作替代。

候选完整包可以按上文真实脚本继续隔离构建；从该仓库独立重建生产更新器、制作并验收新的 OSS 增量更新仍缺上述原始输入。下一步需要相应自有源码仓库、分支或工具目录，不能通过重写同名实现补齐来源。

## OSS 正式更新

### 已核对的生产对象

当前可访问的对象位于 `luotuoruanjiangengx.oss-cn-beijing.aliyuncs.com`（从域名可推断 bucket 为 `luotuoruanjiangengx`、区域端点为 `oss-cn-beijing`；实际写入权限和凭据来源不在本仓库）：

| 用途 | 当前 key/URL 模式 | 当前 1.0.67 状态 |
| --- | --- | --- |
| 增量更新包 | `updates/hun-jian/<版本>/app.zip` | `updates/hun-jian/1.0.67/app.zip`，SHA-256 `FFFDC8A...3A897A` |
| 客户端清单 | `updates/hun-jian/latest.json` | 字段为 `notes`、`version`、`files`、`url`、`sha256`、`preservePaths` |
| 完整包 | `packages/hun-jian-<版本>.zip` | `packages/hun-jian-1.0.67.zip`，SHA-256 `C767BB...471E4D` |
| 下载兼容完整包 | `downloads/packages/hun-jian-<版本>.zip` | 与完整包同字节/哈希 |
| 外部目录记录 | `catalog.json`、`downloads/catalog.json` | 卡片 `id: hun-jian`，字段 `name`、`description`、`version`、`visible`、`downloadUrl` |

2026-11-01 回读：更新包 SHA-256 为 `FFFDC8A339BFDCD5667C65D546A75709097B5550CF0C63A4CB5796D8373A897A`；完整包为 `C767BB4774F63E00CC9C73F4A0EC721D0EDC225E57E124481DC229A130471E4D`，1,076,595,534 字节。前者来自当前清单，后者来自对象 metadata；本轮没有重新下载约 1GB 完整包验算。发布验收必须下载后 `Get-FileHash`，HEAD/metadata/ETag 不能代替文件实算。当前 `latest.json` 的 `preservePaths` 包含配置、用户媒体/日志/work、备份、用户字体和 Paraformer `runtime`、`model_cache`、`downloads`；新清单不得缩减这些保护项。

### 实际机制与缺项

- `AutoUpdate.ps1` 明确禁用运行中自动更新。桌面 EXE 仅在安装根目录同时存在 `Start.cmd` 与 `updater\updater-config.json` 时才转交给启动入口；本仓库没有 `updater\`、`UpdateAgent` 源码、生产 `Start.cmd` 或生产完整/增量打包器。
- 因此，当前仓库可以构建 GitHub 候选包，**不能仅靠现有源码安全重建或发布 OSS 生产更新包**。不要把 GitHub 打包脚本、候选 `version.json` 或 `git push` 当作客户端更新发布。
- 本仓库也没有可验证的 OSS 上传脚本、AccessKey 环境变量名或 CLI 配置。缺少这些信息时，不能猜测 bucket 写入命令或凭据名称。

### 获授权后的受控人工顺序

以下是顺序，不是本轮已执行命令：

1. 在隔离目录从已验证源码构建完整包和 app-only 更新包；审计 ZIP，排除受保护目录和秘密。
2. 记录版本、提交、文件名、字节数、SHA-256；上传到新的不可变版本 key，绝不覆盖旧包。
3. 先 HEAD 核对状态/长度，再从公网重新下载每个新包实算 SHA-256；仅 HEAD 不足以验哈希。
4. 使用真实旧安装的外层旧 `updater-config.json` 做隔离升级，确认 `app.previous`、配置、三套 Paraformer 数据和失败回滚；此项目历史上发生过旧保护规则导致模型丢失，不能跳过。
5. 仅在上述步骤完成后，由获授权的 OSS 操作者最后更新 `updates/hun-jian/latest.json`；先保留旧 JSON 的可恢复副本，再按新版本更新 `version`、`url`、`sha256`、`files`、`notes`，并保留完整 `preservePaths`。
6. 如适用再更新外部 `catalog.json` 与 `downloads/catalog.json` 的唯一 `id: hun-jian` 记录，最后做公网回读。

只读核对示例（不上传、不改清单）：

```powershell
Invoke-WebRequest -Method Head -UseBasicParsing 'https://luotuoruanjiangengx.oss-cn-beijing.aliyuncs.com/updates/hun-jian/latest.json'
Invoke-RestMethod 'https://luotuoruanjiangengx.oss-cn-beijing.aliyuncs.com/updates/hun-jian/latest.json'
Invoke-WebRequest -Method Head -UseBasicParsing 'https://luotuoruanjiangengx.oss-cn-beijing.aliyuncs.com/packages/hun-jian-1.0.67.zip'
```

### 真正上传时用什么入口、改哪些对象

当前仓库没有可恢复的生产上传 CLI/配置，**不要杜撰一键发布命令**。生产工具补齐、包来源与隔离升级验收完成并获授权后，可由获授权操作者使用 [OSS 控制台](https://oss.console.aliyun.com/) 上传（[官方对象操作说明](https://www.alibabacloud.com/help/en/oss/user-guide/console-quick-start)）：

1. 在控制台核对账号及现有 bucket `luotuoruanjiangengx`、北京地域；打开“文件列表/对象”，不要创建同名新 bucket 或改变桶/对象 ACL。
2. 先下载并保存当前 `updates/hun-jian/latest.json`、两个 catalog、旧客户端外层配置及对应包校验信息到受控发布记录目录（不提交公开仓库）。核对新版本严格高于正式版，且新版本 key 不存在。
3. 将**已审计的生产 app 更新 ZIP**上传为 `updates/hun-jian/<新版本>/app.zip`。上传**生产完整安装 ZIP**到 `packages/hun-jian-<新版本>.zip` 及 `downloads/packages/hun-jian-<新版本>.zip`。前两种 ZIP 布局不同，候选 ZIP 不可改名代替。三个对象必须是新 key，保留旧版本。
4. 分别从公开 HTTPS URL 下载到新的验收目录，核对字节数及文件实算 SHA-256。权限/缓存异常先解决，不切换清单。若设置自定义 sha256 元数据，它只辅助审计，不能代替下载校验。
5. 在保留旧 JSON 的前提下编辑**该项目** `latest.json`：更新版本、更新包 URL/哈希、说明及 `files`（若存在则按真实生产工具语义生成，不能猜测结构）；完整保留 `preservePaths`。本地先 `Get-Content -Raw <清单路径> | ConvertFrom-Json` 检查，再上传到精确 key `updates/hun-jian/latest.json`，这是客户端激活点。
6. 两个 catalog 只修改唯一 `id=hun-jian` 条目的版本和完整包 `downloadUrl` 等必要字段，保留其他程序条目及可见性。确认唯一匹配后上传原 key。与协调发布者核对最新远端内容，防止用旧整表覆盖别人更新。
7. 回读清单/catalog/实际下载，并用未手工修补外层配置的旧安装副本真实升级和回滚；报告运行中不替换、不丢模型/配置/媒体，退出后启动入口能更新。网站如需显示新版，另按下节处理。

旧客户端依赖安装根已有的 `updater/updater-config.json` 保护规则，历史版本不一定读取清单中的 `preservePaths`；仅在清单添加保护项不能证明老用户模型安全。完整包、升级桥接、外层保护配置必须一起验收。

截至本次回读，`latest.json` 的保护项为：
`config.ps1`、`config`、`视频位置`、`音频位置`、`完成`、`失败音频`、`work`、`logs`、`backups`、`banbenbeifen`、`fonts/UserAdded`、`tools/paraformer/runtime`、`tools/paraformer/model_cache`、`tools/paraformer/downloads`、`.video_auto_cache`、`watch-failure-state.json`、`视频封面`、`音乐位置`、`贴纸素材`、`素材`。发布时以最新真实清单/旧外层配置的并集为下限重新核对。

## 下载站与网站发布

共享网站的通用接手指南在 [software-download-center 的 PUBLISHING.md](https://github.com/nmrsz645-bit/software-download-center/blob/docs-cross-pc-handoff/docs/PUBLISHING.md#website)，对应锚点还有 [catalog](https://github.com/nmrsz645-bit/software-download-center/blob/docs-cross-pc-handoff/docs/PUBLISHING.md#catalog)、[client-update](https://github.com/nmrsz645-bit/software-download-center/blob/docs-cross-pc-handoff/docs/PUBLISHING.md#client-update)、[verify-rollback](https://github.com/nmrsz645-bit/software-download-center/blob/docs-cross-pc-handoff/docs/PUBLISHING.md#verify-rollback)、[credentials](https://github.com/nmrsz645-bit/software-download-center/blob/docs-cross-pc-handoff/docs/PUBLISHING.md#credentials)。

下述网站差异为 2026-10-31 只读核对记录，之后可能变化；发布前须重新读取网站 main、部署来源和实际页面，不按旧记录直接改卡片：

- 只读核对到该网站仓库的 `index.html` 没有 `hun-jian`/`混剪` 卡片或 `updates/hun-jian` 运行时文件；仓库内 `updates/` 当前只有火花矩阵数据。不能假设推送本项目或改 OSS catalog 会刷新网站。
- 外部 OSS `catalog.json` 和 `downloads/catalog.json` 虽有 `id: hun-jian` 卡片记录，但当前网站 `index.html` 不读取公共 catalog；它们不能代替实际网站卡片配置。
- 共享网站的 Pages 来源是 `main`；该仓库的 `docs-cross-pc-handoff` 分支只用于文档，推送该分支不部署网页。本轮不写该仓库，也不合并或推送其 `main`。
- 将来若网站新增混剪卡片，先在当时的 `index.html` 定位卡片 ID、静态链接或专属加载器，再只修改实际读取字段；卡片显示版本、完整 ZIP URL、下载后哈希和客户端 `latest.json` 是分别验证的四项。

## 验证、回滚与凭据

发布后至少保留：构建提交、版本、两类 ZIP 的长度/哈希、`latest.json` 内容、catalog 中唯一记录、网页实际下载链接、隔离升级的 `app.previous` 与回滚证据。GitHub 候选还应记录 Release URL、tag target 和 prerelease 标记。

生产失败而尚未切换 `latest.json` 时，停止在该阶段并保留旧入口；不要删除新旧不可变 ZIP 或用户安装数据。已经切换清单时，只有在旧包可下载、旧 JSON 已保存、隔离回滚已验证且获得授权时，才恢复该项目自己的旧清单/卡片记录。网页卡片回滚不能替代客户端清单回滚。

## 凭据与安全

- GitHub：使用现有浏览器/`gh auth login` 的受控凭据即可完成本仓库正常推送和 Release 操作；不要提交 token、SSH 私钥、Credential Manager 文件、Cookie 或浏览器 profile。
- OSS：本项目源码未提供经过验证的写入凭据配置名。只能通过拥有 `luotuoruanjiangengx` 对应 key/prefix 最小写入与 HEAD/读取权限的获授权运营者、控制台或短期凭据执行；不要借用其他项目的环境变量、脚本或权限。
- 阿里云字幕：`Subtitle-Settings.ps1` 调用 `Save-AliyunApiKey`，将密钥保存为当前 Windows 用户可解密的 `config\aliyun-key.dat`。它不是 OSS 发布凭据，也不能随配置、压缩包或迁移资料分发。

## 未验证或缺失项

- 本轮未执行 OSS 上传、`latest.json`/catalog 写入、下载站发布、客户端升级或回滚；本文的生产流程仅为受控操作串。
- 当前源码缺少生产更新器工程、生产 `updater-config.json`/`Start.cmd` 模板、完整/增量 OSS 打包器和上传器源码；未确认原工程真实文件名。已检查范围见工具链复核节，不代表全盘证明不存在；拿到真实工具仓库后再核对来源，不重写同名程序充数。
- 初始化脚本在普通依赖下载失败时仍清理自己的临时目录，失败留存要求尚需最小修复与验证，见新机步骤5。
- GitHub `v1.0.68-rc.1` 未重新执行带完整 Paraformer 模型、GPU/NVENC 和真实媒体的全新机端到端验收；它不能称为稳定正式版。
