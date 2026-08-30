# 词级时间轴字幕实施方案

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 无文本稿音频也能生成尽量填满安全宽度、单行优先且不随时长累积漂移的中文字幕。

**Architecture:** 使用阿里云 Paraformer 的 `words` 逐词时间戳作为唯一时间依据。字幕先按停顿、标点和真实字体宽度分段，再以每段首词、末词作为字幕起止时间。文本稿只作可选文字校对，不参与无文本稿时间计算。

**Tech Stack:** PowerShell 5.1、`Subtitle-Core.psm1`、阿里云 Paraformer 词级时间戳、现有 PowerShell 测试脚本。

## Global Constraints

- 保持 1080x1920、中文、最多两行、去除显示标点。
- 能完整显示一行时不得组成两行。
- 安全宽度既是上限，也是单行打包目标。
- 无文本稿不得按整句时长或全文字符比例分配字幕时间。
- 不改动混剪、监控、GPU 编码、网络连接逻辑。

---

### Task 1: 单行优先与安全宽度填充

**Files:**
- Modify: `E:\自动化\混剪\自动剪辑_对外版_20260712_阿里云时间轴容错版_v7\Subtitle-Core.psm1:138-310`
- Test: `E:\自动化\混剪\自动剪辑_对外版_20260712_阿里云时间轴容错版_v7\tests\Test-Subtitle-Core.ps1:37-105`

- [ ] 写两个失败测试：完整文本能放一行时不出现换行；可合并的相邻短语能尽量靠近安全宽度。
- [ ] 运行 `& 'E:\自动化\混剪\自动剪辑_对外版_20260712_阿里云时间轴容错版_v7\tests\Test-Subtitle-Core.ps1'`，确认新断言失败。
- [ ] 修改 `Split-SubtitleText`：先尝试合并为同一行；合并失败时输出当前单行；删除两个独立短语因合并失败而直接组成两行的分支。
- [ ] 保留单个不可再拆语义段超宽时的最多两行规则，且第二行不长于第一行。
- [ ] 重跑 `Test-Subtitle-Core.ps1`，确认所有测试通过。

### Task 2: 词级时间轴分段器

**Files:**
- Modify: `E:\自动化\混剪\自动剪辑_对外版_20260712_阿里云时间轴容错版_v7\Subtitle-Core.psm1:430-530`
- Test: `E:\自动化\混剪\自动剪辑_对外版_20260712_阿里云时间轴容错版_v7\tests\Test-Subtitle-Core.ps1:306-365`

**Interface:** 新增 `New-SegmentsFromAliyunWords -Words <object[]> -SplitOptions <hashtable> -MinimumDuration <double>`，返回 `{ Start; End; Text }` 字幕事件。

- [ ] 写失败测试：12 个有序词从 `0ms` 到 `9000ms`；断言第一条 `Start=0`、最后一条 `End=9`、每条时长为正；再断言 `700ms` 停顿前后必须断开。
- [ ] 运行核心测试，确认因函数不存在而失败。
- [ ] 最小实现：过滤无效词；遇到 `450ms` 以上停顿、句末标点、或加入下一词超出一行安全宽度时结束事件；每条 `Start=首词.begin_time/1000`，`End=末词.end_time/1000`。
- [ ] 单个词组超宽时才调用现有 `Split-SubtitleText`，并按内部词时间拆出最多两行事件。
- [ ] 在 `Convert-AliyunResultToSegments` 的无文本稿分支使用新函数；没有有效词的异常句子继续使用旧的单句兜底，避免整条音频失败。
- [ ] 重跑核心测试，确认新旧字幕、时间戳容错测试全部通过。

### Task 3: 文本稿校对不再使用全文比例时间

**Files:**
- Modify: `E:\自动化\混剪\自动剪辑_对外版_20260712_阿里云时间轴容错版_v7\Subtitle-Core.psm1:475-525`
- Test: `E:\自动化\混剪\自动剪辑_对外版_20260712_阿里云时间轴容错版_v7\tests\Test-Subtitle-Core.ps1:306-365`

- [ ] 写失败测试：给 ASR 结果提供仅修正同音错字的文本稿；断言末条字幕仍以末词结束时间为准。
- [ ] 运行测试，确认当前全文字符比例映射使断言失败。
- [ ] 用顺序文本对齐只替换可靠匹配事件的显示文字；任何无法可靠匹配的部分保留 ASR 文字，绝不重新计算词级时间。
- [ ] 运行 `Test-All.ps1`，确认完整套件通过。

### Task 4: 成片和发布验证

**Files:**
- Modify: `E:\自动化\混剪\自动剪辑_对外版_20260712_阿里云时间轴容错版_v7\发布验证报告.txt`

- [ ] 用 `AutoCut.ps1 -TestMode` 处理一条 10 秒中文音频。
- [ ] 检查开始、中部、末尾字幕：不超出安全框；单行可显示时无两行；末尾仍贴合声音。
- [ ] 日志记录实际字体文件和安全宽度，确认另一台电脑的字体没有被系统替换。
- [ ] 更新验证报告，并同步本地版和对外版；复制时排除 `logs`、`完成`、`失败音频`、`work`、`config\aliyun-key.dat`。

## 验收标准

- 无文本稿长音频末尾字幕不再出现累计滞后或提前。
- 单行能容纳的字幕不会被强制变成两行。
- 字幕会尽量利用设置的安全宽度，但不越界。
- 全部自动化测试和真实 10 秒成片验证通过。
