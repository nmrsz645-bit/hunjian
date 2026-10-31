# GitHub Release Completeness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Publish the verified Paraformer empty-speech repair source, Windows release candidate, user guide, and maintainer handoff to `nmrsz645-bit/hunjian` without touching OSS production objects.

**Architecture:** Keep GitHub `main` as the source-of-truth branch. Build a standalone Windows release candidate from the committed source, package only application code and bootstrappable dependencies, and ship the small one-click repair separately in the same GitHub prerelease. The release is explicitly a prerelease because OSS production remains at 1.0.67.

**Tech Stack:** Windows PowerShell 5.1, .NET 8 Windows Forms, Python Paraformer worker, GitHub REST/CLI release API.

**Spec:** User authorization received 2026-10-31: make latest maintainable source, a runnable Windows program, complete usage guide, and handoff available on GitHub; do not alter OSS, production manifests, or download site.

## Global Constraints

- Never commit runtime/model/download/configuration/media/logs/work/backup/user-font data or credentials.
- Do not modify OSS objects, `latest.json`, catalog, existing releases, or production update behavior.
- Version the GitHub artifact as a prerelease; do not describe OSS 1.0.67 as containing the empty-speech repair.
- Upload only after fresh tests, build, archive audit, and secret scan pass.

## Review Focus

- Empty or near-silent final audio chunks produce an empty subtitle result and still render a video without subtitles.
- Normal speech chunks retain their subtitles and timestamps.
- The repair ZIP can update a legacy installation without touching config, runtime, models, or downloads.
- Release ZIP contains a runnable desktop executable and bootstrap scripts but no user data or secrets.
- README/HANDOFF identify the actual commit, prerelease status, and OSS-production boundary.

---

### Task 1: Audit and validate the candidate source

**Files:**
- Modify: existing candidate files already in the worktree only when a failing test proves a defect.
- Test: `tests/Test-Paraformer-EmptySpeech.ps1`, `tests/Test-Paraformer-EmptySpeechRepair.ps1`, `tests/Test-All.ps1`.

- [ ] **Step 1: Inspect the complete candidate diff and untracked repair files.**

  Run: `git diff -- AutoCut.ps1 tools/paraformer/paraformer_worker.py; Get-ChildItem repairs,tests/Test-Paraformer-* -Recurse`

- [ ] **Step 2: Run the empty-speech regression tests before any packaging.**

  Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-Paraformer-EmptySpeech.ps1; powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-Paraformer-EmptySpeechRepair.ps1`

- [ ] **Step 3: Run the complete source suite and desktop build.**

  Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-All.ps1; dotnet build .\desktop-src\AutoCutDesktop.csproj -c Release`

### Task 2: Make source documentation release-accurate

**Files:**
- Modify: `README.md`, `使用说明.txt`, `桌面版使用说明.txt`, `HANDOFF.md`, `TIMEOFF.md`, `UPDATER_HANDOFF.md`.
- Test: documentation link/path and sensitive-content scans.

- [ ] **Step 1: State the GitHub prerelease version and its relationship to OSS 1.0.67.**

  The docs must name the prerelease artifact and say that it does not activate or replace the OSS updater release.

- [ ] **Step 2: Add a user-facing repair path.**

  The guide must tell a nontechnical user to exit the program, extract the repair ZIP outside the program folder, double-click `DoubleClick-Repair.bat`, choose the folder containing `app`, and run the 10-second test.

- [ ] **Step 3: Complete the next-maintainer handoff.**

  HANDOFF must list architecture/module ownership, .NET and PowerShell requirements, first-run bootstrap, build/test/release commands, safe config template use, known empty-speech behavior, version/commit lookup commands, and the no-OSS boundary.

### Task 3: Build and audit the GitHub-only Windows artifacts

**Files:**
- Create: `tools/Build-GitHubRelease.ps1`.
- Create: `tests/Test-GitHubReleasePackage.ps1`.
- Output: ignored `release-artifacts/` directory.

- [ ] **Step 1: Write a failing package audit test.**

  The test must reject an archive that includes `config.ps1`, protected user directories, Paraformer runtime/model/downloads, logs, media, `.env`, or credential-shaped values; it must require `自动剪辑.exe`, `Start-AutoCut.ps1`, `Initialize-NewComputer.ps1`, `README.md`, `HANDOFF.md`, `config.example.ps1`, and the repair ZIP.

- [ ] **Step 2: Implement the build script.**

  The script must run `dotnet publish -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true`, stage tracked safe application files plus the published executable, build the repair ZIP, create `hun-jian-v1.0.68-rc.1-windows-x64.zip`, and emit SHA-256 checksums. It must refuse to overwrite an existing output.

- [ ] **Step 3: Run the audit test against the generated archive.**

  Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-GitHubReleasePackage.ps1 -ArchivePath <generated-zip>`.

### Task 4: Commit, push, and create a GitHub prerelease

**Files:**
- Modify: tracked source and documents from Tasks 1–3.
- Upload: audited Windows ZIP, repair ZIP, and SHA-256 manifest.

- [ ] **Step 1: Scan staged content for credentials and forbidden files.**

  Run `git diff --cached --check`, inspect `git diff --cached --name-only`, and search staged text for `api[_-]?key`, `secret`, `token`, `password`, `cookie`, and `AKIA`; only documented placeholders are permitted.

- [ ] **Step 2: Commit and push only audited source/document/test/build-script files.**

  Run `git commit -m "release: prepare 1.0.68-rc.1 empty-speech repair"` followed by `git push origin main`.

- [ ] **Step 3: Create GitHub prerelease `v1.0.68-rc.1`.**

  Attach the audited Windows ZIP, repair ZIP, and SHA-256 manifest. The release description must identify it as GitHub-only prerelease, name the empty-speech repair, and state that OSS production remains 1.0.67.

- [ ] **Step 4: Read back the remote branch, tag, release assets, SHA-256 values, and GitHub documents.**

  Verify the pushed commit is `origin/main`, the release is marked prerelease, every asset is downloadable, and the document links resolve.
