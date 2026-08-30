# Two-line Semantic Subtitle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Render each natural speech segment as one subtitle event with at most two visual lines, rather than changing subtitle events line by line.

**Architecture:** Keep the existing Aliyun word-level timing path. Change `Subtitle-Core.psm1` so its splitter makes a semantic event first, then formats that event into one or two width-safe visual lines. Preserve those line breaks in SRT and validate every visual line independently.

**Tech Stack:** Windows PowerShell 5.1, System.Drawing measurement, FFmpeg/libass SRT rendering, existing PowerShell test scripts.

## Global Constraints

- Keep Aliyun word timing and source-mode behavior unchanged.
- Subtitle events contain one or two lines only; no line may exceed the configured safe pixel width.
- Do not create one-character or two-character standalone events for ordinary continuous Chinese text.
- Preserve all text order and timing monotonicity.

---

### Task 1: Define two-line event behavior with failing tests

**Files:**
- Modify: `tests/Test-Subtitle-Core.ps1`

**Interfaces:**
- Consumes: `Split-SubtitleText`, `New-SrtFromSegments`, `Test-SubtitleSegments`.
- Produces: regression coverage for one/two-line output, SRT preservation, and validation limits.

- [ ] **Step 1: Add assertions for a long natural sentence**

```powershell
$twoLineChunks = @(Split-SubtitleText -Text '被接回相府的第一天就撞破病娇爹在试穿女装' @twoLineOptions)
Assert-Equal 1 $twoLineChunks.Count '可容纳两行的完整语义段必须作为一个字幕事件显示'
Assert-True ($twoLineChunks[0] -match "`n") '长语义段必须使用两行排版'
Assert-Equal '被接回相府的第一天就撞破病娇爹在试穿女装' (($twoLineChunks[0] -replace "`r?`n", '')) '两行排版不得丢字或改序'
```

- [ ] **Step 2: Run test and verify it fails because existing code forbids multi-line events**

Run: `powershell -ExecutionPolicy Bypass -File .\tests\Test-Subtitle-Core.ps1`

Expected: FAIL because the old splitter creates separate events and `Test-SubtitleSegments` rejects line breaks.

### Task 2: Produce width-safe one/two-line semantic events

**Files:**
- Modify: `Subtitle-Core.psm1`
- Test: `tests/Test-Subtitle-Core.ps1`

**Interfaces:**
- Consumes: `Test-SubtitleTextFits` for individual visual lines.
- Produces: `Split-SubtitleText` returns a subtitle event string containing zero or one newline, never more.

- [ ] **Step 1: Keep the existing single-line split pass as the width authority**
- [ ] **Step 2: Merge consecutive compatible visual lines into one event, up to two lines, preferring punctuation boundaries and preserving text order**
- [ ] **Step 3: Run core tests and verify the new behavior passes**

Run: `powershell -ExecutionPolicy Bypass -File .\tests\Test-Subtitle-Core.ps1`

Expected: PASS.

### Task 3: Preserve and validate two-line SRT events end-to-end

**Files:**
- Modify: `Subtitle-Core.psm1`
- Modify: `AutoCut.ps1`
- Test: `tests/Test-Subtitle-Core.ps1`, `tests/Test-Integration.ps1`

**Interfaces:**
- `New-SrtFromSegments` emits one or two text lines per SRT event.
- `Convert-SrtToSegments -PreserveEvents` returns both lines as one event.
- `Test-SubtitleSegments` accepts up to two lines and measures each line separately.

- [ ] **Step 1: Write SRT round-trip tests for an event containing two lines**
- [ ] **Step 2: Update SRT writer/parser/validator and replace the single-line gate in AutoCut with a two-line gate**
- [ ] **Step 3: Run the complete test suite**

Run: `powershell -ExecutionPolicy Bypass -File .\tests\Test-All.ps1`

Expected: all scripts PASS.

### Task 4: Real render verification

**Files:**
- No source changes expected.

- [ ] **Step 1: Process one short real audio/video test with subtitles enabled**
- [ ] **Step 2: Inspect an extracted output frame for a maximum of two lines, no horizontal overflow, and readable timing**
- [ ] **Step 3: Record the verification result in the run log**

