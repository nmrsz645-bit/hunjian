# 自动剪辑桌面版开发约定

## 先读

开始工作前阅读 `README.md`、`TIMEOFF.md`、`config.example.ps1` 和 Git 状态。`TIMEOFF.md` 是当前进度、发布状态与已知问题的交接依据。

## 不可触碰的用户数据

未经用户明确授权，不得删除、清空、覆盖或移动：

- `config.ps1`、`config\`、`视频位置\`、`音频位置\`、`完成\`、`失败音频\`、`work\`、`logs\`、`backups\`、`banbenbeifen\`；
- `tools\paraformer\runtime`、`tools\paraformer\model_cache`、`tools\paraformer\downloads`；
- `fonts\UserAdded` 中的用户字体；
- 已发布包、线上清单、`app.previous` 和 `Dedup-Core.psm1` 兼容壳。

默认在隔离目录执行真实音频/视频验证，主目录不作为测试输出位置。

## 修改与测试

- 只做用户请求范围内的最小改动；不因顺手而改模型、并发、编码、更新器或用户配置。
- PowerShell 源码使用 Windows PowerShell 5.1 语法验证；桌面端用 `dotnet build desktop-src\AutoCutDesktop.csproj -c Release`。
- 完成代码修改至少运行 `tests\Test-All.ps1`；涉及媒体流程时还要做隔离真实成片、ffprobe、字幕文件和模型哈希验证。

## 发布规则

- 发布仅从本目录当前已验证源码构建；更新包递归排除所有受保护目录。
- 发布前必须执行真实旧版到新版的隔离升级、`app.previous`、保护数据逐文件 SHA-256、失败回滚验证和公网对象回读。
- 包先上传并回读 SHA-256，最后才激活 `latest.json` / catalog。
- 运行中禁止自动更新；只能在程序完全退出后由用户启动入口检查更新。
