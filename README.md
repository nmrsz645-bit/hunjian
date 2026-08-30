# 自动剪辑桌面版（混剪）

Windows 本地自动混剪程序：监控音频目录，使用本地 Paraformer 生成字幕，以 FFmpeg/NVENC（可回退）生成带字幕的视频。

## 交接范围

本 Git 仓库只保存源码、测试、文档和示例配置。它**不包含**用户配置、音视频素材、成品、日志、工作区、发布包或 Paraformer/FFmpeg 二进制依赖。

新电脑需要从受控备份单独复制以下目录到项目同名位置，或按部署流程重新安装：

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

1. 克隆仓库并复制 `config.example.ps1` 为 `config.ps1`。
2. 恢复上列运行依赖；在字幕设置中执行本地检测。
3. 按需建立 `视频位置`、`音频位置`、`完成`、`work` 目录。
4. 运行环境检查或 10 秒测试，再开始监控。

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

完整交接状态、已发布版本、发布验证和已知限制以 [TIMEOFF.md](TIMEOFF.md) 为准；发布更新的专门交接信息见 [UPDATER_HANDOFF.md](UPDATER_HANDOFF.md)。

## 当前重要决定

- 当前线上版本为 1.0.67；运行中的程序不自动下载、替换或重启，程序完全退出后才由启动入口检查更新。
- 更新发布必须保护配置、日志、素材、work、成品、失败音频及 Paraformer 的 `runtime`、`model_cache`、`downloads`。
- 长音频已通过 15 分钟真实隔离验收；但单一长素材在 `random` 取材且接近耗尽时可能因不重叠规则失败，详见 `TIMEOFF.md`。
