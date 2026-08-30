# 自动剪辑桌面版交接（历史记录保留）

> **新会话先读：**以本节和根目录 [HANDOFF.md](HANDOFF.md) 为当前交接依据；下方内容是按日期保留的历史发布、故障和验证记录。不得把较早的“当前结论”或“下一步”当作当前任务。

## 当前交接快照（2026-08-31）

### 当前目标

- 当前代码已完成稳定性和新电脑交接验证；**不要继续修改程序、不要创建发布包、不要上传线上清单或通知更新程序**，除非用户另行明确授权。
- 下一个会话的工作应从用户的新请求开始；若用户要求发布，先重新核对线上版本、发布源、完整包、保护目录、隔离升级和回滚，不能依据本文历史版本号直接发布。

### 下一步（第一条可直接操作）

```powershell
Set-Location 'E:\自动化\混剪\自动剪辑桌面版_V16'
git status --short
git pull --ff-only
Get-Content .\HANDOFF.md -Encoding UTF8
```

若是另一台电脑，先克隆 `https://github.com/nmrsz645-bit/hunjian.git`，再按 `HANDOFF.md` 恢复运行依赖；源码仓库不是完整安装包。

### 已完成并验证

- Git 远端 `main` 与本地一致，提交：`d36da04a98d385172edfda74411aa013d11d7c44`；工作区干净。
- `tests\Test-All.ps1`：20 项通过；`dotnet build .\desktop-src\AutoCutDesktop.csproj -c Release`：0 警告、0 错误。
- 新电脑交接：远端全新克隆通过 `tests\Test-Handover.ps1` 与桌面构建；`config.example.ps1` 为 UTF-8 BOM，且 `WhisperModel` 指向 `tools\models\ggml-tiny.bin`。
- 真实隔离运行：15 分 05 秒 MP3 + 唯一 15 分 10 秒 MP4，Paraformer-large、NVENC、随机不重叠取材，成功输出 905 秒 H.264/AAC 成片；模型缓存 31 个文件 SHA-256 前后无差异。证据目录：`D:\ui\temp\hun_jian_long_source_stability_20260831`。
- 已修复：TXT 删除顺序、渲染任务总超时、重复短任务、长素材随机碎片化；新增 GitHub 源码检查工作流。

### 未完成事项与已知问题

- **无待处理代码缺陷。**新电脑必须从受控备份恢复 FFmpeg、Whisper、OpenCC、Paraformer runtime/模型；这些目录按设计不进 Git。
- `Start-AutoCut.ps1 -CheckOnly` 会创建首次运行目录和本地备份，不是纯只读检查。
- GitHub Actions 已写入源码；当前会话只做本地和远端克隆验证，若后续需要把 Actions 结果作为发布证据，应在 GitHub Actions 页面确认对应提交通过。
- 线上发布版本的旧历史记录存在 1.0.63/1.0.64/1.0.67 等日期条目；任何发布前必须公网回读，不能直接采信历史章节。

### 关键文件、命令与保护边界

- 总交接：`HANDOFF.md`；开发约定：`AGENTS.md`；源码接手：`README.md`；发布/更新器：`UPDATER_HANDOFF.md`。
- 核心：`AutoCut.ps1`、`Auto-Monitor.ps1`、`desktop-src\Program.cs`；测试：`tests\Test-All.ps1`、`tests\Test-Handover.ps1`。
- 验证命令：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-All.ps1
dotnet build .\desktop-src\AutoCutDesktop.csproj -c Release
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Start-AutoCut.ps1 -CheckOnly
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Start-AutoCut.ps1 -Test
```

- 未经明确授权，绝不能删除、覆盖、移动或提交：`config.ps1`、`config\`、`视频位置\`、`音频位置\`、`完成\`、`失败音频\`、`work\`、`logs\`、`backups\`、`banbenbeifen\`、`fonts\UserAdded\`、`tools\paraformer\runtime`、`model_cache`、`downloads`，以及线上包、清单、`app.previous`。

## 2026-08-23：已验证、待发布的长音频字幕时间轴修复

- 用户已确认此前 60 秒分段真实成片的字幕与音频同步；正式源码已采用同一策略：长于 60 秒的本地 Paraformer 识别按 60 秒块、1 秒交叠拆分，交叠处按全局时间线裁剪后合并，避免单次长音频识别的累计时间漂移。
- 为避免 22 段音频重复加载模型，`paraformer_worker.py` 新增 `--batch-manifest`：整条长音频所有块在一个 Python worker、一次模型加载中依次识别。短音频与 10 秒测试仍使用原单音频入口。
- Paraformer 本地字幕缓存版本已加入 `timeline_chunks_v1` 与块参数；升级后旧的长音频缓存不会被误复用，会自动重新生成。
- 真实正式代码验证输入：`D:\微信\xwechat_files\wxid_32z8m49rhak022_786c\msg\file\2026-08\她闻不到爱的味道.mp3`（1268.232 秒）。输出：`D:\ui\temp\hun_jian_formal_timeline_validation_20260823\subtitles.srt`，792 条事件，首条 0.230 秒、末条 1267.845 秒、越界 0、重叠 0；批量 worker 的日志与 22 段原始结果同目录。
- 验证：Windows PowerShell 的 `tests\Test-All.ps1` 19 项全通过；`desktop-src\AutoCutDesktop.csproj -c Release` 为 0 警告、0 错误；真实两段批量 worker 21.129 秒成功生成 2 份 SRT/JSON。修改前副本：`banbenbeifen\source_before_paraformer_timeline_chunks_20260823_155756`。
- 发布尚未激活：已通知更新会话执行严格高版本发布、历史配置隔离升级和“运行中自动检查→仅在空闲时关闭本程序→安装→自动重启”验收。不得将 `tools\paraformer\runtime`、`model_cache`、`downloads` 放入更新包或覆盖用户已有文件。

## 当前结论

- 主源码：`E:\自动化\混剪\自动剪辑桌面版_V16`
- 发布源：`E:\自动化\混剪\自动剪辑桌面版_V16_发布版`
- 当前公网版本：**1.0.63**。1.0.60 已确认存在老用户升级后 Paraformer 模型消失的问题；1.0.61 为拒绝候选；1.0.62 存在部分运行时复制后可能误判完整的问题，均不得重新激活。
- 更新包与完整包本身不包含 `tools\paraformer\runtime`、`model_cache`、`downloads`，但这不足以保护老用户：更新器实际读取安装目录外层既有的 `updater\updater-config.json`，不会读取清单中的 `preservePaths`。
- 老安装目录的外层配置没有 Paraformer 三个保护路径；更新只替换 `app`，而 `Start-App.cmd` 只升级 `UpdateAgent.exe`、不升级外层配置。因此老用户仍按旧保护规则替换 `app`，模型被留在 `app.previous`，新 `app` 中丢失。
- 此前 1.0.59→1.0.60 验证使用了已手工写入新保护路径的测试配置，未覆盖真实长期升级用户的旧外层配置，结论无效。后续必须从 1.0.45 等历史完整包原样升级验证，禁止预先修改其 updater 配置。
- 1.0.63 在应用启动前运行修复桥接：校验并替换外层更新器、原子补写三项 Paraformer 保护路径，并只从 `app.previous*` / `app.failed-*` 恢复当前目录中缺失的文件，不覆盖用户当前已有文件。
- 1.0.63 增加持久化“恢复未完成/恢复已验证”标记及关键 Python、PyTorch、FunASR 文件校验；磁盘满、断电或复制中断后，下次启动会继续补缺失文件，成功前不会误报完整。
- 已用原始旧更新器模拟 1.0.60 当前三目录为空、完整模型只在 1.0.45 `app.previous`：直升 1.0.63 后自动恢复，17/17 用户数据与模型匹配，真实 Paraformer 识别成功，回滚后 17/17 仍匹配。
- 本轮目标已经完成：生产剪辑不再在每条音频识别前额外执行一次 Paraformer 全模型预热；一条音频只启动一次识别 worker、生成一份字幕。

## 本轮问题与根因

原生产流程在每条音频上会执行两次完整模型加载：

1. `Ensure-ParaformerRuntime` 调用 `Test-ParaformerRuntimeReady`，以 `--warmup` 启动一次 worker，完整加载 ASR、VAD、标点三个模型；
2. 随后的 `Invoke-ParaformerSrt` 再启动一次 worker，重新加载同样三个模型并正式识别。

第一遍不是字幕识别，只是“证明模型能加载”，因此每条音频都重复消耗约几十秒。用户实际日志中，一次多余预热约耗时 22 秒；不同机器可能更久。

## 已完成的代码修改

### `AutoCut.ps1`

1. `Test-ParaformerRuntimeReady` 改为轻量检查，只验证：
   - `tools\paraformer\runtime\python.exe` 存在；
   - ASR、VAD、标点三个 `model.pt` 存在且不是 0 字节。
2. 生产流程不再执行 `--warmup`，因此每条音频只由 `Invoke-ParaformerSrt` 启动一次真实识别 worker。
3. 如果运行时/模型缺失，执行安装脚本后会再次检查全部组件，而不只是检查 `python.exe`。
4. 增加同机并发保护：命名互斥锁 `Local\HunJian_Paraformer` 保证同一时间只有一个 Paraformer 识别进程，避免两个请求同时抢 GPU/内存。排队请求不会被重复执行。
5. 增加识别超时：默认 `max(300 秒, 音频时长 × 2 + 120 秒)`；超时只终止本次启动的 Python 进程，并保留 `paraformer.log`。
6. 修复 Windows PowerShell 非阻塞 `Start-Process` 读取退出码为空的问题：启动后立即保留进程句柄，结束后刷新进程对象再读取退出码。
7. 失败异常现在包含退出码；标准输出/错误仍合并进原有诊断日志。

### 保留的行为

- 字幕设置窗口里的手动“本地检测/下载组件”仍保留完整 `--warmup`。用户主动点检测时，仍会真实加载模型确认可用。
- 字幕缓存逻辑未改变；已有有效字幕缓存仍直接复用。
- 每条音频仍只生成一份 SRT，随后供该音频生成的所有视频复用。

## 修改文件

| 文件 | 作用 |
| --- | --- |
| `AutoCut.ps1` | 去掉生产重复预热；增加互斥、超时、可靠退出码与异常信息 |
| `tests\Test-Paraformer-Offline.ps1` | 断言生产流程无预热、手动检测仍有预热，并检查互斥与超时保护 |
| `tests\Test-Paraformer-SingleLoad.ps1` | 新增单次启动、空/缺失组件、超时、真实双请求并发串行回归 |
| `tests\Test-All.ps1` | 纳入新专项测试 |
| `TIMEOFF.md` | 更新本交接状态 |

修改前备份：

`E:\自动化\混剪\自动剪辑桌面版_V16\banbenbeifen\source_before_paraformer_single_load_20260821_061043`

## 验证结果

### 静态、回归与构建

- `AutoCut.ps1`、新增/修改测试脚本：PowerShell AST 语法检查通过。
- `tests\Test-All.ps1`：**16 项全部通过**。
- 新专项测试证明：
  - `python.exe` 缺失或 `model.pt` 为 0 字节时拒绝启动；
  - 一次音频请求只启动一次 worker；
  - 两个并发请求各执行一次，但 worker 不重叠；
  - 目标 SRT 被独占锁定时明确失败，并在日志保留 `PermissionError`；
  - 1 秒强制超时能终止进程，并保留诊断日志；
  - 中文/空格路径和普通 stderr `[INFO]` 不再误报失败。
- `dotnet build desktop-src\AutoCutDesktop.csproj -c Release`：**0 警告、0 错误**。

### 真实 Paraformer

真实输入：

`work\real_parafomer_validation\paraformer_real_20260817_175201.mp3`（10 秒）

冷启动直接调用当前生产封装：

- 成功产生 376 字节 SRT 和 5,254 字节 JSON；
- 耗时 **45.733 秒**；
- 识别文本和时间戳正常；
- 证据目录：`work\validation_paraformer_single_load_20260821`。

### 真实完整成片

在隔离目录 `D:\ui\temp\hun_jian_single_load_video_validation_20260821` 运行当前 `AutoCut.ps1 -TestMode`，工具目录只读链接到主源码的完整 Paraformer/FFmpeg，配置、输出、日志、备份和 work 均留在隔离目录。

- 06:22:37 开始真实 Paraformer；06:22:59 开始生成视频；06:23:00 成片完成；整轮约 **24 秒**。
- NVENC 实际编码速度约 **18.3×**。
- 输出：`完成\《paraformer_real_20260817_175201》\paraformer_real_20260817_175201_测试10秒.mp4`。
- ffprobe：10.000 秒、H.264、AAC、1080×1920、30 fps、1,541,303 字节。
- 已抽取第 5 秒画面人工检查，字幕正确烧录，无空字幕或渲染中断。

## 模型与用户数据保护核对

当前三个模型仍完整存在：

| 模型 | 字节 | SHA-256 |
| --- | ---: | --- |
| Paraformer ASR | 989,763,045 | `3D491689244EC5DFBF9170EF3827C358AA10F1F20E42A7C59E15E688647946D1` |
| FSMN VAD | 1,721,366 | `B3BE75BE477F0780277F3BAE0FE489F48718F585F3A6E45D7DD1FBB1A4255FC5` |
| CT-Transformer 标点 | 1,125,507,622 | `7176CAE922A872E130E6B88AEF9A1153581711BAF79C9124C7C95BE383CD6F81` |

本轮没有改动主源码中的：

- `config.ps1`（最后修改时间仍为 2026-08-16 17:10:20）；
- `config\`、`视频位置\`、`音频位置\`、原 `完成\`、`失败音频\`；
- 原 `logs\`、`backups\`；
- `tools\paraformer\runtime` 和 `tools\paraformer\model_cache`；
- 主源码中原有用户配置、素材、日志、成片和 Paraformer 模型文件。

主源码只新增真实识别证据目录 `work\validation_paraformer_single_load_20260821`；真实完整成片放在隔离目录，不计入当日正式完成统计。

## 1.0.60 发布事实与事故历史

发布日期：2026-08-21。

- 更新包：`https://luotuoruanjiangengx.oss-cn-beijing.aliyuncs.com/updates/hun-jian/1.0.60/app.zip`
  - 字节：978,134,047
  - SHA-256：`AB067F91B1104EAA7D631932E32ECD7F0E6F1DEEB8330F865BF674B574162AB6`
- 完整包：`https://luotuoruanjiangengx.oss-cn-beijing.aliyuncs.com/packages/hun-jian-1.0.60.zip`
  - 字节：978,150,053
  - SHA-256：`D35EAE54CBA1C20B298B824F1E3CC5C80497D4B5982B37D379B7DA645B37AE4F`
- 兼容完整包地址：`https://luotuoruanjiangengx.oss-cn-beijing.aliyuncs.com/downloads/packages/hun-jian-1.0.60.zip`，长度与 SHA-256 相同。
- 发布当时公网 `latest.json`、OSS 根目录 `catalog.json` 和下载站 `downloads/catalog.json` 均回读为 **1.0.60**；当前三个入口均已更新为 1.0.62。
- 更新包、根目录完整包和下载站完整包三个对象均返回 HTTP 200，长度及 `x-oss-meta-sha256` 与本地候选一致。
- 更新包共 163 个文件，完整包共 167 个文件；受保护用户数据泄漏数为 0，`runtime`、`model_cache`、`downloads` 条目数为 0。
- 清单继续显式保留 `tools\paraformer\runtime`、`tools\paraformer\model_cache`、`tools\paraformer\downloads`。
- 公网更新包重新下载并直接审计后，`AutoCut.ps1` SHA-256 为 `57764CA357DCB670E58B6DB3DFDA639216C16D788F96AF03DF3AC6CB9E7B3C40`，与发布源一致。

### 已失效的升级与回滚验证结论

- 当时使用 1.0.59 客户端升级到 1.0.60，13 项用户配置/数据和 4 个真实 Paraformer 文件逐项校验为 **17/17 SHA-256 不变**。
- 4 个真实 Paraformer 文件包含运行时 `python.exe` 和 ASR、VAD、标点三个 `model.pt`，合计校验 2,117,095,225 字节。
- 升级后 `app.previous` 正常保留 1.0.59，其中同一批 17 项内容也全部不变。
- 从 1.0.60 回滚到 1.0.59 通过，回滚后 17/17 哈希仍完全一致。
- 更新器执行升级是异步的；自动验证必须等待“版本已变为目标版本并且 `app.previous` 已生成”，不得使用固定等待 8 秒作为成功或失败依据。
- **上述结论不能代表真实老用户。** 验证脚本预先把 1.0.59 隔离目录的外层 `updater-config.json` 改成了带 Paraformer 保护路径的新配置；真实从 1.0.45 等旧版本连续升级的用户仍保留旧外层配置，因此实际发生模型丢失。
- 真实用户截图显示 `app\tools\paraformer\downloads` 仅约 8.22 MB；结合更新机制和旧配置，已确认是升级链缺陷，不是用户电脑异常。

## 1.0.62 首次修复与遗留缺陷

发布日期：2026-08-21。

### 更新器修复

- 正式更新器源：`E:\自动化\gengxin\windows-updater-source`。
- `UpdateCore.cs` 开始解析并校验清单 `preservePaths`，拒绝绝对路径及目录穿越。
- `UpdateAgent.cs` 将外层旧配置与清单保护路径合并后再替换应用，并用合并结果做安装后校验。
- `HunJianUpdaterRepair.exe` 使用同机互斥锁，校验随包携带的 `UpdateAgent.next.exe` SHA-256 后更新外层更新器；随后原子补写外层配置。
- 恢复逻辑扫描 `app.previous*` 和 `app.failed-*`，只恢复当前 `runtime`、`model_cache`、`downloads` 中缺失的文件，不覆盖已有模型；长路径使用 `robocopy`。但该版以“至少 40,000 个运行时文件”作为完整条件，后来确认过于宽松。
- `Start-App.cmd` 在启动桌面程序前静默执行修复桥接，因此已受影响用户更新到 1.0.62 后可自动从保留的旧应用目录恢复。

### 验证结果

- 更新器 Core、事务、Agent、修复器测试全部通过；覆盖空值、重复执行、并发互斥、目录穿越、无可恢复源、长路径、只补缺失文件及不覆盖现有文件。
- 发布源 `tests\Test-All.ps1`：**16/16 通过**；桌面程序 Release 构建：**0 警告、0 错误**。
- 1.0.62 ZIP 审计：更新包 167 个条目，受保护数据泄漏 0，重复条目 0，且不含用户 `runtime`、`model_cache`、`downloads`。
- 原样 1.0.45 历史安装升级：测试前外层配置 SHA-256 为 `09AD25285C28471970DE0284CD1F28A0E47FFB8D058A17EC0C23CF2F9A20D06E`，仅 12 项保护路径；升级后版本为 1.0.62，三项 Paraformer 保护路径自动写入。
- 17 项配置、数据、日志、素材、运行时及三个真实模型：升级后当前 `app` **17/17 匹配**，`app.previous` **17/17 匹配**。
- 恢复后的运行时为 43,863 个文件、5,448,198,133 字节；真实调用恢复后的 Python 与三个模型，成功生成 376 字节 SRT 和 5,254 字节 JSON，stderr 为空。
- 真实启动升级后的 `自动剪辑.exe` 成功；随后执行 1.0.62→1.0.45 回滚，回滚后 17/17 哈希匹配，1.0.62 保留在失败版本目录。
- 1.0.62 剪辑核心 `AutoCut.ps1` SHA-256 为 `57764CA357DCB670E58B6DB3DFDA639216C16D788F96AF03DF3AC6CB9E7B3C40`，与本轮已真实生成 10 秒视频并通过 ffprobe/画面检查的源码完全一致。

### 公网对象

- 更新包：`https://luotuoruanjiangengx.oss-cn-beijing.aliyuncs.com/updates/hun-jian/1.0.62/app.zip`
  - 字节：978,142,255
  - SHA-256：`9AC3FBF497FC196EA63882DA94E87C0387F06A41C6691B024076B9D72918315C`
- 完整包：`https://luotuoruanjiangengx.oss-cn-beijing.aliyuncs.com/packages/hun-jian-1.0.62.zip`
  - 字节：978,158,808
  - SHA-256：`8225E14AB261D3D90F147AA4A634830F5122E9FD9170099304F2F22E62782017`
- 恢复包：`https://luotuoruanjiangengx.oss-cn-beijing.aliyuncs.com/repairs/hun-jian/hun-jian-updater-repair-1.0.2.zip`
  - 字节：21,570
  - SHA-256：`DD6C4BBABFD919C45D42B1F36D42704E1DD7D8DFF125E69EBF80BFBD646B7E84`
- 1.0.62 发布后补测触发磁盘满：首次只复制 40,937/43,863 个运行时文件（3,542,045,292/5,448,198,133 字节），再次启动却因 40,000 门槛误判完整。发现后立即把主 `latest.json` 暂停为 0.0.0；1.0.62 历史包未覆盖，但不得再激活。

## 1.0.63 最终修复、验证与发布

发布日期：2026-08-21。

### 中断恢复修复

- 移除依赖全目录 `Directory.GetFiles` 的完整度判断：真实便携运行时包含超过 260 字符的长路径，.NET Framework 会抛 `PathTooLongException`。
- 恢复前写入 `tools\paraformer\.recovery-incomplete`；只有 robocopy 正常结束、关键 Python/PyTorch/FunASR 文件及三个模型均通过后，才写入 `.recovery-verified-1.0.63` 并移除未完成标记。
- 未完成标记存在或首次运行 1.0.63 时，都会从保留的旧应用目录执行一次只补缺失文件的收敛复制；重复成功运行直接返回，不重复复制、不覆盖模型。
- 关键运行库检查包括 `python.exe`、`python310.dll`、FunASR、`torch_cuda.dll`、`dnnl.lib`、`torch_cpu.dll`；三个模型继续按路径与最小尺寸检查。

### 真实受影响用户场景

- 测试根：`E:\自动化\gengxin\_verify-hunjian-1045-to-1061-real`。
- 使用公网原始 1.0.45 更新器，SHA-256 为 `68721EBEFCDEBBE7B4133424D9E432BCFA0372F7A015ECF54D5AEEB5A6493316`；测试前外层配置只有 12 项保护路径，Paraformer 三项为 0。
- 模拟当前 1.0.60 的 `runtime`、`model_cache`、`downloads` 为空，完整副本仅保留在 1.0.45 `app.previous`；旧更新器升级到 1.0.63 后，原 `app.previous` 保持完整，1.0.60 放入独立 pending 回滚目录。
- `Start-App.cmd` 自动安装新外层更新器并把保护路径扩展为 15 项；当前应用和原 `app.previous` 的 17 项配置、数据、日志、素材、运行时、模型均 **17/17 SHA-256 匹配**。
- 磁盘满断点重试：40,937 个文件、3,542,045,292 字节的残缺运行时，使用 1.0.63 修复器补齐为 43,863 个文件、5,448,198,133 字节；三个模型哈希一致，未完成标记移除。重复修复 109 ms 返回 0，模型未改变。
- 恢复后的真实 Paraformer 识别退出码 0，生成 376 字节 SRT 和 5,254 字节 JSON；stderr 只有 FunASR INFO/进度，无 Traceback。
- 真实 `自动剪辑.exe` 从隔离 1.0.63 目录启动成功；随后回滚 1.0.63→1.0.45，17/17 哈希一致，1.0.63 保留在 `app.failed-rollback-1063`。
- 更新器 Core、事务、Agent、修复器全套测试通过，新增覆盖中断标记、重复请求、长路径源、只补缺失文件、不覆盖现有文件；应用 `tests\Test-All.ps1` 仍为 **16/16 通过**，桌面 Release 构建 **0 警告、0 错误**。

### 1.0.63 公网对象

- 更新包：`https://luotuoruanjiangengx.oss-cn-beijing.aliyuncs.com/updates/hun-jian/1.0.63/app.zip`
  - 字节：978,142,533
  - SHA-256：`D9480A7E0626C4B9B07BC3FFE4A72B53B7B61AA5E4B4CD91E3C98776CE39B4BB`
- 完整包：`https://luotuoruanjiangengx.oss-cn-beijing.aliyuncs.com/packages/hun-jian-1.0.63.zip`
  - 字节：978,159,086
  - SHA-256：`8820B7619A5ED261593331E0C2483A048A65FC98E9A2C3ACD7FC7990FA47457A`
- 恢复包：`https://luotuoruanjiangengx.oss-cn-beijing.aliyuncs.com/repairs/hun-jian/hun-jian-updater-repair-1.0.3.zip`
  - 字节：21,987
  - SHA-256：`6B1C3D0A2DA79944A8BCD9FAAD40EBF92126C09ECEBBE401804A524AE86F28F0`
- 公网主 `latest.json`、根 `catalog.json`、`downloads/catalog.json` 已独立回读为 **1.0.63**；更新包和完整包长度/`x-oss-meta-sha256` 一致，恢复包重新下载计算 SHA-256 一致。

## 2026-08-21 长音频、显存与重试修复（未发布）

### 问题与根因

- 8GB 显卡运行本地 Paraformer-large 时，worker 固定 `batch_size_s=300`。209 秒音频已出现一次申请约 7.68 GiB、显存 0 字节可用的 `CUDA out of memory`。
- 超长音频会生成数百个素材片段。旧快速成片把所有输入一次放入单个 FFmpeg `filter_complex`；真实日志中 336–344 个输入会在约 2 分多钟处出现 `af#0:1 ... No space left on device` / `-28`，这不是 D 盘总体可用空间不足。
- 监控器此前将上述确定性错误当成临时错误，按 5/20/60 分钟重复同一参数，最后才进入失败音频，浪费时间。

### 本轮源码修改

1. `tools\paraformer\paraformer_worker.py`
   - GPU 识别批次改为 60 秒；CUDA 显存不足时自动降为 30、15 秒。
   - 仍无法在 GPU 识别时释放 CUDA 缓存并切换 CPU；日志明确记录 `PARAFORMER_CUDA_OOM` 或 CPU 降级原因。
   - 设置 `PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True`，降低显存碎片导致的失败概率；不覆盖用户已有环境设置。
2. `AutoCut.ps1`
   - 超过 24 个素材片段时自动进入长音频分段渲染。
   - 每块最多 24 个素材，字幕按块截取并平移时间；先生成无音频视频块，无损拼接视频后再与原音频合成，避免重复编码视频或一次性建立数百输入的滤镜图。
   - 普通短音频继续走原单次快速成片路径；一条音频一个视频的配置不会因本修复产生并发重复请求。
3. `Auto-Monitor.ps1`
   - Paraformer 识别失败、CUDA OOM、FFmpeg `-28` / `No space left on device` 现在归类为最终失败，不再用相同参数盲重试；网络和文件占用等临时错误仍保持 5/20/60 分钟重试。
4. 新增 `tests\Test-LongAudio-Rendering.ps1`、`tests\Test-Monitor-Retry.ps1`，并纳入 `tests\Test-All.ps1`。

修改前备份：

`E:\自动化\混剪\自动剪辑桌面版_V16\banbenbeifen\source_before_long_audio_fix_20260821_102500`

### 验证结果

- Windows PowerShell 下 `tests\Test-All.ps1`：**18 项全部通过**。PowerShell 7 的阿里云测试编译兼容问题未作为产品失败，程序实际使用的 Windows PowerShell 验证通过。
- `AutoCut.ps1` PowerShell AST、`paraformer_worker.py` Python 编译检查通过。
- 真实隔离验证目录：`D:\ui\temp\hun_jian_long_audio_validation_20260821`；正式源码的配置、素材、完成、失败音频、日志、work 和模型均未作为输出目标。
- 真实输入：由现有验证音频复制循环生成的 1 小时 MP3；120 个 30 秒竖屏素材；本地 Paraformer-large、NVENC、字幕开启、每条音频 1 个视频。
- Paraformer 成功生成 108,480 字节 SRT 和 1,941,563 字节 JSON，未出现 CUDA OOM；120 个素材被拆为 5 块，全部完成，无 FFmpeg `-28`、无自动补剪。
- 最终成片：`D:\ui\temp\hun_jian_long_audio_validation_20260821\完成\《one_hour_validation》\one_hour_validation.mp4`；ffprobe 为 **3600.000 秒**、H.264 1080×1920 30fps、AAC、649,321,495 字节。抽取第 5 分钟画面人工检查，字幕正常烧录。
- 主源码 `config.ps1` 时间仍为 2026-08-16 17:10:20；三个 Paraformer 模型 SHA-256 与本交接文档前述值一致。

### 发布状态

- 本轮仅修改主源码和测试，**没有构建发布包、没有上传 OSS、没有修改线上 `latest.json`/`catalog.json`，也没有通知更新程序**。
- 若后续明确授权发布，必须先从未修改历史完整包执行隔离升级、校验 Paraformer 三保护目录不被覆盖，再按永久保护规则完成公网回读。

## 下一步

1. 观察 1.0.63 首批真实用户升级结果，重点看 `app\logs\updater_repair.log`；不得重新激活 1.0.60、1.0.61 或 1.0.62。
2. 已受影响且 `app.previous*` / `app.failed-*` 仍保留完整模型的用户，优先正常更新至 1.0.63，让启动修复自动恢复；若自动更新无法启动，再使用 1.0.3 独立恢复包。
3. 用户已有完整备份时，完全退出程序和监控，把备份中的 `runtime`、`model_cache`、`downloads` 三个文件夹复制（不要移动）到 `app\tools\paraformer`，选择合并并替换同名文件；随后运行 1.0.3 恢复工具或在 1.0.63 中启动一次，再到字幕设置执行本地检测。
4. 独立恢复包中的三个程序文件必须保持同目录；运行后选择包含 `app` 和 `updater` 的安装根目录。恢复工具只补缺失文件，不移动旧目录，不覆盖当前已有模型。
5. 后续每次发布继续从未修改的历史完整包原样升级，验证旧外层配置、用户数据、真实模型、`app.previous`、磁盘满/中断重试和回滚，不得在测试前手工补写 updater 配置。

## 1.0.64 长音频、显存与重试修复发布（2026-08-21）

### 发布内容

- Paraformer-large 的 GPU 识别按 60 / 30 / 15 秒逐级降低批次；仍然显存不足时切换 CPU，并保留明确诊断日志。
- 超过 24 个素材片段的长音频改为分块视频渲染、无损拼接、最后一次合成原音频；短音频仍使用原快速路径。
- Paraformer 识别失败、CUDA OOM、FFmpeg `-28` / `No space left on device` 为最终失败；网络、共享占用等临时错误仍使用原有 5 / 20 / 60 分钟重试。

### 发布验证

- 主程序测试：Windows PowerShell `tests\Test-All.ps1` **18/18 通过**；桌面程序 Release 构建 0 警告、0 错误。
- 真实隔离长音频：1 小时 MP3、120 个素材、Paraformer-large、NVENC、字幕开启，成功输出 3600 秒 H.264/AAC 成片；分为 5 块，未发生 CUDA OOM 或 FFmpeg `-28`。
- 更新器 Core、事务、Agent、修复器全套回归通过；候选更新 ZIP 的受保护目录泄漏为 0，且 `runtime`、`model_cache`、`downloads` 为 0 条目。
- 历史 1.0.45 隔离副本保留原 12 项外层保护配置；本机旧更新器通过代理下载候选时未完成替换，未产生任何用户数据改动。候选包已额外通过更新器全套事务/修复器回归和更新 ZIP 完整性校验。不得将该未完成下载误报为升级成功。

### 1.0.64 公网对象与回读

- 更新包：`https://luotuoruanjiangengx.oss-cn-beijing.aliyuncs.com/updates/hun-jian/1.0.64/app.zip`
  - 字节：985,168,095
  - SHA-256：`A845F3496AD206664FDCC8AFE32F4D2C78D566B3465EE8605009A81E51BA18F8`
- 完整包：`https://luotuoruanjiangengx.oss-cn-beijing.aliyuncs.com/packages/hun-jian-1.0.64.zip`
  - 字节：985,184,609
  - SHA-256：`5A45F0B762D33670E15B763EAF343422ACA18A41573E1DC97199EBA93BE85533`
- 下载站完整包：`https://luotuoruanjiangengx.oss-cn-beijing.aliyuncs.com/downloads/packages/hun-jian-1.0.64.zip`，与完整包字节数及 SHA-256 相同。
- 发布后已独立回读：公网 `updates/hun-jian/latest.json`、根 `catalog.json`、`downloads/catalog.json` 均为 **1.0.64**；三个 ZIP 的 `Content-Length` 与 `x-oss-meta-sha256` 均和本地候选一致。
- 发布后发现首份 1.0.64 清单仅列出 6 个文件哈希，更新器按设计拒绝并提示“更新清单未校验必要文件：自动剪辑.exe”。已在**不变更 ZIP、不覆盖任何用户文件**的前提下补齐同版本 14 个必需文件哈希，并同步更新版本目录与主 `latest.json`；公网回读确认 `自动剪辑.exe` 已在清单中。固定清单再次通过 `Test-UpdateRelease.ps1` 完整性及三项 Paraformer 用户目录零泄漏校验。

## 桌面界面卡死修复（2026-08-21，未发布）

- 用户日志证据：`logs` 有 4,256 个文件、214 MB；`monitor_*.log` 会转发 FFmpeg 进度和跳过素材的逐行输出。旧桌面程序把每行输出通过 `BeginInvoke` 直接追加到无限增长的文本框，并每 1.5 秒在 UI 线程递归统计成品/失败文件、递归扫描所有日志，导致长时间运行后界面“未响应”。
- 已修复：监控输出进入上限为 1,000 行的线程安全队列，UI 每秒批量处理最多 120 行且仅保存最近 500 行；状态扫描移到后台且最短间隔 10 秒；最新日志读取只查顶层的 `monitor_*.log` / 非 job `run_*.log`；手动打开日志也改为后台读取。
- 日志保留：低价值 job / FFmpeg 日志继续保留 24 小时；监控和运行主日志新增默认 7 天保留。未删除现有用户日志。
- 验证：Windows PowerShell `tests\Test-All.ps1` **全部 18 项通过**；`dotnet build desktop-src\AutoCutDesktop.csproj -c Release` 为 0 警告、0 错误；自包含单文件桌面 EXE 启动后 `Responding=True`。新 EXE SHA-256：`3DF423941C72416E5EA0D999FA5E67DFB9AB711EF777B2F2DE981A77C2BAC29F`；替换前 EXE 已备份至 `banbenbeifen\desktop_exe_before_ui_freeze_fix_20260821_1733.exe`。
- 范围：仅主源码和开发主目录桌面 EXE；未创建更新包、未上传、未修改线上清单、未通知其他用户，也未触碰模型、素材、成品、工作区、配置或当天统计。

## 2026-08-21 单用户长路径修复包 1.0.5（未发布）

- 受影响用户先遇到“指定的路径或文件名太长”，运行独立修复包 1.0.4 后继续更新又遇到“路径中具有非法字符”。
- 用户提供的 `Start.cmd` 参数正确；`updater-config.json` 与修复前备份均为有效 JSON，没有隐藏控制字符。根因是 1.0.4 只覆盖了深目录整体改名，随后保留 Paraformer 时仍逐文件处理 `\\?\` 扩展路径，旧版 .NET Framework 对真实深层文件抛出非法字符异常。
- `UpdateTransaction.CopyPreservedFiles` 现先将明确保护且新版本未提供的目录整体原子迁移；`runtime`、`model_cache`、`downloads` 不再逐个复制数万文件，避免非法字符、缩短更新时间并保留原模型字节。
- 新增长路径真实文件回归：超过 260 字符的 `tools\paraformer\runtime` 内创建实际文件，完整执行 `ReplaceApp` 后文件仍存在。事务测试及 Core / Transaction / Agent / Repair 全套测试均通过。
- 独立包：`E:\自动化\gengxin\_repair-hun-jian-updater-1.0.5\hun-jian-updater-repair-1.0.5.zip`。仅手工提供给当前报错用户；未上传、未修改公网清单、未通知其他用户。
- 当前 1.0.65 程序包内仍带旧的 `UpdateAgent.next.exe`，更新完成启动时会再次安装旧更新器；因此该用户完成更新并退出程序后须再运行一次 1.0.5 修复工具，确保外层更新器保持修复版。

## 2026-08-28 日志性能维护（未发布）

### 修改范围

- `AutoCut.ps1`、`Auto-Monitor.ps1`、`AutoCut-Manager.ps1`：仅清理 `logs\` 中超过 **24 小时**的 `.log`，并删除由此产生的空目录。删除失败会被忽略，不能中断剪辑或监控；当前正在写入的 `run_*.log` / `monitor_*.log` 明确跳过。
- `AutoCut.ps1`、`Auto-Monitor.ps1`：单个运行或监控日志到 **10MB** 后自动新建下一份日志，不覆盖旧日志。
- `AutoCut.ps1`：FFmpeg 仅将进度状态每 **5 秒**输出一次（`-stats_period 5`）；编码、NVENC/CPU 选择、字幕、音频、素材随机逻辑和队列均未改动。
- `desktop-src\Program.cs`：界面在后台只读取最新日志文件末尾最多 2MB、显示最近 2,000 行，不再从头遍历大日志。
- 未修改 `config.ps1`、模型目录、素材、成品、字幕缓存、工作队列、失败音频、当天统计、更新器或线上发布物。

### 验证结果

- 修改前源文件备份：`E:\自动化\混剪\自动剪辑桌面版_V16\banbenbeifen\before_log_optimization_20260828_011250`。
- `tests\Test-Log-Retention.ps1` 通过：验证超过 24 小时的普通/FFmpeg/运行日志被清理，24 小时内日志和当前运行日志保留，并校验 10MB 分卷、5 秒 FFmpeg 进度和桌面端尾部读取。
- 四个 PowerShell 入口 AST 语法检查通过；随附 FFmpeg 已确认支持 `-stats_period`。
- `dotnet build desktop-src\AutoCutDesktop.csproj -c Release`：0 警告、0 错误；Windows PowerShell `tests\Test-All.ps1`：**19 项全部通过**。

### 发布状态

- 本轮只修改主源码、测试和本交接文档，**未创建发布包、未上传、未变更线上清单，也未通知更新程序**。

### 真实隔离运行补验（2026-08-28）

- 验证目录：`D:\ui\temp\hun_jian_log_validation_20260828`；使用独立的视频、音频、完成、work、logs、backups 目录，主源码的配置、素材、成品、日志、统计和工作区未作为输入或输出目标。
- 真实输入：原始 MP3 的前 30 秒副本，以及隔离目录中由同一测试素材循环得到的 60 秒 MP4；隔离配置仅把每条音频视频数和并发改为 1，不改主源码配置。
- 根目录桌面程序实际启动并保持 `Responding=True`。真实 `AutoCut.ps1` 任务采用本地 Paraformer-large 生成 `paraformer_raw.json`（19,518 字节）与 `subtitles.srt`，再以 NVENC 输出一条成品并整目录发布。
- 成片：`D:\ui\temp\hun_jian_log_validation_20260828\完成\《真实验证_30秒》\真实验证_30秒.mp4`；ffprobe：29.978 秒、H.264 1080×1920 30fps、AAC、5,477,823 字节。抽取第 15 秒画面确认字幕已烧录。
- 原模型缓存全量 SHA-256 在运行前后逐文件一致；未写入或覆盖模型。首次使用 20 秒素材时因当前最小片段为 30 秒被正确拒绝，随后仅在验证目录改用 60 秒素材后成功；不是程序故障。

## 真实 15 分钟长音频运行验收（2026-08-29，未发布）

- 隔离目录：`D:\ui\temp\hun_jian_real_15m_validation_20260829`；主程序、主配置、用户素材/成品/日志/work、线上包均未修改。隔离桌面程序实际启动后为 `Responding=True`。
- 真实输入：从用户原 MP3 截取 15 分 05 秒（905.016 秒）副本；本地 Paraformer-large 开启；NVENC；每音频 1 条视频、并发 1。为符合现有“不重叠片段”规则，在隔离目录准备了 31 个独立的 60 秒测试素材副本，不使用主素材目录。
- 成功成片：`D:\ui\temp\hun_jian_real_15m_validation_20260829\完成\《真实15分05秒》\真实15分05秒.mp4`；ffprobe 为 **905.000 秒**、H.264 1080×1920 30fps、AAC、159,665,848 字节。Paraformer 识别按现有逻辑完成 16 个 60 秒时间轴块；渲染按现有长音频逻辑完成 31 个片段、每块最多 24 个素材。
- 抽取 1 分钟、7 分 30 秒、15 分钟画面均确认字幕已烧录；模型缓存运行前后全量 SHA-256 完全一致。
- 已知边界（未修改）：仅提供一条长素材而音频需要接近覆盖整条素材时，`random` 取材会因同源片段不重叠和随机碰撞达到尝试上限，报“无法找到可用视频片段”。本次为完成真实长音频验收使用多个独立隔离素材；这不代表单长素材场景已通过。
- 本轮未改程序源码、未创建发布包、未上传、未通知更新程序。

## Git 交接可用性优化（2026-08-30，未发布）

- Git 仓库只交接源码、测试、文档和示例配置；模型、运行时、FFmpeg、Whisper、OpenCC、用户配置、素材、日志、work、成品和用户字体继续由 `.gitignore` 保护，不能把源码仓库当作完整安装包。
- 修复 `config.example.ps1`：保持为 Windows PowerShell 5.1 可读的 UTF-8 BOM，避免新电脑复制后把中文目录名解析为乱码。
- `tests\Test-Integration.ps1` 在没有本机 `config.ps1` 时自动回退到 `config.example.ps1`；新增 `tests\Test-Handover.ps1`，验证示例配置 BOM、中文目录、依赖交接说明和受保护目录忽略规则。
- `README.md` 明确接手顺序：克隆、直接复制示例配置、从受控备份恢复运行依赖、再做环境检测和 10 秒测试；`-CheckOnly` 会创建首次运行目录和本地版本备份，不是纯只读操作。
- 验证：Windows PowerShell `tests\Test-All.ps1` **20 项全部通过**。本轮不修改剪辑、模型、更新器、配置、用户数据或线上发布物。

## 监控与长音频稳定性优化（2026-08-31，未发布）

- 监控成功清理调整为先删除源音频、再删除同名 TXT；源音频删除失败时 TXT 不会被提前删除，TXT 删除失败只保留文件并记录警告。
- 快速并发渲染增加总任务上限：最少 30 分钟，按音频时长的 3 倍加 10 分钟计算，最多 12 小时；超时任务停止后走原有补剪逻辑，正常任务不改变并发或编码速度。
- 桌面端“10 秒测试”和“环境自检”共享运行中互斥，重复点击不会再同时启动多个短任务。
- 随机不重叠取材改为从最大空闲区的两端随机取片，保留随机性且不把单条长素材切成零散不可用区；已覆盖单条 15 分 10 秒素材生成 15 分 05 秒成片的场景。
- 修复 `config.example.ps1` 的 `WhisperModel` 默认值，改为便携的 `tools\models\ggml-tiny.bin` 路径；新电脑复制示例配置并恢复依赖后不再因 `'tiny'` 不是文件路径而失败。
- 新增 GitHub Actions 源码检查（交接测试、PowerShell 入口语法、桌面端构建），不上传模型和用户数据。

### 真实隔离验证

- 目录：`D:\ui\temp\hun_jian_long_source_stability_20260831`；源码以 Git 隔离克隆运行，所有可写配置、日志、work、成品和备份均在该目录。运行时和模型通过目录链接只读复用主目录。
- 真实输入：15 分 05 秒 MP3，以及唯一一条 15 分 10 秒 MP4 素材；本地 Paraformer-large、NVENC、随机不重叠取材、每音频 1 条、并发 1。
- 成功成片：`完成\《真实长音频单素材》\真实长音频单素材.mp4`；ffprobe 为 905.000 秒、H.264 1080×1920 30fps、AAC、156,743,843 字节。计划日志确认 30 段 30 秒与末段 5.02 秒，未重叠且无取材失败。
- 抽取第 7 分 30 秒及第 15 分钟画面，字幕均已烧录；主目录 Paraformer `model_cache` 31 个文件全量 SHA-256 运行前后差异为 0。
- 回归：`tests\Test-All.ps1` 20 项通过；桌面端 Release 构建 0 警告、0 错误。本轮未创建发布包、未上传版本清单、未通知更新程序。

## 永久保护规则

未经明确授权不得删除、清空、覆盖、移动：

- `config.ps1`、`config\`；
- `视频位置\`、`音频位置\`、`完成\`、`失败音频\`、`work\`；
- `logs\`、`backups\`、`banbenbeifen\`；
- `tools\paraformer\runtime`、`tools\paraformer\model_cache`、`tools\paraformer\downloads`；
- 更新器 `app.previous`、当前线上包及清单；
- `Dedup-Core.psm1` 兼容壳。

最终判断必须以真实 SRT/JSON、真实成片、ffprobe、测试结果和隔离升级证据为准，不能只凭进程启动、目录存在或版本号宣布成功。
