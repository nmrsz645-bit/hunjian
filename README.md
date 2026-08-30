# 自动剪辑桌面版（混剪）

Windows 本地自动混剪程序：监控音频目录，使用本地 Paraformer 生成字幕，以 FFmpeg/NVENC（可回退）生成带字幕的视频。

## 交接范围

本 Git 仓库只保存源码、测试、文档和示例配置。它**不是完整安装包**：不包含用户配置、音视频素材、成品、日志、工作区、发布包或 Paraformer/FFmpeg 二进制依赖。

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

1. 取得维护者提供、已核验 SHA-256 的 Paraformer 离线包，并解压到项目的 `tools\paraformer` 目录。离线包内必须直接包含 `runtime`、`model_cache`、`downloads` 三个目录。
2. 在项目根目录执行：

    `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Initialize-NewComputer.ps1 -SkipParaformer`

   该脚本创建本机 `config.ps1`、素材/输出目录，并下载 FFmpeg、Whisper、OpenCC、Whisper tiny 模型。所有下载都在解压前做 SHA-256 校验，已有目录不会覆盖。
3. 如无离线包，可删除 `-SkipParaformer` 让脚本在线下载 Paraformer；该路径依赖 Python/PyTorch/模型上游网络，下载中断后应保留日志并由维护者处理，不能删除或覆盖已有模型目录。
4. 放入视频和音频后运行环境检查或 10 秒测试，再开始监控。`-CheckOnly` 会创建首次运行目录和本地版本备份，不是纯只读操作。

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Start-AutoCut.ps1 -CheckOnly
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Start-AutoCut.ps1 -Test
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Start-AutoCut.ps1 -Run
```

## 开发与验证

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-All.ps1
dotnet build .\desktop-src\AutoCutDesktop.csproj -c Release
```

完整接手入口见 [HANDOFF.md](HANDOFF.md)；按日期保留的进度、发布验证和已知限制见 [TIMEOFF.md](TIMEOFF.md) 顶部快照；发布更新的专门交接信息见 [UPDATER_HANDOFF.md](UPDATER_HANDOFF.md)。

## 当前重要决定

- 当前线上版本为 1.0.67；运行中的程序不自动下载、替换或重启，程序完全退出后才由启动入口检查更新。
- 更新发布必须保护配置、日志、素材、work、成品、失败音频及 Paraformer 的 `runtime`、`model_cache`、`downloads`。
- 长音频已通过 15 分钟真实隔离验收；但单一长素材在 `random` 取材且接近耗尽时可能因不重叠规则失败，详见 `TIMEOFF.md`。
