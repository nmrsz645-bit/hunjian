# 自动剪辑桌面版：新电脑、GitHub 与生产发布指南

本指南是本项目的操作边界，不是发布授权。它以当前仓库源码、已上线对象和下载站仓库的只读核对为依据；任何生产 OSS、客户端清单或网站变更仍须获得单独授权。

## 当前发布关系

| 渠道 | 当前已知版本 | 作用 | 不要误判为 |
| --- | --- | --- | --- |
| GitHub `main` | 以 `git rev-parse origin/main` 为准 | 完整可维护源码、测试与文档 | 已推送给所有客户端 |
| GitHub Release `v1.0.68-rc.1` | 候选版本 | Windows x64 启动包、空语音修复包和校验值 | OSS 正式更新或模型离线全量包 |
| OSS 生产 | `1.0.67` | 已安装客户端更新清单和完整下载包 | 包含 GitHub RC 的空语音修复 |

`git push`、GitHub Release、OSS 客户端更新清单和下载站卡片是四件独立的事。本仓库的 `.github/workflows/source-check.yml` 只执行源码交接检查、PowerShell 解析和 .NET 构建，权限为 `contents: read`，不会上传 OSS 或部署网站。

## 新 Windows 电脑接手

### 获取准确源码

```powershell
git clone https://github.com/nmrsz645-bit/hunjian.git C:\AutoCut\hunjian
Set-Location C:\AutoCut\hunjian
git switch main
git pull --ff-only origin main
git status --short
git rev-parse HEAD
```

若要复核 GitHub 候选而不是生产 OSS，另行读取 tag：

```powershell
git fetch --tags origin
git rev-list -n 1 v1.0.68-rc.1
```

不要在工作树非空时执行 reset、checkout 覆盖或清理命令；先保存并确认改动来源。

### 依赖、目录与初始化

- 运行环境：Windows 10/11 x64、Windows PowerShell 5.1、系统 `curl.exe`；开发/构建还需 .NET SDK 8.x 和 Git。
- `Initialize-NewComputer.ps1` 当前固定校验并下载：FFmpeg 8.1.2 essentials、whisper.cpp `b4938` 的 x64 包、OpenCC 1.4.2、Whisper `ggml-tiny.bin`。
- Paraformer 在线初始化使用 Python 3.10.11 embedded；RTX 50 系列/计算能力 10 或 12 使用 PyTorch/Torchaudio 2.7.1+cu128，其他路径使用 2.6.0+cu124；随后安装 FunASR 1.4.1、ModelScope 1.39.1、soundfile 0.14.0。
- GitHub 包和源码仓库都不含 `tools\paraformer\runtime`、`model_cache`、`downloads`。这三个目录和模型是外部运行时，不能称为“离线模型已齐”。优先恢复经核验的 Paraformer 离线包，目录层级必须直接为 `tools\paraformer\runtime`、`model_cache`、`downloads`。

已有离线 Paraformer 时：

```powershell
Set-Location C:\AutoCut\hunjian
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Initialize-NewComputer.ps1 -SkipParaformer
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Start-AutoCut.ps1 -CheckOnly
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Start-AutoCut.ps1 -Test
```

没有离线包时去掉 `-SkipParaformer`，保留中断下载和 `logs\paraformer_setup.log`，不要删除不完整的运行时后盲目重试。正常使用时，视频/图片放入 `视频位置`，音频放入 `音频位置`，先通过 10 秒测试，再从 `管理界面.bat` 启动监控。

可迁移的是受控 Paraformer 离线包以及普通依赖缓存；不得迁移、提交或打进发布物的是 `config.ps1`、`config\`、素材、`work`、`logs`、`完成`、`失败音频`、`backups`、`banbenbeifen`、`fonts\UserAdded` 和任何浏览器登录态。`config\aliyun-key.dat` 使用 Windows DPAPI `CurrentUser` 加密，换电脑或换用户无法可靠解密，必须由使用者在新电脑的字幕设置界面重新输入；它不是可分发配置。

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

只有在包审计、敏感信息检查和用户授权均完成后，才可创建新的 prerelease。先确认待推送内容仅为预期源码/文档：

```powershell
git status --short
git diff --cached --check
git diff --cached --name-only
git push origin main
```

可用 GitHub CLI 上传候选附件；下例会创建 GitHub Release，**不是** OSS 发布命令，运行前必须有新的发布授权：

```powershell
gh release create "v<候选版本>" `
  "<完整ZIP路径>" "<修复ZIP路径>" "<SHA256文件路径>" `
  --repo nmrsz645-bit/hunjian --prerelease --title "AutoCut <候选版本>" --notes "GitHub-only prerelease"
```

发布后回读 tag 指向的提交、Release 是否为 prerelease、三个附件的 HTTP 200/长度/SHA-256。GitHub `v1.0.68-rc.1` 与 OSS `1.0.67` 必须分开报告。

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

完整哈希请在发布前后用 `Get-FileHash` 或对象 metadata 回读，不要从本文截断值复制。当前 `latest.json` 的 `preservePaths` 包含配置、用户媒体/日志/work、备份、用户字体和 Paraformer `runtime`、`model_cache`、`downloads`；新清单不得缩减这些保护项。

### 实际机制与缺项

- `AutoUpdate.ps1` 明确禁用运行中自动更新。桌面 EXE 仅在安装根目录同时存在 `Start.cmd` 与 `updater\updater-config.json` 时才转交给启动入口；本仓库没有 `updater\`、`UpdateAgent` 源码、生产 `Start.cmd` 或生产完整/增量打包器。
- 因此，当前仓库可以构建 GitHub 候选包，**不能仅靠现有源码安全重建或发布 OSS 生产更新包**。不要把 GitHub 打包脚本、候选 `version.json` 或 `git push` 当作客户端更新发布。
- 本仓库也没有可验证的 OSS 上传脚本、AccessKey 环境变量名或 CLI 配置。缺少这些信息时，不能猜测 bucket 写入命令或凭据名称。

### 获授权后的受控人工顺序

以下是顺序，不是本轮已执行命令：

1. 在隔离目录从已验证源码构建完整包和 app-only 更新包；审计 ZIP，排除受保护目录和秘密。
2. 记录版本、提交、文件名、字节数、SHA-256；上传到新的不可变版本 key，绝不覆盖旧包。
3. 从公网重新下载/HEAD 每个新包，核对长度与 SHA-256。
4. 使用真实旧安装的外层旧 `updater-config.json` 做隔离升级，确认 `app.previous`、配置、三套 Paraformer 数据和失败回滚；此项目历史上发生过旧保护规则导致模型丢失，不能跳过。
5. 仅在上述步骤完成后，由获授权的 OSS 操作者最后更新 `updates/hun-jian/latest.json`；先保留旧 JSON 的可恢复副本，再按新版本更新 `version`、`url`、`sha256`、`files`、`notes`，并保留完整 `preservePaths`。
6. 如适用再更新外部 `catalog.json` 与 `downloads/catalog.json` 的唯一 `id: hun-jian` 记录，最后做公网回读。

只读核对示例（不上传、不改清单）：

```powershell
Invoke-WebRequest -Method Head -UseBasicParsing 'https://luotuoruanjiangengx.oss-cn-beijing.aliyuncs.com/updates/hun-jian/latest.json'
Invoke-RestMethod 'https://luotuoruanjiangengx.oss-cn-beijing.aliyuncs.com/updates/hun-jian/latest.json'
Invoke-WebRequest -Method Head -UseBasicParsing 'https://luotuoruanjiangengx.oss-cn-beijing.aliyuncs.com/packages/hun-jian-1.0.67.zip'
```

## 下载站与网站发布

共享网站的通用接手指南在 [software-download-center 的 PUBLISHING.md](https://github.com/nmrsz645-bit/software-download-center/blob/docs-cross-pc-handoff/docs/PUBLISHING.md#website)，对应锚点还有 [catalog](https://github.com/nmrsz645-bit/software-download-center/blob/docs-cross-pc-handoff/docs/PUBLISHING.md#catalog)、[client-update](https://github.com/nmrsz645-bit/software-download-center/blob/docs-cross-pc-handoff/docs/PUBLISHING.md#client-update)、[verify-rollback](https://github.com/nmrsz645-bit/software-download-center/blob/docs-cross-pc-handoff/docs/PUBLISHING.md#verify-rollback)、[credentials](https://github.com/nmrsz645-bit/software-download-center/blob/docs-cross-pc-handoff/docs/PUBLISHING.md#credentials)。

本项目的实际差异如下：

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
- 当前源码缺少生产更新器、`updater-config.json`、生产 `Start.cmd`、完整/增量 OSS 打包器和 OSS 上传器源码；补齐这些前不能声称可从本仓库独立完成正式发布。
- GitHub `v1.0.68-rc.1` 未重新执行带完整 Paraformer 模型、GPU/NVENC 和真实媒体的全新机端到端验收；它不能称为稳定正式版。
