# 自动剪辑桌面版（混剪）

Windows 本地自动混剪程序：监控音频目录，使用本地 Paraformer 生成字幕，以 FFmpeg/NVENC（可回退）生成带字幕的视频。

**另一台电脑接手先读 [HANDOFF.md](HANDOFF.md)，再按 [docs/RELEASE-GUIDE.md](docs/RELEASE-GUIDE.md) 执行。**固定源码目录 `C:\AutoCut\hunjian`；先检查 C 盘，不足 25GB 停止；克隆后先报告交接测试/桌面构建，再恢复离线组件与本机配置。交接文档更新于 2026-11-01；Release 附带/ZIP 内的文档是历史快照，最新交接以仓库 `main` 为准。

当前 GitHub 候选版本为 **`v1.0.68-rc.1`**：它修复了 Paraformer 对末尾静音/无语音分段误报失败的问题，并以 GitHub Prerelease 提供源码、Windows x64 包、校验值和一键修复包。该候选**不会修改** OSS 下载站或线上更新清单；线上正式版本仍是 `1.0.67`。实际候选提交请以 [GitHub Release](https://github.com/nmrsz645-bit/hunjian/releases/tag/v1.0.68-rc.1) 的 tag target 为准。

## 交接范围

本 Git 仓库保存混剪业务程序的可维护源码、测试、文档和示例配置，以及 GitHub RC 构建器；生产外层更新器、OSS 制包器/上传器原始源码尚缺，不能声称生产工具链已完整。GitHub Release 附带可启动的 Windows x64 包，但任何来源都**不应**包含用户配置、音视频素材、成品、日志、工作区、密钥或 Paraformer 模型/运行时。Paraformer 本体体积大且机器相关，必须按下述方式恢复或初始化。

新电脑优先使用维护者提供的 Paraformer 离线包恢复运行时和模型，再执行 `Initialize-NewComputer.ps1 -SkipParaformer` 下载和校验其余运行依赖；它不会覆盖已有配置、模型或运行时。无法联网时，才从受控备份恢复以下目录到项目同名位置：

- `tools\paraformer\runtime`
- `tools\paraformer\model_cache`
- `tools\paraformer\downloads`
- `tools\ffmpeg`
- `tools\whisper`
- `tools\opencc`
- `tools\models`
- `fonts\UserAdded`（如用户选择过自定义字幕字体）

不要把这些目录或 `config.ps1` 提交到 Git；它们是机器或用户专属数据。

## 首次接手

1. 按指南完成空间检查、克隆、阅读、交接测试/构建并报告；再取得维护者提供、已核验 SHA-256 的 Paraformer 离线包，恢复到项目的 `tools\paraformer`。其中必须直接包含 `runtime`、`model_cache`、`downloads` 三目录。本机 `C:\软件\混剪所需插件` 是已解压的三目录来源，新电脑需单独取得组件。
2. 在项目根目录执行：

    `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Initialize-NewComputer.ps1 -SkipParaformer`

   该脚本创建本机 `config.ps1`、素材/输出目录，并下载 FFmpeg、Whisper、OpenCC、Whisper tiny 模型。所有下载都在解压前做 SHA-256 校验，已有目录不会覆盖。**当前脚本失败时仍清理普通依赖临时下载目录；按用户“保留失败下载”要求，接手者需先完成该留存缺口的最小修复/验证，再执行初始化。本次仅更新文档，未修改脚本。**
3. 如无离线包，可删除 `-SkipParaformer` 让脚本在线下载 Paraformer；该路径依赖 Python/PyTorch/模型上游网络，下载中断后应保留日志并由维护者处理，不能删除或覆盖已有模型目录。
4. 放入视频和音频后运行环境检查或 10 秒测试，再开始监控。`-CheckOnly` 会创建首次运行目录和本地版本备份，不是纯只读操作。

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Start-AutoCut.ps1 -CheckOnly
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Start-AutoCut.ps1 -Test
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Start-AutoCut.ps1 -Run
```

## Windows 包安装与日常使用

1. 从 GitHub Release 下载 `hun-jian-v1.0.68-rc.1-windows-x64.zip` 和同名 `.sha256`；解压到一个新目录，**不要覆盖正在运行的旧安装**。
2. 有 Paraformer 离线包时，先把包内的 `runtime`、`model_cache`、`downloads` 直接放入 `app\tools\paraformer`；在 `app` 中执行 `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Initialize-NewComputer.ps1 -SkipParaformer`，并先处理上文留存缺口。根目录 `Initialize-Dependencies.bat` 省略了 `-SkipParaformer`，不能把它当作离线恢复后的专用命令。
3. 初始化完成后双击根目录 `Start.cmd`。首次可先在 `app` 目录运行 `测试10秒.bat`；通过后双击 `管理界面.bat`，放入素材后点“开始监控”。
4. 视频/图片放到 `app\视频位置`，音频放到 `app\音频位置`，成品在 `app\完成`。配置在 `app\config.ps1`，由 `config.example.ps1` 初始化，切勿提交或外发。

常见问题：

- **Paraformer 批量识别提示空语音/无句级时间戳：**末尾极短或静音分段是正常输入。使用同一 Release 的 `hun-jian-paraformer-empty-speech-repair-1.0.68-rc.1.zip`：退出程序与监控，解压到程序目录外，双击 `DoubleClick-Repair.bat`，选择直接包含 `app` 的安装目录，然后运行 10 秒测试。它只替换两份源码并在 `app\backups` 留副本。
- **NVENC 初始化失败：**更新 NVIDIA 驱动，或在管理界面把编码器改为 `libx264`；这会变慢但不会影响字幕修复。
- **环境自检提示组件缺失：**保留已有 `runtime`、`model_cache`、`downloads` 和日志，不要清空后重试；按错误日志补齐对应组件或恢复离线包。
- **处理慢：**先看 NVIDIA GPU 是否被其他程序占用、是否回退到 `libx264`、字幕是否回退到 Whisper，以及素材是否在机械硬盘/网络盘。日志目录是 `app\logs`。

## 开发与验证

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-All.ps1
dotnet build .\desktop-src\AutoCutDesktop.csproj -c Release
```

完整接手入口见 [HANDOFF.md](HANDOFF.md)；按日期保留的进度、发布验证和已知限制见 [TIMEOFF.md](TIMEOFF.md) 顶部快照；发布更新的专门交接信息见 [UPDATER_HANDOFF.md](UPDATER_HANDOFF.md)。

新 Windows 电脑接手、GitHub 候选包、OSS 正式更新和下载站边界见 [docs/RELEASE-GUIDE.md](docs/RELEASE-GUIDE.md)。该指南明确区分 GitHub RC、OSS 正式版与网站卡片，`git push` 不等于客户端更新已发布。

## 当前重要决定

- 当前线上版本为 1.0.67；运行中的程序不自动下载、替换或重启，程序完全退出后才由启动入口检查更新。
- 更新发布必须保护配置、日志、素材、work、成品、失败音频及 Paraformer 的 `runtime`、`model_cache`、`downloads`。
- 长音频已通过 15 分钟真实隔离验收；但单一长素材在 `random` 取材且接近耗尽时可能因不重叠规则失败，详见 `TIMEOFF.md`。
