param()

$ErrorActionPreference = "Stop"
$Root = $PSScriptRoot
$ConfigPath = Join-Path $Root "config.ps1"
$MonitorScript = Join-Path $Root "Auto-Monitor.ps1"
$MonitorBat = Join-Path $Root "自动监控.bat"
$AutoStartScript = Join-Path $Root "AutoStart.ps1"
$LauncherScript = Join-Path $Root "Start-AutoCut.ps1"
$TestBat = Join-Path $Root "测试10秒.bat"
$LogDir = Join-Path $Root "logs"
$DailyVideoStatsPath = Join-Path $Root "config\daily_video_stats.json"
$script:MonitorProcess = $null
$script:IsPaused = $false

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class ProcControl {
    [DllImport("ntdll.dll")] public static extern int NtSuspendProcess(IntPtr processHandle);
    [DllImport("ntdll.dll")] public static extern int NtResumeProcess(IntPtr processHandle);
}
"@

function Ensure-Dir($Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "目录路径为空。"
    }
    if (Test-Path -LiteralPath $Path -PathType Container) {
        return
    }
    if (-not (Test-Path -LiteralPath $Path)) {
        [IO.Directory]::CreateDirectory($Path) | Out-Null
    }
}

function Try-EnsureDirForSave($Path, $Label) {
    try {
        Ensure-Dir $Path
        return $null
    } catch {
        return "$Label 当前不可访问：$Path`r`n$($_.Exception.Message)"
    }
}

$VideoExtsForUi = @(".mp4", ".mov", ".mkv", ".webm", ".avi", ".m4v")
$ImageExtsForUi = @(".jpg", ".jpeg", ".png", ".webp", ".bmp")
$AudioExtsForUi = @(".mp3", ".wav", ".m4a", ".aac", ".flac", ".ogg", ".wma")

function Get-LowerExtension($Item) {
    if ($null -eq $Item -or [string]::IsNullOrWhiteSpace($Item.Extension)) {
        return ""
    }
    return ("" + $Item.Extension).ToLowerInvariant()
}

function Count-FilesByExt($Dir, $Exts, [switch]$Recurse) {
    if (-not (Test-Path -LiteralPath $Dir)) {
        return 0
    }
    $params = @{
        LiteralPath = $Dir
        File = $true
        ErrorAction = "SilentlyContinue"
    }
    if ($Recurse) { $params.Recurse = $true }
    return @((Get-ChildItem @params) | Where-Object { $Exts -contains (Get-LowerExtension $_) }).Count
}

function Read-Config {
    . $ConfigPath
    return [ordered]@{
        VideoDir = $VideoDir
        AudioDir = $AudioDir
        OutputDir = $OutputDir
        EnableSubtitles = [bool]$EnableSubtitles
        VideosPerAudio = [int]$VideosPerAudio
        ParallelRenders = [int]$ParallelRenders
        SupplementRetryRounds = [int]$SupplementRetryRounds
        OutputMode = [string]$OutputMode
        Fps = [int]$Fps
        VideoCrf = [int]$VideoCrf
        ClipMode = [string]$ClipMode
        ImageDurationSeconds = [int]$ImageDurationSeconds
        EnableImageEffects = [bool]$EnableImageEffects
        EnableAtmosphereEffects = [bool]$EnableAtmosphereEffects
        AtmosphereEffectMode = [string]$AtmosphereEffectMode
        PreferredVideoEncoder = [string]$PreferredVideoEncoder
        SubtitleFontSize = [int]$SubtitleFontSize
        SubtitleColor = [string]$SubtitleColor
        SubtitleOutline = [int]$SubtitleOutline
        SubtitleMaxCharsPerLine = [int]$SubtitleMaxCharsPerLine
        SubtitleMarginV = [int]$SubtitleMarginV
        OverwriteOutput = [bool]$OverwriteOutput
    }
}

function ConvertTo-PsLiteral($Value) {
    if ($Value -is [bool]) {
        if ($Value) { return '$true' }
        return '$false'
    }
    if ($Value -is [int]) { return [string]$Value }
    $escaped = ([string]$Value).Replace("'", "''")
    return "'" + $escaped + "'"
}

function Set-ConfigValue($Text, $Name, $Value) {
    $configName = [regex]::Escape('$' + $Name)
    $pattern = "(?m)^\s*$configName\s*=.*$"
    $line = '$' + $Name + ' = ' + (ConvertTo-PsLiteral $Value)
    if ($Text -match $pattern) {
        return [regex]::Replace($Text, $pattern, $line)
    }
    return $Text.TrimEnd() + "`r`n" + $line + "`r`n"
}

function Save-Config($Values) {
    Ensure-Dir (Join-Path $Root "banbenbeifen")
    $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
    Copy-Item -LiteralPath $ConfigPath -Destination (Join-Path $Root "banbenbeifen\config_before_manager_$stamp.ps1") -Force
    $text = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8
    foreach ($name in ($Values.Keys | Where-Object { $_ -ne 'SubtitleSourceMode' })) {
        $text = Set-ConfigValue $text $name $Values[$name]
    }
    $utf8Bom = New-Object System.Text.UTF8Encoding($true)
    [IO.File]::WriteAllText($ConfigPath, $text, $utf8Bom)
}

function Open-Folder($Path) {
    Ensure-Dir $Path
    Start-Process explorer.exe -ArgumentList ('"{0}"' -f $Path)
}

function Invoke-AutoStartAction($Action) {
    if (-not (Test-Path -LiteralPath $AutoStartScript -PathType Leaf)) { throw 'AutoStart.ps1 is missing.' }
    $output = & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $AutoStartScript -Action $Action -Root $Root 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw $output.Trim() }
    return $output.Trim()
}

function Enable-AutoStart { return Invoke-AutoStartAction 'Enable' }
function Disable-AutoStart { return Invoke-AutoStartAction 'Disable' }

function Browse-Folder($TextBox) {
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.SelectedPath = $TextBox.Text
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $TextBox.Text = $dlg.SelectedPath
    }
}

function Get-ChildProcessIds([int]$ParentId) {
    $children = @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$ParentId" -ErrorAction SilentlyContinue)
    $ids = @()
    foreach ($child in $children) {
        $ids += [int]$child.ProcessId
        $ids += Get-ChildProcessIds ([int]$child.ProcessId)
    }
    return $ids
}

function Invoke-ProcessTreeControl([int]$RootPid, [string]$Mode) {
    $ids = @(Get-ChildProcessIds $RootPid) + $RootPid
    foreach ($id in ($ids | Select-Object -Unique)) {
        try {
            $p = [Diagnostics.Process]::GetProcessById($id)
            if ($Mode -eq "suspend") {
                [ProcControl]::NtSuspendProcess($p.Handle) | Out-Null
            } else {
                [ProcControl]::NtResumeProcess($p.Handle) | Out-Null
            }
        } catch {}
    }
}

function Get-LatestLogText {
    if (-not (Test-Path -LiteralPath $LogDir)) { return "" }
    $file = Get-ChildItem -LiteralPath $LogDir -File -Filter "*.log" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if (-not $file) { return "" }
    $tail = Get-Content -LiteralPath $file.FullName -Tail 120 -ErrorAction SilentlyContinue
    return ("日志文件：{0}`r`n{1}" -f $file.Name, ($tail -join "`r`n"))
}

function Clear-UnimportantLogs {
    $cfgForCleanup = Read-Config
    $hours = 24
    if (Test-Path -LiteralPath $ConfigPath) {
        . $ConfigPath
        if ($null -ne $UnimportantLogRetentionHours) { $hours = [int]$UnimportantLogRetentionHours }
    }
    if ($hours -le 0 -or -not (Test-Path -LiteralPath $LogDir)) { return }
    $cutoff = (Get-Date).AddHours(-$hours)
    Get-ChildItem -LiteralPath $LogDir -File -Recurse -Filter "*.log" -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt $cutoff } |
        ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
    Get-ChildItem -LiteralPath $LogDir -Directory -Recurse -ErrorAction SilentlyContinue |
        Sort-Object FullName -Descending |
        Where-Object { -not (Get-ChildItem -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue) } |
        ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
}

function Make-Label($Text, $X, $Y, $W = 90) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $Text
    $l.Location = New-Object Drawing.Point($X, $Y)
    $l.Size = New-Object Drawing.Size($W, 22)
    return $l
}

function Make-TextBox($X, $Y, $W) {
    $t = New-Object System.Windows.Forms.TextBox
    $t.Location = New-Object Drawing.Point($X, $Y)
    $t.Size = New-Object Drawing.Size($W, 24)
    return $t
}

function Make-Button($Text, $X, $Y, $W = 90, $H = 30) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Text
    $b.Location = New-Object Drawing.Point($X, $Y)
    $b.Size = New-Object Drawing.Size($W, $H)
    return $b
}

function Make-Number($X, $Y, $Min, $Max) {
    $n = New-Object System.Windows.Forms.NumericUpDown
    $n.Location = New-Object Drawing.Point($X, $Y)
    $n.Size = New-Object Drawing.Size(80, 24)
    $n.Minimum = $Min
    $n.Maximum = $Max
    return $n
}

$cfg = Read-Config

$form = New-Object System.Windows.Forms.Form
$form.Text = "自动剪辑管理界面"
$form.Size = New-Object Drawing.Size(1120, 760)
$form.StartPosition = "CenterScreen"
$form.Font = New-Object Drawing.Font("Microsoft YaHei UI", 9)

$tabs = New-Object System.Windows.Forms.TabControl
$tabs.Location = New-Object Drawing.Point(10, 10)
$tabs.Size = New-Object Drawing.Size(1080, 690)
$form.Controls.Add($tabs)

$tabMain = New-Object System.Windows.Forms.TabPage
$tabMain.Text = "运行监控"
$tabConfig = New-Object System.Windows.Forms.TabPage
$tabConfig.Text = "配置"
$tabLogs = New-Object System.Windows.Forms.TabPage
$tabLogs.Text = "日志"
$tabs.TabPages.AddRange(@($tabMain, $tabConfig, $tabLogs))

$statusPanel = New-Object System.Windows.Forms.Panel
$statusPanel.Location = New-Object Drawing.Point(20, 15)
$statusPanel.Size = New-Object Drawing.Size(1020, 46)
$statusPanel.BackColor = [Drawing.Color]::Gainsboro
$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Text = "状态：未启动"
$statusLabel.Location = New-Object Drawing.Point(15, 9)
$statusLabel.Size = New-Object Drawing.Size(980, 30)
$statusLabel.Font = New-Object Drawing.Font("Microsoft YaHei UI", 14, [Drawing.FontStyle]::Bold)
$statusLabel.ForeColor = [Drawing.Color]::DimGray
$statusPanel.Controls.Add($statusLabel)
$audioCountLabel = Make-Label "音频：0" 20 72 180
$videoCountLabel = Make-Label "视频素材：0" 220 72 180
$doneCountLabel = Make-Label "完成目录：0" 420 72 220
$tabMain.Controls.AddRange(@($statusPanel, $audioCountLabel, $videoCountLabel, $doneCountLabel))

$btnStart = Make-Button "开始监控" 20 110 120 34
$btnStop = Make-Button "停止监控" 150 110 120 34
$btnPause = Make-Button "暂停任务" 280 110 120 34
$btnResume = Make-Button "继续任务" 410 110 120 34
$btnTest = Make-Button "10秒测试" 540 110 120 34
$btnCheck = Make-Button "环境自检" 670 110 120 34
$tabMain.Controls.AddRange(@($btnStart, $btnStop, $btnPause, $btnResume, $btnTest, $btnCheck))

$btnOpenAudio = Make-Button "打开音频位置" 20 160 130
$btnOpenVideo = Make-Button "打开视频位置" 160 160 130
$btnOpenOutput = Make-Button "打开完成位置" 300 160 130
$btnOpenFailed = Make-Button "打开失败音频" 440 160 130
$btnAutoStartEnable = Make-Button ([string]::Concat([char]0x542F, [char]0x7528, [char]0x5F00, [char]0x673A, [char]0x81EA, [char]0x542F)) 580 160 140
$btnAutoStartDisable = Make-Button ([string]::Concat([char]0x5173, [char]0x95ED, [char]0x5F00, [char]0x673A, [char]0x81EA, [char]0x542F)) 730 160 140
$tabMain.Controls.AddRange(@($btnOpenAudio, $btnOpenVideo, $btnOpenOutput, $btnOpenFailed, $btnAutoStartEnable, $btnAutoStartDisable))

$infoPanel = New-Object System.Windows.Forms.Panel
$infoPanel.Location = New-Object Drawing.Point(20, 200)
$infoPanel.Size = New-Object Drawing.Size(1020, 86)
$infoPanel.BorderStyle = "FixedSingle"
$infoPanel.BackColor = [Drawing.Color]::WhiteSmoke
$infoLabels = [ordered]@{}
function Add-InfoItem($Key, $Title, $X, $Y, $W = 240) {
    $label = New-Object System.Windows.Forms.Label
    $label.Text = "$Title：-"
    $label.Location = New-Object Drawing.Point($X, $Y)
    $label.Size = New-Object Drawing.Size($W, 24)
    $label.Font = New-Object Drawing.Font("Microsoft YaHei UI", 9, [Drawing.FontStyle]::Bold)
    $infoPanel.Controls.Add($label)
    $script:infoLabels[$Key] = $label
}
Add-InfoItem "Monitor" "监控状态" 12 10 210
Add-InfoItem "Today" "今日已剪辑" 245 10 170
Add-InfoItem "Current" "正在剪辑" 430 10 315
Add-InfoItem "Subtitle" "字幕状态" 760 10 250
Add-InfoItem "Start" "开始时间" 12 48 210
Add-InfoItem "Done" "已完成数量" 245 48 170
Add-InfoItem "Failed" "失败数量" 430 48 160
Add-InfoItem "LastDone" "上次完成" 610 48 260
Add-InfoItem "LastDoneTime" "完成时间" 855 48 150
$tabMain.Controls.Add($infoPanel)

$mainLog = New-Object System.Windows.Forms.TextBox
$mainLog.Location = New-Object Drawing.Point(20, 300)
$mainLog.Size = New-Object Drawing.Size(1020, 340)
$mainLog.Multiline = $true
$mainLog.ScrollBars = "Both"
$mainLog.ReadOnly = $true
$mainLog.Font = New-Object Drawing.Font("Consolas", 9)
$tabMain.Controls.Add($mainLog)

$txtVideo = Make-TextBox 120 25 690
$txtAudio = Make-TextBox 120 60 690
$txtOutput = Make-TextBox 120 95 690
$txtVideo.Text = $cfg.VideoDir
$txtAudio.Text = $cfg.AudioDir
$txtOutput.Text = $cfg.OutputDir
$btnBrowseVideo = Make-Button "选择" 825 23 70
$btnBrowseAudio = Make-Button "选择" 825 58 70
$btnBrowseOutput = Make-Button "选择" 825 93 70
$tabConfig.Controls.AddRange(@(
    (Make-Label "素材位置" 20 27),
    $txtVideo,
    $btnBrowseVideo,
    (Make-Label "音频位置" 20 62),
    $txtAudio,
    $btnBrowseAudio,
    (Make-Label "完成位置" 20 97),
    $txtOutput,
    $btnBrowseOutput
))

$numVideos = Make-Number 150 150 1 20
$numParallel = Make-Number 420 150 1 12
$numRetry = Make-Number 690 150 0 10
$numCrf = Make-Number 150 190 18 35
$numFps = Make-Number 420 190 15 60
$numFont = Make-Number 690 190 12 60
$numOutline = Make-Number 690 230 0 10
$numMaxChars = Make-Number 150 230 0 80
$numMargin = Make-Number 420 230 0 500
$numImageDuration = Make-Number 690 310 2 60
$numVideos.Value = $cfg.VideosPerAudio
$numParallel.Value = $cfg.ParallelRenders
$numRetry.Value = $cfg.SupplementRetryRounds
$numCrf.Value = $cfg.VideoCrf
$numFps.Value = $cfg.Fps
$numFont.Value = $cfg.SubtitleFontSize
$numOutline.Value = $cfg.SubtitleOutline
$numMaxChars.Value = $cfg.SubtitleMaxCharsPerLine
$numMargin.Value = $cfg.SubtitleMarginV
$numImageDuration.Value = $cfg.ImageDurationSeconds

$chkImageEffects = New-Object System.Windows.Forms.CheckBox
$chkImageEffects.Location = New-Object Drawing.Point(810, 310)
$chkImageEffects.Size = New-Object Drawing.Size(140, 24)
$chkImageEffects.Text = "图片动效"
$chkImageEffects.Checked = $cfg.EnableImageEffects

$chkWholeSource = New-Object System.Windows.Forms.CheckBox
$chkWholeSource.Location = New-Object Drawing.Point(570, 340)
$chkWholeSource.Size = New-Object Drawing.Size(180, 24)
$chkWholeSource.Text = "整条素材使用"
$chkWholeSource.Checked = ($cfg.ClipMode -eq "whole")

$chkAtmosphereEffects = New-Object System.Windows.Forms.CheckBox
$chkAtmosphereEffects.Location = New-Object Drawing.Point(950, 310)
$chkAtmosphereEffects.Size = New-Object Drawing.Size(115, 24)
$chkAtmosphereEffects.Text = "氛围特效"
$chkAtmosphereEffects.Checked = $cfg.EnableAtmosphereEffects

$cmbAtmosphere = New-Object System.Windows.Forms.ComboBox
$cmbAtmosphere.Location = New-Object Drawing.Point(690, 370)
$cmbAtmosphere.Size = New-Object Drawing.Size(170, 24)
$cmbAtmosphere.DropDownStyle = "DropDownList"
$cmbAtmosphere.Items.AddRange(@('random', 'snow', 'rain', 'petals', 'fireflies', 'stars', 'fireworks', 'confetti', 'bubbles', 'mist', 'dust'))
$cmbAtmosphere.SelectedItem = $cfg.AtmosphereEffectMode

$cmbQuality = New-Object System.Windows.Forms.ComboBox
$cmbQuality.Location = New-Object Drawing.Point(150, 310)
$cmbQuality.Size = New-Object Drawing.Size(160, 24)
$cmbQuality.DropDownStyle = "DropDownList"
$cmbQuality.Items.AddRange(@("快速 CQ30", "标准 CQ26", "高清 CQ23", "超清 CQ21", "自定义"))
switch ([int]$cfg.VideoCrf) {
    30 { $cmbQuality.SelectedItem = "快速 CQ30" }
    26 { $cmbQuality.SelectedItem = "标准 CQ26" }
    23 { $cmbQuality.SelectedItem = "高清 CQ23" }
    21 { $cmbQuality.SelectedItem = "超清 CQ21" }
    default { $cmbQuality.SelectedItem = "自定义" }
}

$cmbMode = New-Object System.Windows.Forms.ComboBox
$cmbMode.Location = New-Object Drawing.Point(150, 270)
$cmbMode.Size = New-Object Drawing.Size(120, 24)
$cmbMode.DropDownStyle = "DropDownList"
$cmbMode.Items.AddRange(@("auto", "portrait", "landscape"))
$cmbMode.SelectedItem = $cfg.OutputMode

$cmbEncoder = New-Object System.Windows.Forms.ComboBox
$cmbEncoder.Location = New-Object Drawing.Point(420, 270)
$cmbEncoder.Size = New-Object Drawing.Size(140, 24)
$cmbEncoder.DropDownStyle = "DropDownList"
$cmbEncoder.Items.AddRange(@("auto", "h264_nvenc", "libx264"))
$cmbEncoder.SelectedItem = $cfg.PreferredVideoEncoder

$chkSubs = New-Object System.Windows.Forms.CheckBox
$chkSubs.Location = New-Object Drawing.Point(690, 270)
$chkSubs.Size = New-Object Drawing.Size(120, 24)
$chkSubs.Text = "启用字幕"
$chkSubs.Checked = $cfg.EnableSubtitles

$chkOverwrite = New-Object System.Windows.Forms.CheckBox
$chkOverwrite.Location = New-Object Drawing.Point(820, 270)
$chkOverwrite.Size = New-Object Drawing.Size(140, 24)
$chkOverwrite.Text = "覆盖已有成品"
$chkOverwrite.Checked = $cfg.OverwriteOutput

$txtColor = Make-TextBox 420 310 120
$txtColor.Text = $cfg.SubtitleColor

$tabConfig.Controls.AddRange(@(
    (Make-Label "生成数量" 20 152 120), $numVideos,
    (Make-Label "并发数量" 300 152 120), $numParallel,
    (Make-Label "补剪轮数" 570 152 120), $numRetry,
    (Make-Label "画质CQ" 20 192 120), $numCrf,
    (Make-Label "帧率FPS" 300 192 120), $numFps,
    (Make-Label "字幕字号" 570 192 120), $numFont,
    (Make-Label "描边粗细" 570 232 120), $numOutline,
    (Make-Label "每行字数" 20 232 120), $numMaxChars,
    (Make-Label "字幕位置" 300 232 120), $numMargin,
    (Make-Label "输出方向" 20 272 120), $cmbMode,
    (Make-Label "编码器" 300 272 120), $cmbEncoder,
    $chkSubs, $chkOverwrite,
    (Make-Label "画质档位" 20 312 120), $cmbQuality,
    (Make-Label "字幕颜色" 300 312 120), $txtColor,
    (Make-Label "图片切换秒数" 570 312 120), $numImageDuration,
    $chkImageEffects, $chkWholeSource, $chkAtmosphereEffects,
    (Make-Label "氛围模式" 570 372 120), $cmbAtmosphere
))

$btnSave = Make-Button "保存配置" 20 435 120 34
$btnReload = Make-Button "重新读取" 150 435 120 34
$btnSubtitlePreview = Make-Button "字幕设置与预览" 280 435 150 34
$tabConfig.Controls.AddRange(@($btnSave, $btnReload, $btnSubtitlePreview))

$logBox = New-Object System.Windows.Forms.TextBox
$logBox.Location = New-Object Drawing.Point(15, 15)
$logBox.Size = New-Object Drawing.Size(1030, 610)
$logBox.Multiline = $true
$logBox.ScrollBars = "Both"
$logBox.ReadOnly = $true
$logBox.Font = New-Object Drawing.Font("Consolas", 9)
$tabLogs.Controls.Add($logBox)

function Get-UiValues {
    return [ordered]@{
        VideoDir = $txtVideo.Text
        AudioDir = $txtAudio.Text
        OutputDir = $txtOutput.Text
        VideosPerAudio = [int]$numVideos.Value
        ParallelRenders = [int]$numParallel.Value
        SupplementRetryRounds = [int]$numRetry.Value
        VideoCrf = [int]$numCrf.Value
        ClipMode = if ($chkWholeSource.Checked) { "whole" } else { "random" }
        ImageDurationSeconds = [int]$numImageDuration.Value
        EnableImageEffects = [bool]$chkImageEffects.Checked
        EnableAtmosphereEffects = [bool]$chkAtmosphereEffects.Checked
        AtmosphereEffectMode = [string]$cmbAtmosphere.SelectedItem
        Fps = [int]$numFps.Value
        SubtitleFontSize = [int]$numFont.Value
        SubtitleOutline = [int]$numOutline.Value
        SubtitleMaxCharsPerLine = [int]$numMaxChars.Value
        SubtitleMarginV = [int]$numMargin.Value
        SubtitleMarginVPortrait = [int]$numMargin.Value
        SubtitleMarginVLandscape = [int]$numMargin.Value
        OutputMode = [string]$cmbMode.SelectedItem
        PreferredVideoEncoder = [string]$cmbEncoder.SelectedItem
        EnableSubtitles = [bool]$chkSubs.Checked
        OverwriteOutput = [bool]$chkOverwrite.Checked
        SubtitleColor = $txtColor.Text.Trim().TrimStart("#").ToUpperInvariant()
    }
}

function Reload-Ui {
    $c = Read-Config
    $txtVideo.Text = $c.VideoDir
    $txtAudio.Text = $c.AudioDir
    $txtOutput.Text = $c.OutputDir
    $numVideos.Value = $c.VideosPerAudio
    $numParallel.Value = $c.ParallelRenders
    $numRetry.Value = $c.SupplementRetryRounds
    $numCrf.Value = $c.VideoCrf
    $chkWholeSource.Checked = ($c.ClipMode -eq "whole")
    $numFps.Value = $c.Fps
    $numFont.Value = $c.SubtitleFontSize
    $numOutline.Value = $c.SubtitleOutline
    $numMaxChars.Value = $c.SubtitleMaxCharsPerLine
    $numMargin.Value = $c.SubtitleMarginV
    $numImageDuration.Value = $c.ImageDurationSeconds
    $chkImageEffects.Checked = $c.EnableImageEffects
    $chkAtmosphereEffects.Checked = $c.EnableAtmosphereEffects
    $cmbAtmosphere.SelectedItem = $c.AtmosphereEffectMode
    $cmbMode.SelectedItem = $c.OutputMode
    $cmbEncoder.SelectedItem = $c.PreferredVideoEncoder
    $chkSubs.Checked = $c.EnableSubtitles
    $chkOverwrite.Checked = $c.OverwriteOutput
    $txtColor.Text = $c.SubtitleColor
    switch ([int]$c.VideoCrf) {
        30 { $cmbQuality.SelectedItem = "快速 CQ30" }
        26 { $cmbQuality.SelectedItem = "标准 CQ26" }
        23 { $cmbQuality.SelectedItem = "高清 CQ23" }
        21 { $cmbQuality.SelectedItem = "超清 CQ21" }
        default { $cmbQuality.SelectedItem = "自定义" }
    }
}

function Get-MonitorStats {
    $today = (Get-Date).Date
    $lines = @()
    if (Test-Path -LiteralPath $LogDir) {
        $lines = @(Get-ChildItem -LiteralPath $LogDir -File -Filter "monitor_*.log" -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime |
            ForEach-Object { Get-Content -LiteralPath $_.FullName -ErrorAction SilentlyContinue })
    }

    $todayDone = 0
    if (Test-Path -LiteralPath $DailyVideoStatsPath -PathType Leaf) {
        try {
            $dailyStats = Get-Content -LiteralPath $DailyVideoStatsPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($dailyStats.Date -eq $today.ToString('yyyy-MM-dd')) {
                $todayDone = [Math]::Max(0, [int]$dailyStats.VideoCount)
            }
        } catch {
            $todayDone = 0
        }
    }
    $totalDone = 0
    $todayFailed = 0
    $totalFailed = 0
    $current = "-"
    $lastDone = "-"
    $lastDoneTime = "-"
    $startTime = "-"
    $subtitleStatus = "-"

    foreach ($line in $lines) {
        $lineDate = $null
        if ($line -match '^\[(?<dt>\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\]') {
            try {
                $lineDate = [datetime]::ParseExact($matches.dt, "yyyy-MM-dd HH:mm:ss", [Globalization.CultureInfo]::InvariantCulture)
            } catch {
                $lineDate = $null
            }
        }
        $isToday = ($lineDate -and $lineDate.Date -eq $today)

        if ($line -match '====== 自动监控音频并剪辑 ======') {
            if ($lineDate) { $startTime = $lineDate.ToString("HH:mm:ss") }
        }
        if ($line -match '开始剪辑：(?<path>.+)$') {
            $current = [IO.Path]::GetFileNameWithoutExtension($matches.path.Trim())
        }
        if ($line -match '剪辑完成，已删除源音频：(?<path>.+)$') {
            $totalDone += 1
            $lastDone = [IO.Path]::GetFileNameWithoutExtension($matches.path.Trim())
            if ($lineDate) { $lastDoneTime = $lineDate.ToString("HH:mm:ss") }
            if ($current -eq $lastDone) { $current = "-" }
        }
        if ($line -match '剪辑失败，已移动音频到失败：') {
            $totalFailed += 1
            if ($isToday) { $todayFailed += 1 }
        }
        if ($line -match '字幕来源：(?<source>.+)$') {
            $subtitleStatus = $matches.source.Trim()
        } elseif ($line -match '字幕缓存：(?<cache>.+)$') {
            $subtitleStatus = $matches.cache.Trim()
        }
    }

    return [pscustomobject]@{
        TodayDone = $todayDone
        TotalDone = $totalDone
        TodayFailed = $todayFailed
        TotalFailed = $totalFailed
        Current = $current
        LastDone = $lastDone
        LastDoneTime = $lastDoneTime
        StartTime = $startTime
        SubtitleStatus = $subtitleStatus
    }
}

function Update-Status {
    if ($script:SubtitleSettingsProcess -and $script:SubtitleSettingsProcess.HasExited) {
        $script:SubtitleSettingsProcess = $null
        Reload-Ui
    }
    $c = Get-UiValues
    $audioCount = 0
    $videoCount = 0
    $doneCount = 0
    if (Test-Path -LiteralPath $c.AudioDir) { $audioCount = Count-FilesByExt $c.AudioDir $AudioExtsForUi }
    if (Test-Path -LiteralPath $c.VideoDir) { $videoCount = Count-FilesByExt $c.VideoDir ($VideoExtsForUi + $ImageExtsForUi) -Recurse }
    if (Test-Path -LiteralPath $c.OutputDir) { $doneCount = @(Get-ChildItem -LiteralPath $c.OutputDir -Directory -ErrorAction SilentlyContinue).Count }
    $audioCountLabel.Text = "音频：$audioCount"
    $videoCountLabel.Text = "素材（视频/图片）：$videoCount"
    $doneCountLabel.Text = "完成目录：$doneCount"
    if ($script:MonitorProcess -and -not $script:MonitorProcess.HasExited) {
        if ($script:IsPaused) {
            $statusLabel.Text = "状态：已暂停，PID $($script:MonitorProcess.Id)"
            $statusLabel.ForeColor = [Drawing.Color]::White
            $statusPanel.BackColor = [Drawing.Color]::DarkOrange
            $tabMain.Text = "运行监控（暂停）"
        } else {
            $statusLabel.Text = "状态：监控运行中，PID $($script:MonitorProcess.Id)"
            $statusLabel.ForeColor = [Drawing.Color]::White
            $statusPanel.BackColor = [Drawing.Color]::ForestGreen
            $tabMain.Text = "运行监控（运行中）"
        }
    } else {
        $statusLabel.Text = "状态：未启动"
        $statusLabel.ForeColor = [Drawing.Color]::DimGray
        $statusPanel.BackColor = [Drawing.Color]::Gainsboro
        $tabMain.Text = "运行监控"
        $script:MonitorProcess = $null
        $script:IsPaused = $false
    }
    $stats = Get-MonitorStats
    $monitorText = if ($script:MonitorProcess -and -not $script:MonitorProcess.HasExited) {
        if ($script:IsPaused) { "已暂停" } else { "运行中" }
    } else { "未启动" }
    $infoLabels.Monitor.Text = "监控状态：$monitorText"
    $infoLabels.Today.Text = "今日已剪辑：$($stats.TodayDone)"
    $infoLabels.Current.Text = "正在剪辑：$($stats.Current)"
    $infoLabels.Subtitle.Text = "字幕状态：$($stats.SubtitleStatus)"
    $infoLabels.Start.Text = "开始时间：$($stats.StartTime)"
    $infoLabels.Done.Text = "已完成数量：$($stats.TotalDone)"
    $infoLabels.Failed.Text = "失败数量：$($stats.TotalFailed)"
    $infoLabels.LastDone.Text = "上次完成：$($stats.LastDone)"
    $infoLabels.LastDoneTime.Text = "完成时间：$($stats.LastDoneTime)"
    $text = Get-LatestLogText
    $mainLog.Text = $text
    $logBox.Text = $text
}

function Invoke-SelfCheck {
    Ensure-Dir $LogDir
    Clear-UnimportantLogs
    $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $checkLog = Join-Path $LogDir "manager_check_$stamp.log"
    $mainLog.Text = "正在自检，请稍候..."
    $logBox.Text = $mainLog.Text
    [System.Windows.Forms.Application]::DoEvents()

    $oldCursor = $form.Cursor
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    try {
        & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $LauncherScript -CheckOnly *> $checkLog
        $code = $LASTEXITCODE
        $result = Get-Content -LiteralPath $checkLog -Raw -ErrorAction SilentlyContinue
        if ([string]::IsNullOrWhiteSpace($result)) {
            $result = "自检没有输出。"
        }
        $prefix = "自检完成，退出码：$code`r`n日志文件：$checkLog`r`n`r`n"
        $mainLog.Text = $prefix + $result
        $logBox.Text = $mainLog.Text
        if ($code -eq 0) {
            [System.Windows.Forms.MessageBox]::Show("自检完成。", "环境自检") | Out-Null
        } else {
            [System.Windows.Forms.MessageBox]::Show("自检发现问题，请查看日志区。", "环境自检") | Out-Null
        }
    } catch {
        $msg = "自检失败：$($_.Exception.Message)"
        $mainLog.Text = $msg
        $logBox.Text = $msg
        [System.Windows.Forms.MessageBox]::Show($msg, "环境自检") | Out-Null
    } finally {
        $form.Cursor = $oldCursor
    }
}

$btnBrowseVideo.Add_Click({ Browse-Folder $txtVideo })
$btnBrowseAudio.Add_Click({ Browse-Folder $txtAudio })
$btnBrowseOutput.Add_Click({ Browse-Folder $txtOutput })
$btnOpenAudio.Add_Click({ Open-Folder (Get-UiValues).AudioDir })
$btnOpenVideo.Add_Click({ Open-Folder (Get-UiValues).VideoDir })
$btnOpenOutput.Add_Click({ Open-Folder (Get-UiValues).OutputDir })
$btnOpenFailed.Add_Click({ Open-Folder (Join-Path $Root "失败音频") })

$cmbQuality.Add_SelectedIndexChanged({
    switch ([string]$cmbQuality.SelectedItem) {
        "快速 CQ30" { $numCrf.Value = 30 }
        "标准 CQ26" { $numCrf.Value = 26 }
        "高清 CQ23" { $numCrf.Value = 23 }
        "超清 CQ21" { $numCrf.Value = 21 }
    }
})

$numCrf.Add_ValueChanged({
    switch ([int]$numCrf.Value) {
        30 { $cmbQuality.SelectedItem = "快速 CQ30" }
        26 { $cmbQuality.SelectedItem = "标准 CQ26" }
        23 { $cmbQuality.SelectedItem = "高清 CQ23" }
        21 { $cmbQuality.SelectedItem = "超清 CQ21" }
        default { $cmbQuality.SelectedItem = "自定义" }
    }
})

$btnSave.Add_Click({
    try {
        $values = Get-UiValues
        if ($values.SubtitleColor -notmatch "^[0-9A-F]{6}$") { throw "字幕颜色必须是6位十六进制，例如 FFFFFF" }
        Save-Config $values
        $warnings = @(
            Try-EnsureDirForSave $values.VideoDir "视频位置"
            Try-EnsureDirForSave $values.AudioDir "音频位置"
            Try-EnsureDirForSave $values.OutputDir "完成位置"
        ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        if ($warnings.Count -gt 0) {
            [System.Windows.Forms.MessageBox]::Show(("配置已保存。`r`n`r`n但有目录当前不可访问，开始监控前请确认网络盘已连接：`r`n`r`n{0}" -f ($warnings -join "`r`n`r`n")), "保存完成，有警告") | Out-Null
        } else {
            [System.Windows.Forms.MessageBox]::Show("配置已保存。", "完成") | Out-Null
        }
    } catch {
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "保存失败") | Out-Null
    }
})
$btnReload.Add_Click({ Reload-Ui })
$btnSubtitlePreview.Add_Click({
    $subtitleSettings = Join-Path $Root 'Subtitle-Settings.ps1'
    if (Test-Path -LiteralPath $subtitleSettings) {
        $script:SubtitleSettingsProcess = Start-Process powershell.exe -ArgumentList @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $subtitleSettings) -WorkingDirectory $Root -PassThru
    }
})

$btnStart.Add_Click({
    try {
        Save-Config (Get-UiValues)
        if ($script:MonitorProcess -and -not $script:MonitorProcess.HasExited) { throw "监控已经在运行。" }
        if (Test-Path -LiteralPath $MonitorBat) {
            $script:MonitorProcess = Start-Process -FilePath $MonitorBat -WorkingDirectory $Root -WindowStyle Normal -PassThru
        } else {
            $script:MonitorProcess = Start-Process powershell.exe -ArgumentList @("-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $MonitorScript) -WorkingDirectory $Root -WindowStyle Normal -PassThru
        }
        $script:IsPaused = $false
        Update-Status
    } catch {
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "启动失败") | Out-Null
    }
})

$btnStop.Add_Click({
    if ($script:MonitorProcess -and -not $script:MonitorProcess.HasExited) {
        try {
            if ($script:IsPaused) { Invoke-ProcessTreeControl $script:MonitorProcess.Id "resume" }
            $ids = @(Get-ChildProcessIds $script:MonitorProcess.Id) + $script:MonitorProcess.Id
            foreach ($id in ($ids | Select-Object -Unique)) {
                Stop-Process -Id $id -Force -ErrorAction SilentlyContinue
            }
        } catch {}
    }
    $script:MonitorProcess = $null
    $script:IsPaused = $false
    Update-Status
})

$btnPause.Add_Click({
    if ($script:MonitorProcess -and -not $script:MonitorProcess.HasExited -and -not $script:IsPaused) {
        Invoke-ProcessTreeControl $script:MonitorProcess.Id "suspend"
        $script:IsPaused = $true
        Update-Status
    }
})

$btnResume.Add_Click({
    if ($script:MonitorProcess -and -not $script:MonitorProcess.HasExited -and $script:IsPaused) {
        Invoke-ProcessTreeControl $script:MonitorProcess.Id "resume"
        $script:IsPaused = $false
        Update-Status
    }
})

$btnTest.Add_Click({
    if (Test-Path -LiteralPath $TestBat) {
        Start-Process -FilePath $TestBat -WorkingDirectory $Root
    }
})

$btnCheck.Add_Click({
    Invoke-SelfCheck
})

$btnAutoStartEnable.Add_Click({
    try {
        $message = Enable-AutoStart
        [System.Windows.Forms.MessageBox]::Show($message, 'AutoCut') | Out-Null
    } catch {
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'AutoCut') | Out-Null
    }
})

$btnAutoStartDisable.Add_Click({
    try {
        $message = Disable-AutoStart
        [System.Windows.Forms.MessageBox]::Show($message, 'AutoCut') | Out-Null
    } catch {
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'AutoCut') | Out-Null
    }
})

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 3000
$timer.Add_Tick({ Update-Status })
$timer.Start()
$form.Add_Shown({ Clear-UnimportantLogs })
$form.Add_Shown({ Update-Status })
[void]$form.ShowDialog()
