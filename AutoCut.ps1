param(
    [switch]$TestMode,
    [string]$AudioFile
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$AutoCutVersion = "V16.1.15-20260816"

. "$PSScriptRoot\config.ps1"
Import-Module (Join-Path $PSScriptRoot 'Subtitle-Core.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Subtitle-Aliyun.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Segment-Usage.psm1') -Force -DisableNameChecking

$Ffmpeg = Join-Path $PSScriptRoot "tools\ffmpeg\bin\ffmpeg.exe"
$Ffprobe = Join-Path $PSScriptRoot "tools\ffmpeg\bin\ffprobe.exe"
$Whisper = Join-Path $PSScriptRoot "tools\whisper\whisper-cli.exe"
$ParaformerRoot = Join-Path $PSScriptRoot 'tools\paraformer'
$ParaformerPython = Join-Path $ParaformerRoot 'runtime\python.exe'
$ParaformerWorker = Join-Path $ParaformerRoot 'paraformer_worker.py'
$ParaformerSetup = Join-Path $ParaformerRoot 'Setup-Paraformer.ps1'
$ParaformerModelCache = Join-Path $ParaformerRoot 'model_cache'
$OpenCC = Join-Path $PSScriptRoot "tools\opencc\bin\opencc.exe"
$OpenCCConfig = Join-Path $PSScriptRoot "tools\opencc\share\opencc\t2s.json"
$InvariantCulture = [Globalization.CultureInfo]::InvariantCulture

$VideoExts = @(".mp4", ".mov", ".mkv", ".webm", ".avi", ".m4v")
$ImageExts = @(".jpg", ".jpeg", ".png", ".webp", ".bmp")
$AudioExts = @(".mp3", ".wav", ".m4a", ".aac", ".flac", ".ogg", ".wma")
$MediaInfoCache = @{}
$LogDir = Join-Path $PSScriptRoot "logs"
$BackupDir = Join-Path $PSScriptRoot "backups"
$DailyVideoStatsPath = Join-Path $PSScriptRoot "config\daily_video_stats.json"
$RunStamp = Get-Date -Format "yyyyMMdd_HHmmss"
$LogFile = Join-Path $LogDir "run_$RunStamp.log"
$RunStartTime = Get-Date
$LastHeartbeat = Get-Date
$LogMaxBytes = 10MB

# FFmpeg resolves the bundled atmosphere font relative to its working folder.
# Keep rendering rooted at the package so portable copies use the same effects.
Set-Location -LiteralPath $PSScriptRoot

function Get-RotatedLogPath([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $Path }
    try {
        if ((Get-Item -LiteralPath $Path -ErrorAction Stop).Length -lt $LogMaxBytes) { return $Path }
        $dir = Split-Path -Parent $Path
        $base = [IO.Path]::GetFileNameWithoutExtension($Path)
        $ext = [IO.Path]::GetExtension($Path)
        return (Join-Path $dir ("{0}_{1}{2}" -f $base, (Get-Date -Format 'yyyyMMdd_HHmmss_fff'), $ext))
    } catch {
        return $Path
    }
}

function Add-LogLineSafe($Path, $Line) {
    for ($attempt = 1; $attempt -le 20; $attempt += 1) {
        try {
            Add-Content -LiteralPath $Path -Value $Line -Encoding UTF8 -ErrorAction Stop
            return
        } catch {
            Start-Sleep -Milliseconds (50 * $attempt)
        }
    }
    Write-Host "日志写入失败：$Path" -ForegroundColor Red
}

function Write-Log($Message) {
    $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
    Write-Host $Message
    $script:LogFile = Get-RotatedLogPath $LogFile
    Add-LogLineSafe $LogFile $line
}

function Write-ErrorLog($Message) {
    $line = "[{0}] ERROR {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
    Write-Host $Message -ForegroundColor Red
    $script:LogFile = Get-RotatedLogPath $LogFile
    Add-LogLineSafe $LogFile $line
}

function Add-TodayCompletedVideoCount([int]$Count) {
    if ($TestMode -or $Count -le 0) {
        return
    }
    $statsDir = Split-Path -Parent $DailyVideoStatsPath
    Ensure-Directory $statsDir
    $today = (Get-Date).ToString('yyyy-MM-dd')
    $stats = [ordered]@{ Date = $today; VideoCount = 0; UpdatedAt = '' }
    if (Test-Path -LiteralPath $DailyVideoStatsPath -PathType Leaf) {
        try {
            $saved = Get-Content -LiteralPath $DailyVideoStatsPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($saved.Date -eq $today) {
                $stats.VideoCount = [Math]::Max(0, [int]$saved.VideoCount)
            }
        } catch {
            Write-ErrorLog "今日剪辑统计读取失败，将重新开始统计：$($_.Exception.Message)"
        }
    }
    $stats.VideoCount = [int]$stats.VideoCount + $Count
    $stats.UpdatedAt = (Get-Date).ToString('o')
    $tempPath = "$DailyVideoStatsPath.$([guid]::NewGuid().ToString('N')).tmp"
    [IO.File]::WriteAllText($tempPath, ($stats | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($true))
    Move-Item -LiteralPath $tempPath -Destination $DailyVideoStatsPath -Force
    Write-Log "今日剪辑视频统计：$($stats.VideoCount) 条（本次 +$Count）"
}

function Clear-UnimportantLogs {
    $hours = if ($null -eq $UnimportantLogRetentionHours) { 24 } else { [int]$UnimportantLogRetentionHours }
    if ($hours -le 0 -or -not (Test-Path -LiteralPath $LogDir)) { return }
    $cutoff = (Get-Date).AddHours(-$hours)
    $activeLogPath = [IO.Path]::GetFullPath($LogFile)
    Get-ChildItem -LiteralPath $LogDir -File -Recurse -Filter "*.log" -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt $cutoff -and [IO.Path]::GetFullPath($_.FullName) -ne $activeLogPath } |
        ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
    Get-ChildItem -LiteralPath $LogDir -Directory -Recurse -ErrorAction SilentlyContinue |
        Sort-Object FullName -Descending |
        Where-Object { -not (Get-ChildItem -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue) } |
        ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
}

function Write-Heartbeat($Force = $false) {
    $now = Get-Date
    if (-not $Force -and (($now - $LastHeartbeat).TotalSeconds -lt 10)) {
        return
    }
    $script:LastHeartbeat = $now
    $elapsed = $now - $RunStartTime
    $elapsedText = "{0:D2}:{1:D2}:{2:D2}" -f [int]$elapsed.TotalHours, $elapsed.Minutes, $elapsed.Seconds
    Write-Log ("运行中：{0}，已运行 {1}" -f $now.ToString("HH:mm:ss"), $elapsedText)
}

function Remove-OldBackupFiles($Directory, $Pattern, $KeepCount) {
    if ($KeepCount -lt 1 -or -not (Test-Path -LiteralPath $Directory -PathType Container)) { return }
    Get-ChildItem -LiteralPath $Directory -File -Filter $Pattern -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -Skip $KeepCount |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

function Remove-ExpiredWorkDirectories($Directory, $RetentionHours) {
    if ($RetentionHours -le 0 -or -not (Test-Path -LiteralPath $Directory -PathType Container)) { return }
    $cutoff = (Get-Date).AddHours(-$RetentionHours)
    Get-ChildItem -LiteralPath $Directory -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '_\d{8}_\d{6}$' -and $_.LastWriteTime -lt $cutoff } |
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
}

function Remove-SuccessfulWorkDirectory($Path, $WorkRoot) {
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return }
    $resolvedRoot = [IO.Path]::GetFullPath($WorkRoot).TrimEnd('\')
    $resolvedPath = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    if (-not $resolvedPath.StartsWith($resolvedRoot + '\', [StringComparison]::OrdinalIgnoreCase)) { return }
    if (-not [string]::Equals((Split-Path -Parent $resolvedPath), $resolvedRoot, [StringComparison]::OrdinalIgnoreCase)) { return }
    Remove-Item -LiteralPath $resolvedPath -Recurse -Force -ErrorAction SilentlyContinue
}

function Backup-Software() {
    Ensure-Directory $BackupDir
    $backupPath = Join-Path $BackupDir "software_$RunStamp.zip"
    $items = @(
        (Join-Path $PSScriptRoot "AutoCut.ps1"),
        (Join-Path $PSScriptRoot "config.ps1"),
        (Join-Path $PSScriptRoot "Subtitle-Core.psm1"),
        (Join-Path $PSScriptRoot "Subtitle-Aliyun.psm1"),
        (Join-Path $PSScriptRoot "tools\paraformer\Setup-Paraformer.ps1"),
        (Join-Path $PSScriptRoot "tools\paraformer\paraformer_worker.py"),
        (Join-Path $PSScriptRoot "Subtitle-Settings.ps1"),
        (Join-Path $PSScriptRoot "Subtitle-Preview-Worker.ps1"),
        (Join-Path $PSScriptRoot "AutoCut-Manager.ps1"),
        (Join-Path $PSScriptRoot "Start-AutoCut.ps1"),
        (Join-Path $PSScriptRoot "Auto-Monitor.ps1"),
        (Join-Path $PSScriptRoot "一键开始.bat"),
        (Join-Path $PSScriptRoot "测试10秒.bat"),
        (Join-Path $PSScriptRoot "管理界面.bat"),
        (Join-Path $PSScriptRoot "自动监控.bat"),
        (Join-Path $PSScriptRoot "字幕设置器.bat")
    ) | Where-Object { Test-Path -LiteralPath $_ }
    Compress-Archive -LiteralPath $items -DestinationPath $backupPath -Force
    Remove-OldBackupFiles $BackupDir 'software_*.zip' ([int]$SoftwareBackupKeepCount)
    Write-Log "软件备份：$backupPath"
}

function Assert-File($Path, $Name) {
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "$Name 不存在：$Path"
    }
}

function Ensure-Directory($Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "目录路径为空。"
    }
    if (Test-Path -LiteralPath $Path -PathType Container) {
        return
    }
    [IO.Directory]::CreateDirectory($Path) | Out-Null
}

function Safe-Name($Name) {
    $invalid = [IO.Path]::GetInvalidFileNameChars()
    $result = $Name
    foreach ($char in $invalid) {
        $result = $result.Replace($char, "_")
    }
    return $result
}

function Get-AudioOutputFolderName($AudioBase) {
    if ($AudioBase.StartsWith("《") -and $AudioBase.EndsWith("》")) {
        return $AudioBase
    }
    return "《$AudioBase》"
}

function Get-OutputVideoFileName($AudioBase, [int]$RenderIndex, [int]$RenderCount, [bool]$IsTest, [int]$TestSeconds) {
    if ($IsTest) {
        return "$AudioBase`_测试${TestSeconds}秒.mp4"
    }
    if ($RenderCount -le 1) {
        return "$AudioBase.mp4"
    }
    return ("{0}_{1:D2}.mp4" -f $AudioBase, $RenderIndex)
}

function Get-MediaInfo($Path) {
    if ($MediaInfoCache.ContainsKey($Path)) {
        return $MediaInfoCache[$Path]
    }
    $json = & $Ffprobe -v error -print_format json -show_entries "format=duration:stream=codec_type,width,height" "$Path"
    if ($LASTEXITCODE -ne 0) {
        throw "ffprobe 读取失败：$Path"
    }
    $info = ($json | ConvertFrom-Json)
    $MediaInfoCache[$Path] = $info
    return $info
}

function Get-DurationSeconds($Path) {
    $info = Get-MediaInfo $Path
    return [double]$info.format.duration
}

function Test-ValidOutputVideo($Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $false
    }
    $file = Get-Item -LiteralPath $Path
    if ($file.Length -le 0) {
        return $false
    }
    try {
        if ($MediaInfoCache.ContainsKey($Path)) {
            $MediaInfoCache.Remove($Path) | Out-Null
        }
        return ((Get-DurationSeconds $Path) -gt 0.5)
    } catch {
        return $false
    }
}

function Assert-CompleteVideoSet($Folder, $ExpectedCount) {
    if (-not (Test-Path -LiteralPath $Folder -PathType Container)) {
        throw "成品暂存文件夹不存在：$Folder"
    }

    $outputVideos = @(Get-ChildItem -LiteralPath $Folder -File -Filter "*.mp4")
    if ($outputVideos.Count -ne $ExpectedCount) {
        throw "成品数量不完整：需要 $ExpectedCount 条，实际 $($outputVideos.Count) 条。暂不发布成品。"
    }

    foreach ($video in $outputVideos) {
        if ($video.Length -le 0) {
            throw "成品文件为空：$($video.FullName)"
        }
        try {
            $duration = Get-DurationSeconds $video.FullName
        } catch {
            throw "成品无法读取：$($video.FullName)"
        }
        if ($duration -le 0.5) {
            throw "成品时长异常：$($video.FullName)"
        }
    }
}

function Publish-CompleteVideoFolder($StagingFolder, $FinalFolder, $ExpectedCount) {
    Assert-CompleteVideoSet $StagingFolder $ExpectedCount

    if (Test-Path -LiteralPath $FinalFolder) {
        if (-not $OverwriteOutput) {
            throw "成品文件夹已存在，未覆盖：$FinalFolder"
        }
        Remove-Item -LiteralPath $FinalFolder -Recurse -Force
    }

    Move-Item -LiteralPath $StagingFolder -Destination $FinalFolder
    Write-Log "$ExpectedCount 条成品验证通过，已整文件夹一次发布：$FinalFolder"
}

function Select-VideoSources($AllVideos) {
    if (-not $PreferFastVideoSources) {
        return @($AllVideos)
    }

    $imageSources = @($AllVideos | Where-Object { $ImageExts -contains (Get-LowerExtension $_) })
    $mp4Videos = @($AllVideos | Where-Object { (Get-LowerExtension $_) -eq ".mp4" })
    if ($mp4Videos.Count -gt 0) {
        Write-Host "已启用快速素材模式：优先使用 mp4，跳过 webm/mkv 等较慢格式。"
        return @($mp4Videos + $imageSources)
    }

    return @($AllVideos)
}

function Test-IsImageSource($Source) {
    return $ImageExts -contains (Get-LowerExtension $Source)
}

function Select-AtmosphereEffect {
    if (-not $EnableAtmosphereEffects) { return 'none' }
    $effects = @('snow', 'rain', 'petals', 'fireflies', 'stars', 'fireworks', 'confetti', 'bubbles', 'dust')
    $mode = ('' + $AtmosphereEffectMode).ToLowerInvariant()
    if ($effects -contains $mode) { return $mode }
    if ($random.Next(0, 100) -ge 85) { return 'none' }
    return $effects[$random.Next(0, $effects.Count)]
}

function Get-AtmosphereEffectFilters($Clip, $Width, $Height) {
    if ($Clip.AtmosphereEffect -eq 'none') { return '' }
    # The font is copied beside each generated filter script. Relative font
    # paths then remain valid even when the program lives in a Chinese path.
    $font = 'NotoSansSymbols2-Regular.ttf'
    if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'effects/fonts/NotoSansSymbols2-Regular.ttf'))) { return '' }

    $variant = [int]$Clip.AtmosphereVariant
    $count = 24 + ($variant % 8)
    $settings = switch ($Clip.AtmosphereEffect) {
        'snow'      { @{ Glyph = '❄'; Color = 'white@0.55'; Size = 26; X = 0.32; Y = 1.00 } }
        'rain'      { @{ Glyph = '╱'; Color = '0xB9D8FF@0.46'; Size = 25; X = 0.10; Y = 2.40 } }
        'petals'    { @{ Glyph = '✿'; Color = '0xFFB7D5@0.56'; Size = 24; X = 0.45; Y = 0.72 } }
        'fireflies' { @{ Glyph = '✦'; Color = '0xFFF3A0@0.70'; Size = 20; X = 0.55; Y = 0.25 } }
        'stars'     { @{ Glyph = '✧'; Color = '0xD8EEFF@0.58'; Size = 20; X = 0.38; Y = 0.42 } }
        'fireworks' { @{ Glyph = '✹'; Color = '0xFFD36A@0.65'; Size = 27; X = 1.10; Y = 0.72 } }
        'confetti'  { @{ Glyph = '◆'; Color = '0xF7A8C2@0.58'; Size = 18; X = 0.52; Y = 1.12 } }
        'bubbles'   { @{ Glyph = '○'; Color = '0xD7F5FF@0.50'; Size = 28; X = 0.24; Y = -0.32 } }
        default     { @{ Glyph = '✦'; Color = 'white@0.46'; Size = 18; X = 0.35; Y = 0.45 } }
    }

    $parts = @()
    for ($p = 0; $p -lt $count; $p += 1) {
        $x = (($p + 1) * 173 + $variant * 41) % $Width
        $y = (($p + 1) * 251 + $variant * 67) % $Height
        $vx = 46 + (($p % 7) * 8)
        $vy = 54 + (($p % 9) * 9)
        $xSpeed = ([double]$vx * [double]$settings.X).ToString('0.###', $InvariantCulture)
        $ySpeed = ([double]$vy * [double]$settings.Y).ToString('0.###', $InvariantCulture)
        $parts += "drawtext=fontfile=${font}:text='$($settings.Glyph)':fontcolor=$($settings.Color):fontsize=$($settings.Size):x='mod($x+t*$xSpeed,$Width)':y='mod($y+t*$ySpeed,$Height)'"
    }
    return (($parts -join ',') + ',')
}

function Prepare-AtmosphereFont($AudioWork) {
    $source = Join-Path $PSScriptRoot 'effects/fonts/NotoSansSymbols2-Regular.ttf'
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { return }
    Copy-Item -LiteralPath $source -Destination (Join-Path $AudioWork 'NotoSansSymbols2-Regular.ttf') -Force
}

function Get-LowerExtension($Item) {
    if ($null -eq $Item -or [string]::IsNullOrWhiteSpace($Item.Extension)) {
        return ""
    }
    return ("" + $Item.Extension).ToLowerInvariant()
}

function Get-VideoStream($Path) {
    $info = Get-MediaInfo $Path
    $stream = $info.streams | Where-Object { $_.codec_type -eq "video" } | Select-Object -First 1
    if (-not $stream) {
        throw "找不到视频流：$Path"
    }
    return $stream
}

function Get-TargetSize($Videos) {
    if ($OutputMode -eq "portrait") {
        return @{ Width = $PortraitWidth; Height = $PortraitHeight; Label = "portrait" }
    }
    if ($OutputMode -eq "landscape") {
        return @{ Width = $LandscapeWidth; Height = $LandscapeHeight; Label = "landscape" }
    }

    $portrait = 0
    $landscape = 0
    $sampleLimit = [Math]::Min([int]$OrientationSampleLimit, $Videos.Count)
    $sampleVideos = $Videos | Get-Random -Count $sampleLimit
    foreach ($video in $sampleVideos) {
        try {
            $stream = Get-VideoStream $video.FullName
            if ([int]$stream.height -gt [int]$stream.width) {
                $portrait += 1
            } else {
                $landscape += 1
            }
        } catch {
            Write-Host "跳过无法识别方向的视频：$($video.Name)"
        }
    }

    if ($portrait -gt $landscape) {
        return @{ Width = $PortraitWidth; Height = $PortraitHeight; Label = "portrait" }
    }
    return @{ Width = $LandscapeWidth; Height = $LandscapeHeight; Label = "landscape" }
}

function Escape-ConcatPath($Path) {
    return $Path.Replace("\", "/").Replace("'", "'\''")
}

function Invoke-Checked($File, $Arguments, $Step) {
    if ((Split-Path -Leaf $File) -ieq "ffmpeg.exe") {
        $Arguments = @("-hide_banner", "-loglevel", "error", "-stats_period", "5", "-stats") + $Arguments
    }
    & $File @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Step 失败，退出码：$LASTEXITCODE"
    }
}

function Test-VideoEncoder($Encoder) {
    $testOut = Join-Path $WorkDir "encoder_test.mp4"
    $args = @(
        "-hide_banner",
        "-loglevel", "error",
        "-y",
        "-f", "lavfi",
        "-i", "color=c=black:s=640x360:r=10:d=0.2",
        "-an",
        "-c:v", $Encoder,
        "-frames:v", "2",
        $testOut
    )
    & $Ffmpeg @args 1>$null 2>$null
    $ok = ($LASTEXITCODE -eq 0) -and (Test-Path -LiteralPath $testOut)
    if (Test-Path -LiteralPath $testOut) {
        Remove-Item -LiteralPath $testOut -Force
    }
    return $ok
}

function Get-VideoEncoder() {
    if ($PreferredVideoEncoder -and $PreferredVideoEncoder -ne "auto") {
        if (Test-VideoEncoder $PreferredVideoEncoder) {
            return $PreferredVideoEncoder
        }
        Write-Host "指定编码器不可用，自动选择：$PreferredVideoEncoder"
    }

    foreach ($encoder in @("h264_nvenc", "h264_qsv", "h264_amf", "h264_mf")) {
        if (Test-VideoEncoder $encoder) {
            return $encoder
        }
    }
    return "libx264"
}

function Get-EncodeArgs($Encoder) {
    switch ($Encoder) {
        "h264_nvenc" { return @("-c:v", "h264_nvenc", "-preset", "p1", "-cq", "$VideoCrf") }
        "h264_qsv"   { return @("-c:v", "h264_qsv", "-global_quality", "$VideoCrf") }
        "h264_amf"   { return @("-c:v", "h264_amf", "-quality", "speed", "-qp_i", "$VideoCrf", "-qp_p", "$VideoCrf", "-qp_b", "$VideoCrf") }
        "h264_mf"    { return @("-c:v", "h264_mf", "-quality", "80") }
        default      { return @("-c:v", "libx264", "-preset", $VideoPreset, "-crf", "$VideoCrf") }
    }
}

function Get-FreeDriveLetter() {
    foreach ($letter in @("W", "Y", "Z", "Q")) {
        if (-not (Test-Path "$letter`:\")) {
            return $letter
        }
    }
    throw "没有可用的临时盘符给字幕识别使用。"
}

function Convert-HexColorToAss($HexColor) {
    $hex = ("" + $HexColor).Trim().TrimStart("#")
    if ($hex.Length -ne 6 -or $hex -notmatch "^[0-9a-fA-F]{6}$") {
        $hex = "FFFFFF"
    }
    $r = $hex.Substring(0, 2)
    $g = $hex.Substring(2, 2)
    $b = $hex.Substring(4, 2)
    return "&H00$b$g$r"
}

function Get-SubtitleStyle {
    $marginV = if ($targetHeight -gt $targetWidth) {
        if ($null -ne $SubtitleMarginVPortrait) { [int]$SubtitleMarginVPortrait } else { [int]$SubtitleMarginV }
    } else {
        if ($null -ne $SubtitleMarginVLandscape) { [int]$SubtitleMarginVLandscape } else { [int]$SubtitleMarginV }
    }
    return Subtitle-Core\Get-SubtitleAssStyle `
        -FontName $SubtitleFontName `
        -FontSize ([int]$SubtitleFontSize) `
        -PrimaryColor $SubtitleColor `
        -OutlineColor $SubtitleOutlineColor `
        -Outline ([int]$SubtitleOutline) `
        -MarginV $marginV
}

function Get-SubtitleFontPath {
    if ([string]::IsNullOrWhiteSpace($SubtitleFontFile)) { return '' }
    if ([IO.Path]::IsPathRooted($SubtitleFontFile)) { return $SubtitleFontFile }
    return (Join-Path $PSScriptRoot $SubtitleFontFile)
}

function Get-SubtitleSplitOptions {
    return @{
        FontName = $SubtitleFontName
        FontFile = Get-SubtitleFontPath
        FontSize = [int]$SubtitleFontSize
        FrameWidth = [int]$targetWidth
        FrameHeight = [int]$targetHeight
        Outline = [int]$SubtitleOutline
        SafeWidthPercent = 94
        MaxChars = [int]$SubtitleMaxCharsPerLine
        MinChars = [int]$SubtitleMinChars
    }
}

function Assert-TwoLineSubtitleFile {
    param(
        [Parameter(Mandatory = $true)][string]$SubtitlePath,
        [Parameter(Mandatory = $true)][double]$Duration,
        [string]$Stage = '字幕'
    )
    if (-not (Test-Path -LiteralPath $SubtitlePath -PathType Leaf)) {
        throw "$Stage验证失败：字幕文件不存在：$SubtitlePath"
    }

    $raw = [IO.File]::ReadAllText($SubtitlePath, [Text.Encoding]::UTF8)
    foreach ($block in [regex]::Split($raw.Trim(), '(\r?\n){2,}')) {
        if ([string]::IsNullOrWhiteSpace($block)) { continue }
        $lines = @($block -split '\r?\n')
        if ($lines.Count -lt 3 -or $lines.Count -gt 4) {
            throw "$Stage验证失败：SRT字幕块格式无效。"
        }
        $textLines = @($lines | Select-Object -Skip 2)
        if ($textLines.Count -gt 2 -or ($textLines | Where-Object { [string]::IsNullOrWhiteSpace($_) -or $_ -match '\\[Nn]|\t' })) {
            throw "$Stage验证失败：字幕最多两行，且不能包含空行、制表符或ASS换行标记。"
        }
    }

    # Existing SRT events must retain their exact end time during validation.
    try {
        $segments = @(Subtitle-Core\Convert-SrtToSegments `
            -SrtPath $SubtitlePath `
            -SplitOptions (Get-SubtitleSplitOptions) `
            -MinimumDuration 0.0 `
            -PreserveEvents)
    } catch {
        throw "$Stage验证失败：$($_.Exception.Message)"
    }
    if ($segments.Count -eq 0) {
        throw "$Stage验证失败：字幕不能为空。"
    }

    $check = Subtitle-Core\Test-SubtitleSegments -Segments $segments -SplitOptions (Get-SubtitleSplitOptions)
    if (-not $check.Success) {
        throw "$Stage验证失败：$($check.Message)"
    }
    foreach ($segment in $segments) {
        if ([double]$segment.Start -lt 0 -or [double]$segment.End -gt ($Duration + 0.05)) {
            throw "$Stage验证失败：字幕时间超出音频时长。"
        }
    }
    return $true
}

function Repair-SubtitleFile {
    param(
        [Parameter(Mandatory = $true)][string]$SubtitlePath,
        [Parameter(Mandatory = $true)][double]$Duration,
        [string]$Stage = '字幕'
    )
    # Do not extend a repaired final event past the audio duration.
    $rawSegments = @(Subtitle-Core\Convert-SrtToSegments `
        -SrtPath $SubtitlePath `
        -SplitOptions (Get-SubtitleSplitOptions) `
        -MinimumDuration 0.0 `
        -PreserveEvents)
    $repairedSegments = @(Subtitle-Core\Repair-SubtitleSegments `
        -Segments $rawSegments `
        -Duration $Duration `
        -SplitOptions (Get-SubtitleSplitOptions))
    if ($repairedSegments.Count -eq 0) {
        throw "$Stage修复失败：没有可用字幕段。"
    }
    Subtitle-Core\New-SrtFromSegments -Segments $repairedSegments -Destination $SubtitlePath
    Convert-SrtToSimplified $SubtitlePath
    Write-Log "$Stage已自动裁正异常时间轴与超宽字幕段：$($rawSegments.Count) -> $($repairedSegments.Count)"
}

function Clamp-SrtTimelineToAudio {
    param(
        [Parameter(Mandatory = $true)][string]$SubtitlePath,
        [Parameter(Mandatory = $true)][double]$Duration
    )
    $raw = [IO.File]::ReadAllText($SubtitlePath, [Text.Encoding]::UTF8)
    $blocks = New-Object Collections.ArrayList
    $previousEnd = 0.0
    foreach ($block in [regex]::Split($raw.Trim(), '(\r?\n){2,}')) {
        if ([string]::IsNullOrWhiteSpace($block)) { continue }
        $lines = @($block -split '\r?\n')
        if ($lines.Count -lt 3) { continue }
        $timeMatch = [regex]::Match($lines[1], '^\s*(.+?)\s*-->\s*(.+?)\s*$')
        if (-not $timeMatch.Success) { throw 'SRT字幕块时间格式无效。' }
        $start = Convert-SrtTimeToSeconds $timeMatch.Groups[1].Value
        $end = Convert-SrtTimeToSeconds $timeMatch.Groups[2].Value
        if ($null -eq $start -or $null -eq $end) { throw 'SRT字幕块时间格式无效。' }
        $start = [Math]::Min($Duration, [Math]::Max(0.0, [double]$start))
        $end = [Math]::Min($Duration, [Math]::Max(0.0, [double]$end))
        $start = [Math]::Max($start, $previousEnd)
        if ($end -le $start) { continue }
        $textLines = @($lines | Select-Object -Skip 2)
        if ($textLines.Count -eq 0 -or ($textLines | Where-Object { [string]::IsNullOrWhiteSpace($_) })) { continue }
        $index = $blocks.Count + 1
        [void]$blocks.Add(("{0}`r`n{1} --> {2}`r`n{3}" -f $index, (Convert-SecondsToSrtTime $start), (Convert-SecondsToSrtTime $end), ($textLines -join "`r`n")))
        $previousEnd = $end
    }
    if ($blocks.Count -eq 0) { throw 'SRT字幕修复后没有可用时间段。' }
    [IO.File]::WriteAllText($SubtitlePath, ($blocks -join "`r`n`r`n"), [Text.UTF8Encoding]::new($true))
    return $blocks.Count
}

function Save-SubtitleDiagnosticJson {
    param([string]$DiagnosticsDir, [string]$Name, $Data)
    if ([string]::IsNullOrWhiteSpace($DiagnosticsDir)) { return }
    try {
        Ensure-Directory $DiagnosticsDir
        $path = Join-Path $DiagnosticsDir $Name
        $json = $Data | ConvertTo-Json -Depth 100
        [IO.File]::WriteAllText($path, $json, [Text.UTF8Encoding]::new($true))
        Write-Log "字幕诊断已保存：$path"
    } catch {
        Write-Log "字幕诊断保存失败：$Name；$($_.Exception.Message)"
    }
}

function Save-SubtitleDiagnosticCopy {
    param([string]$DiagnosticsDir, [string]$Name, [string]$SourcePath)
    if ([string]::IsNullOrWhiteSpace($DiagnosticsDir) -or -not (Test-Path -LiteralPath $SourcePath -PathType Leaf)) { return }
    try {
        Ensure-Directory $DiagnosticsDir
        $path = Join-Path $DiagnosticsDir $Name
        Copy-Item -LiteralPath $SourcePath -Destination $path -Force
        Write-Log "字幕诊断已保存：$path"
    } catch {
        Write-Log "字幕诊断保存失败：$Name；$($_.Exception.Message)"
    }
}

function Prepare-PortableFontDirectory($AudioWork) {
    $localFonts = Join-Path $AudioWork 'fonts'
    Ensure-Directory $localFonts
    $selectedFont = Get-SubtitleFontPath
    if (-not [string]::IsNullOrWhiteSpace($selectedFont) -and (Test-Path -LiteralPath $selectedFont -PathType Leaf)) {
        Copy-Item -LiteralPath $selectedFont -Destination $localFonts -Force | Out-Null
    }
}

function Split-SubtitleLine($Text, [int]$MaxChars) {
    if ($MaxChars -le 0 -or $Text.Length -le $MaxChars) {
        return @($Text)
    }
    $result = @()
    $remaining = $Text
    while ($remaining.Length -gt $MaxChars) {
        $result += $remaining.Substring(0, $MaxChars)
        $remaining = $remaining.Substring($MaxChars)
    }
    if ($remaining.Length -gt 0) {
        $result += $remaining
    }
    return $result
}

function Convert-SrtTimeToSeconds($TimeText) {
    $match = [regex]::Match($TimeText, "^\s*(\d{2}):(\d{2}):(\d{2}),(\d{3})\s*$")
    if (-not $match.Success) {
        return $null
    }
    return ([int]$match.Groups[1].Value * 3600) + ([int]$match.Groups[2].Value * 60) + [int]$match.Groups[3].Value + ([int]$match.Groups[4].Value / 1000.0)
}

function Convert-SecondsToSrtTime([double]$Seconds) {
    if ($Seconds -lt 0) {
        $Seconds = 0
    }
    $ts = [TimeSpan]::FromSeconds($Seconds)
    return "{0:00}:{1:00}:{2:00},{3:000}" -f [int][Math]::Floor($ts.TotalHours), $ts.Minutes, $ts.Seconds, $ts.Milliseconds
}

function Get-OneLineSubtitleLimit {
    if ($SubtitleMaxCharsPerLine -ne $null -and [int]$SubtitleMaxCharsPerLine -gt 0) {
        return [int]$SubtitleMaxCharsPerLine
    }
    if ($targetWidth -le 1080) {
        return 10
    }
    return 18
}

function Split-SrtBlockToOneLineBlocks($Index, $TimeLine, $Text, [int]$MaxChars) {
    $timeMatch = [regex]::Match($TimeLine, "^\s*(.+?)\s*-->\s*(.+?)\s*$")
    if (-not $timeMatch.Success) {
        return @("$Index`r`n$TimeLine`r`n$Text")
    }

    $startSeconds = Convert-SrtTimeToSeconds $timeMatch.Groups[1].Value
    $endSeconds = Convert-SrtTimeToSeconds $timeMatch.Groups[2].Value
    if ($startSeconds -eq $null -or $endSeconds -eq $null -or $endSeconds -le $startSeconds) {
        return @("$Index`r`n$TimeLine`r`n$Text")
    }

    $chunks = @(Split-SubtitleLine $Text $MaxChars)
    if ($chunks.Count -le 1) {
        return @("$Index`r`n$TimeLine`r`n$Text")
    }

    $duration = $endSeconds - $startSeconds
    $totalWeight = ($chunks | ForEach-Object { [Math]::Max(1, $_.Length) } | Measure-Object -Sum).Sum
    $cursor = $startSeconds
    $blocks = @()
    for ($i = 0; $i -lt $chunks.Count; $i += 1) {
        if ($i -eq $chunks.Count - 1) {
            $chunkEnd = $endSeconds
        } else {
            $weight = [Math]::Max(1, $chunks[$i].Length)
            $chunkEnd = $cursor + ($duration * $weight / $totalWeight)
        }
        $blocks += "$Index`r`n$(Convert-SecondsToSrtTime $cursor) --> $(Convert-SecondsToSrtTime $chunkEnd)`r`n$($chunks[$i])"
        $cursor = $chunkEnd
    }
    return $blocks
}

function Convert-SrtToSimplifiedWithWindows($SrtPath) {
    try {
        Add-Type -AssemblyName Microsoft.VisualBasic -ErrorAction SilentlyContinue
        $text = [IO.File]::ReadAllText($SrtPath, [Text.Encoding]::UTF8)
        $converted = [Microsoft.VisualBasic.Strings]::StrConv(
            $text,
            [Microsoft.VisualBasic.VbStrConv]::SimplifiedChinese,
            2052
        )
        [IO.File]::WriteAllText($SrtPath, $converted, [Text.UTF8Encoding]::new($true))
        Write-Host "Windows 内置简体转换完成。"
    } catch {
        Write-Host "Windows 内置简体转换失败，继续使用原字幕：$($_.Exception.Message)" -ForegroundColor Yellow
    }
}

function Format-SrtLineLength($SrtPath) {
    if (-not (Test-Path -LiteralPath $SrtPath)) {
        return
    }
    $segments = @(Subtitle-Core\Convert-SrtToSegments `
        -SrtPath $SrtPath `
        -SplitOptions (Get-SubtitleSplitOptions) `
        -MinimumDuration ([double]$SubtitleMinimumDuration))
    Subtitle-Core\New-SrtFromSegments -Segments $segments -Destination $SrtPath
}

function Get-SidecarTextPath($AudioFile) {
    $textPath = Join-Path $AudioFile.DirectoryName "$($AudioFile.BaseName).txt"
    if (Test-Path -LiteralPath $textPath -PathType Leaf) {
        return $textPath
    }
    return $null
}

function Read-SubtitleTextFile($TextPath) {
    $bytes = [IO.File]::ReadAllBytes($TextPath)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        return [Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3)
    }
    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
        return [Text.Encoding]::Unicode.GetString($bytes, 2, $bytes.Length - 2)
    }
    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
        return [Text.Encoding]::BigEndianUnicode.GetString($bytes, 2, $bytes.Length - 2)
    }
    try {
        $strictUtf8 = [Text.UTF8Encoding]::new($false, $true)
        return $strictUtf8.GetString($bytes)
    } catch {
        return [Text.Encoding]::Default.GetString($bytes)
    }
}

function Split-TextToSubtitleChunks($Text) {
    $splitOptions = Get-SubtitleSplitOptions
    return @(Subtitle-Core\Split-SubtitleText -Text $Text @splitOptions)
}

function New-SrtFromTextFile($TextPath, [double]$Duration, $DestinationSrt) {
    $text = Read-SubtitleTextFile $TextPath
    $chunks = @(Split-TextToSubtitleChunks $text)
    if ($chunks.Count -eq 0) {
        throw "文本稿为空，无法生成字幕：$TextPath"
    }

    $totalWeight = ($chunks | ForEach-Object { [Math]::Max(1, $_.Length) } | Measure-Object -Sum).Sum
    $cursor = 0.0
    $blocks = @()
    for ($i = 0; $i -lt $chunks.Count; $i += 1) {
        if ($i -eq $chunks.Count - 1) {
            $end = $Duration
        } else {
            $weight = [Math]::Max(1, $chunks[$i].Length)
            $end = $cursor + ($Duration * $weight / $totalWeight)
        }
        if ($end -le $cursor) {
            $end = [Math]::Min($Duration, $cursor + 0.1)
        }
        $blocks += ("{0}`r`n{1} --> {2}`r`n{3}" -f ($i + 1), (Convert-SecondsToSrtTime $cursor), (Convert-SecondsToSrtTime $end), $chunks[$i])
        $cursor = $end
    }

    [IO.File]::WriteAllText($DestinationSrt, ($blocks -join "`r`n`r`n"), [Text.UTF8Encoding]::new($true))
}

function Invoke-WhisperSrt($SourceWav, $DestinationSrt) {
    $runtimeDir = Join-Path $WorkDir "whisper_runtime"
    if (Test-Path -LiteralPath $runtimeDir) {
        Remove-Item -LiteralPath $runtimeDir -Recurse -Force
    }
    Ensure-Directory $runtimeDir

    $asciiRuntime = Join-Path ([IO.Path]::GetTempPath()) ("autocut_whisper_{0}_{1}" -f $PID, (Get-Date -Format "yyyyMMddHHmmssfff"))
    $whisperToolDir = Join-Path $asciiRuntime "whisper_tool"
    Ensure-Directory $asciiRuntime
    Ensure-Directory $whisperToolDir

    $runtimeWav = Join-Path $asciiRuntime "input.wav"
    $runtimeModel = Join-Path $asciiRuntime "model.bin"
    $outputBase = Join-Path $asciiRuntime "subtitles"
    Copy-Item -LiteralPath $SourceWav -Destination $runtimeWav -Force
    Copy-Item -LiteralPath $WhisperModel -Destination $runtimeModel -Force
    Copy-Item -Path (Join-Path $PSScriptRoot "tools\whisper\*") -Destination $whisperToolDir -Recurse -Force
    $runtimeWhisper = Join-Path $whisperToolDir "whisper-cli.exe"

    try {
        Push-Location $whisperToolDir
        try {
            $whisperArgs = @(
                "-m", $runtimeModel,
                "-f", $runtimeWav,
                "-t", "$WhisperThreads",
                "-l", $WhisperLanguage,
                "-osrt",
                "-of", $outputBase,
                "-np"
            )
            $whisperLog = Join-Path $runtimeDir "whisper.log"
            $oldErrorActionPreference = $ErrorActionPreference
            $ErrorActionPreference = "Continue"
            try {
                & $runtimeWhisper @whisperArgs *> $whisperLog
                $whisperExitCode = $LASTEXITCODE
            } finally {
                $ErrorActionPreference = $oldErrorActionPreference
            }
            if ($whisperExitCode -ne 0) {
                throw "识别字幕失败，退出码：$whisperExitCode。日志：$whisperLog"
            }
        } finally {
            Pop-Location
        }

        $runtimeSrt = Join-Path $asciiRuntime "subtitles.srt"
        if (-not (Test-Path -LiteralPath $runtimeSrt)) {
            throw "字幕识别完成但没有生成 SRT 文件。"
        }
        Copy-Item -LiteralPath $runtimeSrt -Destination $DestinationSrt -Force
    } finally {
        Remove-Item -LiteralPath $asciiRuntime -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Convert-SrtToSimplified($SrtPath) {
    if (-not (Test-Path -LiteralPath $SrtPath)) {
        return
    }
    if (-not ((Test-Path -LiteralPath $OpenCC) -and (Test-Path -LiteralPath $OpenCCConfig))) {
        throw "OpenCC 不存在或配置缺失：$OpenCC；$OpenCCConfig"
    }

    $openccRuntime = Join-Path ([IO.Path]::GetTempPath()) ("autocut_opencc_{0}_{1}" -f $PID, (Get-Date -Format "yyyyMMddHHmmssfff"))
    $openccToolDir = Join-Path $openccRuntime "opencc_tool"
    $openccShareDir = Join-Path $openccToolDir "share\opencc"
    try {
        Ensure-Directory $openccRuntime
        Ensure-Directory $openccToolDir
        Ensure-Directory $openccShareDir

        $input = Join-Path $openccRuntime "input.srt"
        $output = Join-Path $openccRuntime "output.srt"
        $openccExe = Join-Path $openccToolDir "opencc.exe"
        $openccConfig = Join-Path $openccShareDir "t2s.json"
        $sourceText = [IO.File]::ReadAllText($SrtPath, [Text.Encoding]::UTF8)
        [IO.File]::WriteAllText($input, $sourceText, [Text.UTF8Encoding]::new($false))
        Copy-Item -Path (Join-Path $PSScriptRoot "tools\opencc\bin\*") -Destination $openccToolDir -Recurse -Force
        Copy-Item -Path (Join-Path $PSScriptRoot "tools\opencc\share\opencc\*") -Destination $openccShareDir -Recurse -Force

        $oldErrorActionPreference = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try {
            & $openccExe -i $input -o $output -c $openccConfig
            $openccExitCode = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $oldErrorActionPreference
        }
        if ($openccExitCode -ne 0) {
            throw "OpenCC 转简体失败，退出码：$openccExitCode"
        }
        if (-not (Test-Path -LiteralPath $output)) {
            throw "OpenCC 没有生成输出文件：$output"
        }
        $convertedText = [IO.File]::ReadAllText($output, [Text.Encoding]::UTF8)
        [IO.File]::WriteAllText($SrtPath, $convertedText, [Text.UTF8Encoding]::new($true))
        Write-Host "OpenCC 简体转换完成。"
    } finally {
        Remove-Item -LiteralPath $openccRuntime -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Get-SubtitleCachePath($AudioFile, [bool]$IsTestMode, $TextFile = $null) {
    $cacheDir = Join-Path $WorkDir "subtitle_cache"
    New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null
    $canonicalAudioPath = [IO.Path]::GetFullPath($AudioFile.FullName).ToLowerInvariant()
    $audioContentHash = (Get-FileHash -LiteralPath $AudioFile.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    $providerStamp = if ($SubtitleSourceMode -eq 'paraformer_local') {
        $workerItem = Get-Item -LiteralPath $ParaformerWorker
        "paraformer_local_timeline_chunks_v1_$ParaformerTimelineChunkSeconds`_$ParaformerTimelineChunkOverlapSeconds`_$($workerItem.Length)_$([int64]$workerItem.LastWriteTimeUtc.Ticks)"
    } else {
        "$SubtitleSourceMode`_aliyun_$AliyunModel"
    }
    if ($TextFile -and (Test-Path -LiteralPath $TextFile)) {
        $textItem = Get-Item -LiteralPath $TextFile
        $textContentHash = (Get-FileHash -LiteralPath $TextFile -Algorithm SHA256).Hash.ToLowerInvariant()
        $stamp = "$canonicalAudioPath`_$audioContentHash`_txt_$textContentHash`_$($textItem.Length)_$([int64]$textItem.LastWriteTimeUtc.Ticks)_$providerStamp"
    } else {
        $stamp = "$canonicalAudioPath`_$audioContentHash`_$providerStamp"
        if ($SubtitleSourceMode -ne 'aliyun_only') {
            $modelFile = Get-Item -LiteralPath $WhisperModel
            $stamp = "$stamp`_$($modelFile.BaseName)_$($modelFile.Length)"
        }
    }
    $layoutStamp = "$SubtitleFontName`_$SubtitleFontSize`_$SubtitleOutline`_$SubtitleMaxCharsPerLine`_$SubtitleMinChars`_94`_$targetWidth`x$targetHeight`_display_no_punctuation_v2"
    $coreItem = Get-Item -LiteralPath (Join-Path $PSScriptRoot 'Subtitle-Core.psm1')
    $coreStamp = "$($coreItem.Length)_$([int64]$coreItem.LastWriteTimeUtc.Ticks)"
    $stamp = "$stamp`_$layoutStamp`_core_$coreStamp"
    if ($IsTestMode) {
        $stamp = "$stamp`_test$TestSeconds"
    }
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        $cacheKey = -join ($sha256.ComputeHash([Text.Encoding]::UTF8.GetBytes($stamp)) | ForEach-Object { $_.ToString('x2') })
    } finally {
        $sha256.Dispose()
    }
    return (Join-Path $cacheDir "$(Safe-Name $AudioFile.BaseName)_$cacheKey.srt")
}

function Test-ParaformerRuntimeReady([ref]$Reason, [string]$DiagnosticsDir = '') {
    $Reason.Value = ''
    if (-not (Test-Path -LiteralPath $ParaformerPython -PathType Leaf)) { $Reason.Value = '未找到本地 Python'; return $false }
    foreach ($modelName in @('iic--speech_seaco_paraformer_large_asr_nat-zh-cn-16k-common-vocab8404-pytorch', 'iic--speech_fsmn_vad_zh-cn-16k-common-pytorch', 'iic--punc_ct-transformer_cn-en-common-vocab471067-large')) {
        $modelFile = Join-Path $ParaformerModelCache ("models\$modelName\snapshots\master\model.pt")
        if (-not (Test-Path -LiteralPath $modelFile -PathType Leaf)) { $Reason.Value = "本地模型缓存缺少：$modelFile"; return $false }
        if ((Get-Item -LiteralPath $modelFile -ErrorAction SilentlyContinue).Length -le 0) { $Reason.Value = "本地模型文件为空：$modelFile"; return $false }
    }
    return $true
}

function Ensure-ParaformerRuntime([string]$DiagnosticsDir = '') {
    if (-not ((Test-Path -LiteralPath $ParaformerWorker) -and (Test-Path -LiteralPath $ParaformerSetup))) {
        throw '本地 Paraformer 组件不完整，请重新安装软件更新包。'
    }
    $readyReason = ''
    $ready = Test-ParaformerRuntimeReady ([ref]$readyReason) $DiagnosticsDir
    if ($ready) { return }

    $setupLog = if ($DiagnosticsDir) { Join-Path $DiagnosticsDir 'paraformer_setup.log' } else { Join-Path $LogDir 'paraformer_setup.log' }
    Write-Log "本地 Paraformer 未就绪：$readyReason"
    Write-Log '本地 Paraformer 首次准备：将下载运行环境和模型到程序目录，完成后可离线使用。'
    & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $ParaformerSetup -RuntimeDir (Join-Path $ParaformerRoot 'runtime') -ModelCacheDir $ParaformerModelCache -WorkerPath $ParaformerWorker -LogPath $setupLog
    if ($LASTEXITCODE -ne 0) { throw "本地 Paraformer 准备失败，详见日志：$setupLog" }
    $readyReason = ''
    if (-not (Test-ParaformerRuntimeReady ([ref]$readyReason) $DiagnosticsDir)) { throw "本地 Paraformer 准备后仍未就绪：$readyReason；详见日志：$setupLog" }
}

function ConvertTo-WindowsCommandLineArgument([string]$Argument) {
    if ($Argument.Length -eq 0) { return '""' }
    if ($Argument -notmatch '[\s"]') { return $Argument }
    $escaped = [regex]::Replace($Argument, '(\\*)"', '$1$1\"')
    $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
    return '"' + $escaped + '"'
}

function Invoke-ParaformerSrt($AudioFile, [double]$Duration, [string]$DestinationSrt, [bool]$IsTestMode, [string]$DiagnosticsDir = '', [int]$TimeoutSeconds = 0) {
    Ensure-ParaformerRuntime $DiagnosticsDir
    $recognitionAudio = $AudioFile.FullName
    if ($IsTestMode) {
        $recognitionAudio = "$DestinationSrt.paraformer.wav"
        Invoke-Checked $Ffmpeg @('-y', '-i', $AudioFile.FullName, '-t', ('{0:0.###}' -f $Duration), '-ar', '16000', '-ac', '1', '-c:a', 'pcm_s16le', $recognitionAudio) '准备 Paraformer 测试音频'
    }
    $rawJson = if ($DiagnosticsDir) { Join-Path $DiagnosticsDir 'paraformer_raw.json' } else { "$DestinationSrt.paraformer.json" }
    $runLog = if ($DiagnosticsDir) { Join-Path $DiagnosticsDir 'paraformer.log' } else { "$DestinationSrt.paraformer.log" }
    $stdout = "$runLog.stdout"
    $stderr = "$runLog.stderr"
    $previousModelScopeCache = $env:MODELSCOPE_CACHE
    $effectiveTimeoutSeconds = if ($TimeoutSeconds -gt 0) { $TimeoutSeconds } else { [Math]::Max(300, [Math]::Ceiling(($Duration * 2) + 120)) }
    $timeoutMilliseconds = [int][Math]::Min([double][int]::MaxValue, ([double]$effectiveTimeoutSeconds * 1000))
    $workerExitCode = -1
    $timedOut = $false
    $process = $null
    $mutex = [Threading.Mutex]::new($false, 'Local\HunJian_Paraformer')
    $mutexAcquired = $false
    try {
        try {
            $mutexAcquired = $mutex.WaitOne([TimeSpan]::FromSeconds($effectiveTimeoutSeconds))
        } catch [Threading.AbandonedMutexException] {
            $mutexAcquired = $true
        }
        if (-not $mutexAcquired) { throw "等待其他 Paraformer 任务超时（$effectiveTimeoutSeconds 秒）。" }
        $env:MODELSCOPE_CACHE = $ParaformerModelCache
        $workerArguments = @($ParaformerWorker, '--audio', $recognitionAudio, '--srt', $DestinationSrt, '--json', $rawJson)
        $workerArgumentString = ($workerArguments | ForEach-Object { ConvertTo-WindowsCommandLineArgument $_ }) -join ' '
        $process = Start-Process -FilePath $ParaformerPython -ArgumentList $workerArgumentString -PassThru -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr
        $null = $process.Handle
        if ($process.WaitForExit($timeoutMilliseconds)) {
            $process.WaitForExit()
            $process.Refresh()
            $workerExitCode = $process.ExitCode
        } else {
            $timedOut = $true
            try { $process.Kill() } catch {}
            try { $process.WaitForExit(5000) | Out-Null } catch {}
        }
    } finally {
        $output = @()
        foreach ($stream in @($stdout, $stderr)) {
            if (Test-Path -LiteralPath $stream -PathType Leaf) { $output += [IO.File]::ReadAllText($stream, [Text.UTF8Encoding]::new($false)) }
        }
        [IO.File]::WriteAllText($runLog, ($output -join [Environment]::NewLine), [Text.UTF8Encoding]::new($true))
        if ($null -eq $previousModelScopeCache) { Remove-Item Env:MODELSCOPE_CACHE -ErrorAction SilentlyContinue }
        else { $env:MODELSCOPE_CACHE = $previousModelScopeCache }
        if ($mutexAcquired) { try { $mutex.ReleaseMutex() } catch {} }
        $mutex.Dispose()
        Remove-Item -LiteralPath $stdout,$stderr -Force -ErrorAction SilentlyContinue
    }
    if ($timedOut) { throw "Paraformer 识别超时（$effectiveTimeoutSeconds 秒），详见日志：$runLog" }
    if ($workerExitCode -ne 0 -or -not (Test-Path -LiteralPath $DestinationSrt)) {
        if (-not (Test-Path -LiteralPath $runLog) -or (Get-Item -LiteralPath $runLog).Length -eq 0) {
            [IO.File]::WriteAllText($runLog, "Paraformer 识别失败，退出码：$workerExitCode", [Text.UTF8Encoding]::new($true))
        }
        throw "Paraformer 识别失败（退出码：$workerExitCode），详见日志：$runLog"
    }
}

function Invoke-ParaformerBatch($Entries, [double]$Duration, [string]$DiagnosticsDir = '', [int]$TimeoutSeconds = 0) {
    if (@($Entries).Count -eq 0) { throw 'Paraformer 批量识别没有输入音频。' }
    Ensure-ParaformerRuntime $DiagnosticsDir
    $batchDirectory = if ($DiagnosticsDir) { $DiagnosticsDir } else { $LogDir }
    New-Item -ItemType Directory -Force -Path $batchDirectory | Out-Null
    $manifestPath = Join-Path $batchDirectory 'paraformer_batch_manifest.json'
    $runLog = Join-Path $batchDirectory 'paraformer_batch.log'
    $stdout = "$runLog.stdout"
    $stderr = "$runLog.stderr"
    $manifest = @($Entries | ForEach-Object {
        [ordered]@{ audio = $_.Audio; srt = $_.Srt; json = $_.Json }
    })
    [IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 4), [Text.UTF8Encoding]::new($false))

    $previousModelScopeCache = $env:MODELSCOPE_CACHE
    $effectiveTimeoutSeconds = if ($TimeoutSeconds -gt 0) { $TimeoutSeconds } else { [Math]::Max(300, [Math]::Ceiling(($Duration * 2) + 300)) }
    $timeoutMilliseconds = [int][Math]::Min([double][int]::MaxValue, ([double]$effectiveTimeoutSeconds * 1000))
    $workerExitCode = -1
    $timedOut = $false
    $process = $null
    $mutex = [Threading.Mutex]::new($false, 'Local\HunJian_Paraformer')
    $mutexAcquired = $false
    try {
        try { $mutexAcquired = $mutex.WaitOne([TimeSpan]::FromSeconds($effectiveTimeoutSeconds)) }
        catch [Threading.AbandonedMutexException] { $mutexAcquired = $true }
        if (-not $mutexAcquired) { throw "等待其他 Paraformer 任务超时（$effectiveTimeoutSeconds 秒）。" }
        $env:MODELSCOPE_CACHE = $ParaformerModelCache
        $workerArguments = @($ParaformerWorker, '--batch-manifest', $manifestPath)
        $workerArgumentString = ($workerArguments | ForEach-Object { ConvertTo-WindowsCommandLineArgument $_ }) -join ' '
        $process = Start-Process -FilePath $ParaformerPython -ArgumentList $workerArgumentString -PassThru -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr
        $null = $process.Handle
        if ($process.WaitForExit($timeoutMilliseconds)) {
            $process.WaitForExit()
            $process.Refresh()
            $workerExitCode = $process.ExitCode
        } else {
            $timedOut = $true
            try { $process.Kill() } catch {}
            try { $process.WaitForExit(5000) | Out-Null } catch {}
        }
    } finally {
        $output = @()
        foreach ($stream in @($stdout, $stderr)) {
            if (Test-Path -LiteralPath $stream -PathType Leaf) { $output += [IO.File]::ReadAllText($stream, [Text.UTF8Encoding]::new($false)) }
        }
        [IO.File]::WriteAllText($runLog, ($output -join [Environment]::NewLine), [Text.UTF8Encoding]::new($true))
        if ($null -eq $previousModelScopeCache) { Remove-Item Env:MODELSCOPE_CACHE -ErrorAction SilentlyContinue }
        else { $env:MODELSCOPE_CACHE = $previousModelScopeCache }
        if ($mutexAcquired) { try { $mutex.ReleaseMutex() } catch {} }
        $mutex.Dispose()
        Remove-Item -LiteralPath $stdout,$stderr -Force -ErrorAction SilentlyContinue
    }
    if ($timedOut) { throw "Paraformer 批量识别超时（$effectiveTimeoutSeconds 秒），详见日志：$runLog" }
    if ($workerExitCode -ne 0) { throw "Paraformer 批量识别失败（退出码：$workerExitCode），详见日志：$runLog" }
    foreach ($entry in @($Entries)) {
        if (-not (Test-Path -LiteralPath $entry.Srt -PathType Leaf)) { throw "Paraformer 批量识别缺少字幕结果：$($entry.Srt)；详见日志：$runLog" }
    }
}

function Merge-ParaformerChunkSrt($Chunks, [string]$DestinationSrt) {
    $merged = @()
    foreach ($chunk in @($Chunks)) {
        $merged += @(Subtitle-Core\Convert-SrtToSegments -SrtPath $chunk.Srt -PreserveEvents | Where-Object {
            $globalStart = $_.Start + $chunk.Start
            $globalEnd = $_.End + $chunk.Start
            ($globalEnd -gt $chunk.KeepStart) -and ($globalStart -lt $chunk.KeepEnd)
        } | ForEach-Object {
            [pscustomobject]@{
                Start = [Math]::Max([double]$chunk.KeepStart, $_.Start + $chunk.Start)
                End = [Math]::Min([double]$chunk.KeepEnd, $_.End + $chunk.Start)
                Text = $_.Text
            }
        })
    }
    $merged = @($merged | Where-Object { $_.End -gt $_.Start } | Sort-Object Start, End)
    if ($merged.Count -eq 0) { throw 'Paraformer 分段识别没有返回字幕。' }
    Subtitle-Core\New-SrtFromSegments -Segments $merged -Destination $DestinationSrt
}

function Invoke-ChunkedParaformerSrt($AudioFile, [double]$Duration, [string]$DestinationSrt, [string]$DiagnosticsDir = '') {
    $chunkSeconds = [Math]::Max(30.0, [double]$ParaformerTimelineChunkSeconds)
    $overlapSeconds = [Math]::Min(5.0, [Math]::Max(0.0, [double]$ParaformerTimelineChunkOverlapSeconds))
    $chunkDir = Join-Path (Split-Path -Parent $DestinationSrt) 'paraformer_chunks'
    New-Item -ItemType Directory -Force -Path $chunkDir | Out-Null
    $chunks = @()
    for ($offset = 0.0; $offset -lt $Duration; $offset += $chunkSeconds) {
        $start = [Math]::Max(0.0, $offset - $overlapSeconds)
        $end = [Math]::Min($Duration, $offset + $chunkSeconds + $overlapSeconds)
        $index = [int][Math]::Floor($offset / $chunkSeconds) + 1
        $chunkAudio = Join-Path $chunkDir ("audio_{0:D3}.wav" -f $index)
        $chunkSrt = Join-Path $chunkDir ("subtitles_{0:D3}.srt" -f $index)
        $chunkJson = Join-Path $chunkDir ("subtitles_{0:D3}.json" -f $index)
        Invoke-Checked $Ffmpeg @('-y', '-ss', ('{0:0.###}' -f $start), '-t', ('{0:0.###}' -f ($end - $start)), '-i', $AudioFile.FullName, '-ar', '16000', '-ac', '1', '-c:a', 'pcm_s16le', $chunkAudio) ("准备 Paraformer 字幕块 {0}" -f $index)
        Write-Log ("Paraformer 时间轴分段：第 {0} 块，{1:N2} - {2:N2} 秒" -f $index, $start, $end)
        $chunks += [pscustomobject]@{ Audio = $chunkAudio; Srt = $chunkSrt; Json = $chunkJson; Start = $start; KeepStart = $offset; KeepEnd = [Math]::Min($Duration, $offset + $chunkSeconds) }
    }
    $batchDiagnosticsDir = if ($DiagnosticsDir) { $DiagnosticsDir } else { $chunkDir }
    Invoke-ParaformerBatch $chunks $Duration $batchDiagnosticsDir
    Merge-ParaformerChunkSrt $chunks $DestinationSrt
}

function Prepare-Subtitle($AudioFile, [double]$Duration, $DestinationSrt, [bool]$IsTestMode, [string]$DiagnosticsDir = '') {
    if ($SubtitleSourceMode -notin @('paraformer_local', 'aliyun_only', 'aliyun_fallback', 'text_preferred')) {
        throw "字幕来源模式无效：$SubtitleSourceMode。允许值：paraformer_local、aliyun_only、aliyun_fallback、text_preferred。"
    }
    $textPath = if ($SubtitleSourceMode -eq 'text_preferred') { Get-SidecarTextPath $AudioFile } else { $null }
    $cachePath = Get-SubtitleCachePath $AudioFile $IsTestMode $textPath
    $cacheValidationFailure = $null
    if (Test-Path -LiteralPath $cachePath) {
        try {
            Copy-Item -LiteralPath $cachePath -Destination $DestinationSrt -Force
            Assert-TwoLineSubtitleFile -SubtitlePath $DestinationSrt -Duration $Duration -Stage '字幕缓存'
            Write-Host "使用字幕缓存。"
            Write-Log '字幕缓存：已复用，不重复识别。'
            return $true
        } catch {
            Remove-Item -LiteralPath $cachePath -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $DestinationSrt -Force -ErrorAction SilentlyContinue
            $cacheValidationFailure = $_.Exception.Message
            Write-Log "字幕缓存验证失败，已删除并重新识别：$($_.Exception.Message)"
        }
    }

    $preferredText = ''
    if ($textPath) {
        $preferredText = Read-SubtitleTextFile $textPath
        Write-Log "检测到同名文本稿，将优先使用文本稿文字：$textPath"
    }

    if ($SubtitleSourceMode -eq 'paraformer_local') {
        Write-Log '字幕来源：本地 Paraformer-large'
        if (-not $IsTestMode -and $Duration -gt [double]$ParaformerTimelineChunkSeconds) {
            Invoke-ChunkedParaformerSrt $AudioFile $Duration $DestinationSrt $DiagnosticsDir
        } else {
            Invoke-ParaformerSrt $AudioFile $Duration $DestinationSrt $IsTestMode $DiagnosticsDir
        }
        $segments = @(Subtitle-Core\Convert-SrtToSegments -SrtPath $DestinationSrt -SplitOptions (Get-SubtitleSplitOptions) -MinimumDuration ([double]$SubtitleMinimumDuration))
        $segments = @(Subtitle-Core\Limit-SubtitleSegments -Segments $segments -Duration $Duration)
        $segments = @(Subtitle-Core\Repair-SubtitleSegments -Segments $segments -Duration $Duration -SplitOptions (Get-SubtitleSplitOptions))
        if ($segments.Count -eq 0) { throw 'Paraformer 返回的字幕结果无效。' }
        Subtitle-Core\New-SrtFromSegments -Segments $segments -Destination $DestinationSrt
        Clamp-SrtTimelineToAudio -SubtitlePath $DestinationSrt -Duration $Duration | Out-Null
        Assert-TwoLineSubtitleFile -SubtitlePath $DestinationSrt -Duration $Duration -Stage 'Paraformer字幕'
        Copy-Item -LiteralPath $DestinationSrt -Destination $cachePath -Force
        return $true
    }

    if ($SubtitleSourceMode -eq 'aliyun_only' -or $AliyunSubtitlesEnabled) {
        try {
            $apiKey = Get-AliyunApiKey
            if ([string]::IsNullOrWhiteSpace($apiKey)) {
                throw '严格阿里云模式需要先配置API Key。'
            }
            $cloudAudio = $AudioFile.FullName
            if ($IsTestMode) {
                $cloudAudio = $whisperWav
                Invoke-Checked $Ffmpeg @(
                    '-y', '-i', $AudioFile.FullName,
                    '-t', ('{0:0.###}' -f $Duration),
                    '-ar', '16000', '-ac', '1', '-c:a', 'pcm_s16le',
                    $cloudAudio
                ) '准备阿里云测试音频'
            }
            Write-Log '字幕来源：正在调用阿里云 Paraformer（每条音频仅一次）'
            $segments = @()
            for ($aliyunAttempt = 1; $aliyunAttempt -le 2; $aliyunAttempt += 1) {
                $aliyunResult = Invoke-AliyunTranscription -AudioPath $cloudAudio -ApiKey $apiKey -Endpoint $AliyunEndpoint -Model $AliyunModel -TimeoutMinutes ([int]$AliyunTimeoutMinutes)
                Save-SubtitleDiagnosticJson -DiagnosticsDir $DiagnosticsDir -Name 'aliyun_raw.json' -Data $aliyunResult
                try {
                    $segments = @(Subtitle-Core\Convert-AliyunResultToSegments `
                        -AliyunResult $aliyunResult `
                        -PreferredText $preferredText `
                        -SplitOptions (Get-SubtitleSplitOptions) `
                        -MinimumDuration ([double]$SubtitleMinimumDuration) `
                        -AudioDuration $Duration)
                    break
                } catch {
                    if ($aliyunAttempt -ge 2) { throw }
                    Write-Log "阿里云时间轴异常，正在重新识别（第 $aliyunAttempt 次失败）：$($_.Exception.Message)"
                }
            }
            Save-SubtitleDiagnosticJson -DiagnosticsDir $DiagnosticsDir -Name 'segments_before_repair.json' -Data $segments
            $segments = @(Subtitle-Core\Limit-SubtitleSegments -Segments $segments -Duration $Duration)
            $segments = @(Subtitle-Core\Repair-SubtitleSegments -Segments $segments -Duration $Duration -SplitOptions (Get-SubtitleSplitOptions))
            if ($segments.Count -eq 0) { throw '阿里云返回的字幕结果无效。' }
            Save-SubtitleDiagnosticJson -DiagnosticsDir $DiagnosticsDir -Name 'segments_after_repair.json' -Data $segments
            Subtitle-Core\New-SrtFromSegments -Segments $segments -Destination $DestinationSrt
            Convert-SrtToSimplified $DestinationSrt
            Save-SubtitleDiagnosticCopy -DiagnosticsDir $DiagnosticsDir -Name 'subtitles_before_clamp.srt' -SourcePath $DestinationSrt
            Clamp-SrtTimelineToAudio -SubtitlePath $DestinationSrt -Duration $Duration | Out-Null
            Save-SubtitleDiagnosticCopy -DiagnosticsDir $DiagnosticsDir -Name 'subtitles_after_clamp.srt' -SourcePath $DestinationSrt
            Save-SubtitleDiagnosticJson -DiagnosticsDir $DiagnosticsDir -Name 'timeline_summary.json' -Data ([pscustomobject]@{ AudioDurationSeconds = $Duration; Attempt = $aliyunAttempt; SegmentCount = $segments.Count; GeneratedAt = (Get-Date).ToString('o') })
            try {
                Assert-TwoLineSubtitleFile -SubtitlePath $DestinationSrt -Duration $Duration -Stage '阿里云字幕'
            } catch {
                Write-Log "阿里云字幕首次验证异常，正在自动修复：$($_.Exception.Message)"
                Repair-SubtitleFile -SubtitlePath $DestinationSrt -Duration $Duration -Stage '阿里云字幕'
                Clamp-SrtTimelineToAudio -SubtitlePath $DestinationSrt -Duration $Duration | Out-Null
                Assert-TwoLineSubtitleFile -SubtitlePath $DestinationSrt -Duration $Duration -Stage '阿里云字幕修复后'
            }
            Copy-Item -LiteralPath $DestinationSrt -Destination $cachePath -Force
            if ($textPath) {
                Write-Log '字幕来源：TXT文稿 + 阿里云时间轴'
            } else {
                Write-Log '字幕来源：阿里云识别'
            }
            return $true
        } catch {
            if ($SubtitleSourceMode -eq 'aliyun_only') {
                throw "严格阿里云字幕失败：$($_.Exception.Message)"
            }
            Write-Log "阿里云字幕失败，自动回退本地Whisper：$($_.Exception.Message)"
            Write-Host "阿里云字幕失败，自动回退本地Whisper：$($_.Exception.Message)" -ForegroundColor Yellow
        }
    }

    if (-not ((Test-Path -LiteralPath $Whisper) -and (Test-Path -LiteralPath $WhisperModel))) {
        if ($textPath) {
            Write-Log '阿里云和Whisper均不可用，使用文本稿按时长分配的兜底字幕。'
            New-SrtFromTextFile $textPath $Duration $DestinationSrt
            Convert-SrtToSimplified $DestinationSrt
            Format-SrtLineLength $DestinationSrt
            Assert-TwoLineSubtitleFile -SubtitlePath $DestinationSrt -Duration $Duration -Stage '文本稿字幕'
            Copy-Item -LiteralPath $DestinationSrt -Destination $cachePath -Force
            return $true
        }
        if ($cacheValidationFailure) {
            throw "字幕生成失败：缓存验证失败后无法重新生成合格字幕：$cacheValidationFailure"
        }
        Write-Host "字幕工具或模型不存在，本次只合成视频。"
        return $false
    }

    Write-Log '字幕来源：本地Whisper回退'
    if ($IsTestMode) {
        $wavArgs = @(
            "-y",
            "-i", $AudioFile.FullName,
            "-t", ("{0:0.###}" -f $Duration),
            "-ar", "16000",
            "-ac", "1",
            "-c:a", "pcm_s16le",
            $whisperWav
        )
    } else {
        $wavArgs = @(
            "-y",
            "-i", $AudioFile.FullName,
            "-ar", "16000",
            "-ac", "1",
            "-c:a", "pcm_s16le",
            $whisperWav
        )
    }
    Invoke-Checked $Ffmpeg $wavArgs "转换字幕识别音频"
    Invoke-WhisperSrt $whisperWav $DestinationSrt

    if (Test-Path -LiteralPath $DestinationSrt) {
        try {
            $segments = @(Subtitle-Core\Convert-SrtToSegments `
                -SrtPath $DestinationSrt `
                -PreferredText $preferredText `
                -SplitOptions (Get-SubtitleSplitOptions) `
                -MinimumDuration ([double]$SubtitleMinimumDuration))
            $segments = @(Subtitle-Core\Limit-SubtitleSegments -Segments $segments -Duration $Duration)
            Subtitle-Core\New-SrtFromSegments -Segments $segments -Destination $DestinationSrt
            if ($textPath) {
                Write-Log '字幕来源：TXT文稿 + Whisper时间轴'
            }
        } catch {
            Write-Log "Whisper字幕重新排版失败，使用原SRT安全拆分：$($_.Exception.Message)"
            Format-SrtLineLength $DestinationSrt
        }
        Convert-SrtToSimplified $DestinationSrt
        Assert-TwoLineSubtitleFile -SubtitlePath $DestinationSrt -Duration $Duration -Stage 'Whisper字幕'
        Copy-Item -LiteralPath $DestinationSrt -Destination $cachePath -Force
        return $true
    }

    if ($cacheValidationFailure) {
        throw "字幕生成失败：缓存验证失败后无法重新生成合格字幕：$cacheValidationFailure"
    }
    return $false
}

function Prepare-SubtitleForRender($AudioFile, [double]$Duration, $DestinationSrt, [bool]$IsTestMode, $AudioWork) {
    $useSubtitle = $false
    if ($EnableSubtitles) {
        $useSubtitle = Prepare-Subtitle $AudioFile $Duration $DestinationSrt $IsTestMode $AudioWork
        if ($useSubtitle) { Prepare-PortableFontDirectory $AudioWork }
    }
    return [bool]$useSubtitle
}

function New-ShuffledVideoBag($Videos) {
    $bag = @($Videos)
    for ($i = $bag.Count - 1; $i -gt 0; $i -= 1) {
        $j = $random.Next(0, $i + 1)
        $tmp = $bag[$i]
        $bag[$i] = $bag[$j]
        $bag[$j] = $tmp
    }
    return $bag
}

function New-ClipPlanItem($Source, [double]$Start, [double]$Duration, [bool]$IsImage) {
    return [pscustomobject]@{
        Source = $Source
        Start = $Start
        Duration = $Duration
        IsImage = $IsImage
        Motion = $random.Next(0, 2)
        Brightness = $random.Next(-2, 3) / 100.0
        Contrast = 1 + ($random.Next(-3, 4) / 100.0)
        Saturation = 1 + ($random.Next(-6, 7) / 100.0)
        AtmosphereEffect = Select-AtmosphereEffect
        AtmosphereVariant = $random.Next(0, 12)
        Crop = ''
    }
}

function Get-NonOverlappingClipStart([string]$SourcePath, [double]$SourceDuration, [double]$TakeSeconds, $PlannedClips) {
    if ($TakeSeconds -le 0 -or $SourceDuration + 0.0001 -lt $TakeSeconds) { return $null }
    $ranges = @()
    $cursor = 0.0
    $usedClips = @($PlannedClips | Where-Object { $_.Source.FullName -eq $SourcePath } | Sort-Object Start)
    foreach ($usedClip in $usedClips) {
        $usedStart = [Math]::Max(0.0, [double]$usedClip.Start)
        $usedEnd = [Math]::Min($SourceDuration, $usedStart + [double]$usedClip.Duration)
        if ($usedStart - $cursor + 0.0001 -ge $TakeSeconds) {
            $ranges += [pscustomobject]@{ Start = $cursor; End = $usedStart }
        }
        $cursor = [Math]::Max($cursor, $usedEnd)
    }
    if ($SourceDuration - $cursor + 0.0001 -ge $TakeSeconds) {
        $ranges += [pscustomobject]@{ Start = $cursor; End = $SourceDuration }
    }
    if ($ranges.Count -eq 0) { return $null }

    # Pick an edge of the largest free range. Remaining capacity stays contiguous,
    # so random starts cannot fragment a long source into unusable pieces.
    $range = @($ranges | Sort-Object { $_.End - $_.Start } -Descending | Select-Object -First 1)[0]
    $maxStart = [double]$range.End - $TakeSeconds
    if ($maxStart -le [double]$range.Start + 0.0001) { return [double]$range.Start }
    if ($random.Next(0, 2) -eq 0) { return [double]$range.Start }
    return $maxStart
}

function Get-ClipPlan($Videos, [double]$TargetDuration) {
    $remaining = $TargetDuration
    $usedSources = @{}
    $clips = @()
    $attempts = 0
    $maxAttempts = [Math]::Max(200, $Videos.Count * 30)
    $videoBag = @()
    $bagIndex = 0
    $imageSources = @($Videos | Where-Object { Test-IsImageSource $_ })
    if ($imageSources.Count -eq $Videos.Count) {
        $requiredImages = [int][Math]::Ceiling($TargetDuration / [double]$ImageDurationSeconds)
        if ($requiredImages -gt $imageSources.Count) {
            throw "图片素材不足：当前音频需要 $requiredImages 张不同图片（每张 $ImageDurationSeconds 秒），实际只有 $($imageSources.Count) 张。"
        }
    }

    while ($remaining -gt 0.05) {
        $attempts += 1
        if ($attempts -gt $maxAttempts) {
            throw "无法找到可用视频片段，请检查视频素材和取材方式设置。"
        }
        if ($bagIndex -ge $videoBag.Count) {
            $videoBag = @(New-ShuffledVideoBag $Videos)
            $bagIndex = 0
        }
        $source = $videoBag[$bagIndex]
        $bagIndex += 1
        $isImage = Test-IsImageSource $source
        if ($isImage -and $usedSources.ContainsKey($source.FullName)) {
            continue
        }
        if ($ClipMode -eq "whole" -and $usedSources.ContainsKey($source.FullName) -and $usedSources.Count -lt $Videos.Count) {
            continue
        }

        if ($isImage) {
            $takeSeconds = [Math]::Min([double]$ImageDurationSeconds, $remaining)
            $start = 0
            $usedSources[$source.FullName] = $true
        } else {
            try {
                $sourceDuration = Get-DurationSeconds $source.FullName
            } catch {
                Write-Host "跳过损坏或不可读视频：$($source.Name)"
                continue
            }
            if ($sourceDuration -lt 0.5) {
                Write-Host "跳过过短视频：$($source.Name)"
                continue
            }

            if ($ClipMode -eq "whole") {
            $takeSeconds = [Math]::Min($remaining, $sourceDuration)
            $start = 0
            $usedSources[$source.FullName] = $true
            } else {
            if ([int]$MinClipSeconds -eq [int]$MaxClipSeconds) {
                $clipSeconds = [double]$MaxClipSeconds
            } else {
                $clipSeconds = $random.Next($MinClipSeconds * 1000, ($MaxClipSeconds * 1000) + 1) / 1000.0
            }
            $clipSeconds = [Math]::Min($clipSeconds, $remaining)
            if ($sourceDuration + 0.05 -lt $clipSeconds) {
                if ($ClipMode -eq "short" -and $sourceDuration + 0.05 -ge [double]$MinimumShortClipSeconds) {
                    # Short-video mode keeps the source intact instead of discarding it.
                    $takeSeconds = [Math]::Min($remaining, $sourceDuration)
                    $start = Get-NonOverlappingClipStart $source.FullName $sourceDuration $takeSeconds $clips
                } else {
                    Write-Host "跳过过短视频：$($source.Name)，需要 $clipSeconds 秒，实际 $sourceDuration 秒"
                    continue
                }
            } else {
                $takeSeconds = $clipSeconds
                $start = Get-NonOverlappingClipStart $source.FullName $sourceDuration $takeSeconds $clips
            }
            }
        }

        if ($null -eq $start) { continue }
        if (-not (Test-SourceSegmentUnused $source.FullName $start $takeSeconds $clips)) {
            continue
        }
        $newClip = New-ClipPlanItem $source $start $takeSeconds $isImage
        $clips += $newClip
        $remaining -= $takeSeconds
    }

    return $clips
}

function Get-ClipVisualFilter($InputIndex, $Clip, $Width, $Height, $AspectValue, $FrameRate) {
    $clipDuration = [Math]::Max(0.1, [double]$Clip.Duration).ToString('0.###', $InvariantCulture)
    $sourcePrefix = "[$InputIndex`:v]"
    if ($Clip.Crop) { $sourcePrefix += "crop=$($Clip.Crop)," }
    $atmosphere = if ($Clip.IsImage) { Get-AtmosphereEffectFilters $Clip $Width $Height } else { '' }
    $tail = "${atmosphere}setsar=1,fps=$FrameRate,trim=duration=$clipDuration,setpts=PTS-STARTPTS,format=yuv420p[v$InputIndex]"
    if (-not $Clip.IsImage -or -not $EnableImageEffects) {
        return "${sourcePrefix}scale='if(gte(iw/ih,$AspectValue),-2,$Width)':'if(gte(iw/ih,$AspectValue),$Height,-2)',crop=${Width}:${Height},$tail"
    }
    $imageFrames = [Math]::Max(1, [int][Math]::Round([double]$Clip.Duration * $FrameRate))
    # Keep the image anchored at center. Slow pan offsets round to integer pixels in FFmpeg
    # and visibly jump on long stills; centered scale keyframes remain continuously smooth.
    $motionAmount = [Math]::Min(0.16, [Math]::Max(0.08, [double]$Clip.Duration * 0.005)).ToString('0.###', $InvariantCulture)
    # Perspective evaluates a floating-point transform for every frame, like a position/scale keyframe animation.
    if ([int]$Clip.Motion -eq 0) {
        $zoom = "1+${motionAmount}*on/$imageFrames"
        return "${sourcePrefix}scale=${Width}:${Height}:force_original_aspect_ratio=increase,crop=${Width}:${Height},perspective=x0='W/2-W/(2*($zoom))':y0='H/2-H/(2*($zoom))':x1='W/2+W/(2*($zoom))':y1='H/2-H/(2*($zoom))':x2='W/2-W/(2*($zoom))':y2='H/2+H/(2*($zoom))':x3='W/2+W/(2*($zoom))':y3='H/2+H/(2*($zoom))':interpolation=cubic:eval=frame,$tail"
    }
    if ([int]$Clip.Motion -eq 1) {
        $zoom = "1+$motionAmount-${motionAmount}*on/$imageFrames"
        return "${sourcePrefix}scale=${Width}:${Height}:force_original_aspect_ratio=increase,crop=${Width}:${Height},perspective=x0='W/2-W/(2*($zoom))':y0='H/2-H/(2*($zoom))':x1='W/2+W/(2*($zoom))':y1='H/2-H/(2*($zoom))':x2='W/2-W/(2*($zoom))':y2='H/2+H/(2*($zoom))':x3='W/2+W/(2*($zoom))':y3='H/2+H/(2*($zoom))':interpolation=cubic:eval=frame,$tail"
    }
    $progress = "min(1,t/$clipDuration)"
    switch ([int]$Clip.Motion) {
        0 { $x = "(in_w-out_w)*$progress"; $y = "(in_h-out_h)/2" }
        1 { $x = "(in_w-out_w)*(1-$progress)"; $y = "(in_h-out_h)/2" }
        2 { $x = "(in_w-out_w)/2"; $y = "(in_h-out_h)*$progress" }
        3 { $x = "(in_w-out_w)/2"; $y = "(in_h-out_h)*(1-$progress)" }
    }
    if ([int]$Clip.Motion -eq 4) {
        return "[$InputIndex`:v]scale=w='ceil($zoomWidth*(1+0.08*$progress)/2)*2':h='ceil($zoomHeight*(1+0.08*$progress)/2)*2':force_original_aspect_ratio=increase:eval=frame,crop=${Width}:${Height}:x='(in_w-out_w)/2':y='(in_h-out_h)/2',$tail"
    }
    if ([int]$Clip.Motion -eq 5) {
        return "[$InputIndex`:v]scale=w='ceil($zoomWidth*1.08*(1-0.08*$progress)/2)*2':h='ceil($zoomHeight*1.08*(1-0.08*$progress)/2)*2':force_original_aspect_ratio=increase:eval=frame,crop=${Width}:${Height}:x='(in_w-out_w)/2':y='(in_h-out_h)/2',$tail"
    }
    return "${sourcePrefix}scale=${zoomWidth}:${zoomHeight}:force_original_aspect_ratio=increase,crop=${Width}:${Height}:x='$x':y='$y',$tail"
}

function Get-RenderChunks($Clips, [int]$MaxClips = 24) {
    if ($MaxClips -lt 1) { throw '每个渲染块至少需要一个素材。' }
    $items = @($Clips)
    $chunks = @()
    $offset = 0.0
    for ($start = 0; $start -lt $items.Count; $start += $MaxClips) {
        $end = [Math]::Min($items.Count - 1, $start + $MaxClips - 1)
        $chunkClips = @($items[$start..$end])
        $duration = [double](($chunkClips | Measure-Object -Property Duration -Sum).Sum)
        $chunks += [pscustomobject]@{
            Index = $chunks.Count + 1
            Offset = $offset
            Duration = $duration
            Clips = $chunkClips
        }
        $offset += $duration
    }
    return $chunks
}

function Write-RenderChunkSubtitle([string]$SubtitlePath, [string]$Destination, [double]$Offset, [double]$Duration) {
    $end = $Offset + $Duration
    $segments = @(Subtitle-Core\Convert-SrtToSegments -SrtPath $SubtitlePath -PreserveEvents | Where-Object { $_.End -gt $Offset -and $_.Start -lt $end } | ForEach-Object {
        [pscustomobject]@{
            Start = [Math]::Max($_.Start, $Offset) - $Offset
            End = [Math]::Min($_.End, $end) - $Offset
            Text = $_.Text
        }
    })
    if ($segments.Count -eq 0) { return $false }
    Subtitle-Core\New-SrtFromSegments -Segments $segments -Destination $Destination
    return $true
}

function Invoke-RenderVideoChunk($Chunk, [string]$OutputPath, [string]$ChunkSubtitlePath, [bool]$UseSubtitle) {
    $args = @('-hide_banner', '-loglevel', 'error', '-stats_period', '5', '-stats', '-y')
    foreach ($clip in $Chunk.Clips) {
        if ($clip.IsImage) {
            $args += @('-loop', '1', '-framerate', "$Fps", '-t', ('{0:0.###}' -f $clip.Duration), '-i', $clip.Source.FullName)
        } else {
            $args += @('-ss', ('{0:0.###}' -f $clip.Start), '-t', ('{0:0.###}' -f $clip.Duration), '-i', $clip.Source.FullName)
        }
    }
    $filterParts = @()
    $concatInputs = ''
    for ($i = 0; $i -lt $Chunk.Clips.Count; $i += 1) {
        $filterParts += Get-ClipVisualFilter $i $Chunk.Clips[$i] $targetWidth $targetHeight $aspect $Fps
        $concatInputs += "[v$i]"
    }
    $filterParts += "${concatInputs}concat=n=$($Chunk.Clips.Count):v=1:a=0[vcat]"
    if ($UseSubtitle) {
        $style = Get-SubtitleStyle
        $filterParts += "[vcat]subtitles=$([IO.Path]::GetFileName($ChunkSubtitlePath)):fontsdir=fonts:force_style='$style'[vout]"
    } else {
        $filterParts += '[vcat]null[vout]'
    }
    $filterScriptPath = Join-Path $audioWork ("filter_chunk_{0}_{1}.ffscript" -f $Chunk.Index, ([guid]::NewGuid().ToString('N')))
    [IO.File]::WriteAllText($filterScriptPath, ($filterParts -join ';'), [Text.UTF8Encoding]::new($false))
    $args += @('-filter_complex_script', $filterScriptPath, '-map', '[vout]') + $encodeArgs + @('-an', '-movflags', '+faststart', $OutputPath)
    Push-Location $audioWork
    try {
        Invoke-Checked $Ffmpeg $args ("生成长音频视频块 {0}" -f $Chunk.Index)
    } finally {
        Pop-Location
        Remove-Item -LiteralPath $filterScriptPath -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-ChunkedSinglePassRender($Clips, $AudioPath, $OutputPath, $SubtitlePath, [bool]$UseSubtitle) {
    $chunks = @(Get-RenderChunks $Clips 24)
    $chunkDir = Join-Path $audioWork 'render_chunks'
    Ensure-Directory $chunkDir
    $chunkVideos = @()
    foreach ($chunk in $chunks) {
        $chunkVideo = Join-Path $chunkDir ("chunk_{0:D4}.mp4" -f $chunk.Index)
        $chunkSubtitle = Join-Path $audioWork ("chunk_subtitles_{0:D4}.srt" -f $chunk.Index)
        $chunkHasSubtitle = $UseSubtitle -and (Write-RenderChunkSubtitle $SubtitlePath $chunkSubtitle $chunk.Offset $chunk.Duration)
        Write-Host ("  长音频块 {0}/{1}：{2} 个素材，{3:N2} 秒" -f $chunk.Index, $chunks.Count, $chunk.Clips.Count, $chunk.Duration)
        Invoke-RenderVideoChunk $chunk $chunkVideo $chunkSubtitle $chunkHasSubtitle
        $chunkVideos += $chunkVideo
    }
    $concatList = Join-Path $audioWork 'render_chunks_concat.txt'
    $concatVideo = Join-Path $audioWork 'render_chunks_video.mp4'
    $concatLines = foreach ($chunkVideo in $chunkVideos) { "file '$((Escape-ConcatPath $chunkVideo))'" }
    [IO.File]::WriteAllLines($concatList, $concatLines, [Text.UTF8Encoding]::new($false))
    Invoke-Checked $Ffmpeg @('-y', '-f', 'concat', '-safe', '0', '-i', $concatList, '-c', 'copy', $concatVideo) '合并长音频视频块'
    $outputDuration = (($Clips | Measure-Object -Property Duration -Sum).Sum).ToString('0.###', $InvariantCulture)
    Invoke-Checked $Ffmpeg @('-y', '-i', $concatVideo, '-i', $AudioPath, '-map', '0:v:0', '-map', '1:a:0', '-c:v', 'copy', '-c:a', 'aac', '-b:a', $AudioBitrate, '-t', $outputDuration, '-movflags', '+faststart', $OutputPath) '合成长音频成片'
}

function Invoke-SinglePassRender($Clips, $AudioPath, $OutputPath, $SubtitlePath, [bool]$UseSubtitle) {
    if (-not $Clips -or $Clips.Count -eq 0) {
        throw "没有可用视频片段。"
    }
    if ($Clips.Count -gt 24) {
        Invoke-ChunkedSinglePassRender $Clips $AudioPath $OutputPath $SubtitlePath $UseSubtitle
        return
    }

    $args = @("-y")
    $outputDuration = (($Clips | Measure-Object -Property Duration -Sum).Sum).ToString('0.###', $InvariantCulture)
    foreach ($clip in $Clips) {
        if ($clip.IsImage) {
            $args += @("-loop", "1", "-framerate", "$Fps", "-t", ("{0:0.###}" -f $clip.Duration), "-i", $clip.Source.FullName)
        } else {
            $args += @("-ss", ("{0:0.###}" -f $clip.Start), "-t", ("{0:0.###}" -f $clip.Duration), "-i", $clip.Source.FullName)
        }
    }
    $audioInputIndex = $Clips.Count
    $args += @("-i", $AudioPath)

    $filterParts = @()
    $concatInputs = ""
    for ($i = 0; $i -lt $Clips.Count; $i += 1) {
        $filterParts += Get-ClipVisualFilter $i $Clips[$i] $targetWidth $targetHeight $aspect $Fps
        $concatInputs += "[v$i]"
    }

    if ($UseSubtitle) {
        $localSubtitle = Join-Path $audioWork "subtitles.srt"
        if ((Resolve-Path -LiteralPath $SubtitlePath).Path -ne (Resolve-Path -LiteralPath $localSubtitle -ErrorAction SilentlyContinue).Path) {
            Copy-Item -LiteralPath $SubtitlePath -Destination $localSubtitle -Force
        }
        $style = Get-SubtitleStyle
        $filterParts += "${concatInputs}concat=n=$($Clips.Count):v=1:a=0[vcat]"
        $filterParts += "[vcat]subtitles=subtitles.srt:fontsdir=fonts:force_style='$style'[vout]"
    } else {
        $filterParts += "${concatInputs}concat=n=$($Clips.Count):v=1:a=0[vout]"
    }

    $filterScriptPath = Join-Path $audioWork ("filter_{0}.ffscript" -f ([guid]::NewGuid().ToString('N')))
    [IO.File]::WriteAllText($filterScriptPath, ($filterParts -join ";"), (New-Object System.Text.UTF8Encoding($false)))
    $args += @(
        "-filter_complex_script", $filterScriptPath,
        "-map", "[vout]",
        "-map", "$audioInputIndex`:a:0"
    )
    $args += $encodeArgs
    $args += @(
        "-c:a", "aac",
        "-b:a", $AudioBitrate,
        "-t", $outputDuration,
        "-shortest",
        "-movflags", "+faststart",
        $OutputPath
    )

    Push-Location $audioWork
    try {
        Invoke-Checked $Ffmpeg $args "单次快速成片"
    } finally {
        Pop-Location
        Remove-Item -LiteralPath $filterScriptPath -Force -ErrorAction SilentlyContinue
    }
}

function Get-RenderJobTimeoutSeconds([double]$AudioDuration) {
    return [int][Math]::Min(43200, [Math]::Max(1800, [Math]::Ceiling(($AudioDuration * 3) + 600)))
}

function Start-RenderJob($RenderIndex, $RenderCount, $Clips, $AudioPath, $OutputPath, $SubtitlePath, [bool]$UseSubtitle) {
    $clipData = @($Clips | ForEach-Object {
        [pscustomobject]@{
            Source = $_.Source.FullName
            Name = $_.Source.Name
            Start = $_.Start
            Duration = $_.Duration
            IsImage = $_.IsImage
            Motion = $_.Motion
            Brightness = $_.Brightness
            Contrast = $_.Contrast
            Saturation = $_.Saturation
            Atmosphere = if ($_.IsImage) { Get-AtmosphereEffectFilters $_ $targetWidth $targetHeight } else { '' }
        }
    })
    $jobLog = Join-Path $LogDir ("run_{0}_{1:D2}.job.log" -f $RunStamp, $RenderIndex)
    $scriptBlock = {
        param(
            $RenderIndex,
            $RenderCount,
            $ClipData,
            $AudioPath,
            $OutputPath,
            $SubtitlePath,
            $UseSubtitle,
            $Ffmpeg,
            $AudioWork,
            $TargetWidth,
            $TargetHeight,
            $Aspect,
            $Fps,
            $EncodeArgs,
            $AudioBitrate,
            $SubtitleStyle,
            $JobLog,
            $EnableImageEffects
        )

        function Add-JobLogLineSafe($Path, $Line) {
            for ($attempt = 1; $attempt -le 20; $attempt += 1) {
                try {
                    Add-Content -LiteralPath $Path -Value $Line -Encoding UTF8 -ErrorAction Stop
                    return
                } catch {
                    Start-Sleep -Milliseconds (50 * $attempt)
                }
            }
            Write-Host "日志写入失败：$Path" -ForegroundColor Red
        }

        function JobLog($Message) {
            $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
            Write-Host $Message
            Add-JobLogLineSafe $JobLog $line
        }

        function Get-JobClipVisualFilter($InputIndex, $Clip) {
            $clipDuration = [Math]::Max(0.1, [double]$Clip.Duration).ToString('0.###', [Globalization.CultureInfo]::InvariantCulture)
            $tail = "$($Clip.Atmosphere)setsar=1,fps=$Fps,trim=duration=$clipDuration,setpts=PTS-STARTPTS,format=yuv420p[v$InputIndex]"
            if (-not $Clip.IsImage -or -not $EnableImageEffects) {
                return "[$InputIndex`:v]scale='if(gte(iw/ih,$Aspect),-2,$TargetWidth)':'if(gte(iw/ih,$Aspect),$TargetHeight,-2)',crop=${TargetWidth}:${TargetHeight},$tail"
            }
            $imageFrames = [Math]::Max(1, [int][Math]::Round([double]$Clip.Duration * $Fps))
            # Mirror the main renderer: centered keyframe zoom avoids integer crop jitter.
            $motionAmount = [Math]::Min(0.16, [Math]::Max(0.08, [double]$Clip.Duration * 0.005)).ToString('0.###', [Globalization.CultureInfo]::InvariantCulture)
            if ([int]$Clip.Motion -eq 0) {
                $zoom = "1+${motionAmount}*on/$imageFrames"
                return "[$InputIndex`:v]scale=${TargetWidth}:${TargetHeight}:force_original_aspect_ratio=increase,crop=${TargetWidth}:${TargetHeight},perspective=x0='W/2-W/(2*($zoom))':y0='H/2-H/(2*($zoom))':x1='W/2+W/(2*($zoom))':y1='H/2-H/(2*($zoom))':x2='W/2-W/(2*($zoom))':y2='H/2+H/(2*($zoom))':x3='W/2+W/(2*($zoom))':y3='H/2+H/(2*($zoom))':interpolation=cubic:eval=frame,$tail"
            }
            if ([int]$Clip.Motion -eq 1) {
                $zoom = "1+$motionAmount-${motionAmount}*on/$imageFrames"
                return "[$InputIndex`:v]scale=${TargetWidth}:${TargetHeight}:force_original_aspect_ratio=increase,crop=${TargetWidth}:${TargetHeight},perspective=x0='W/2-W/(2*($zoom))':y0='H/2-H/(2*($zoom))':x1='W/2+W/(2*($zoom))':y1='H/2-H/(2*($zoom))':x2='W/2-W/(2*($zoom))':y2='H/2+H/(2*($zoom))':x3='W/2+W/(2*($zoom))':y3='H/2+H/(2*($zoom))':interpolation=cubic:eval=frame,$tail"
            }
            $progress = "min(1,t/$clipDuration)"
            switch ([int]$Clip.Motion) {
                0 { $x = "(in_w-out_w)*$progress"; $y = "(in_h-out_h)/2" }
                1 { $x = "(in_w-out_w)*(1-$progress)"; $y = "(in_h-out_h)/2" }
                2 { $x = "(in_w-out_w)/2"; $y = "(in_h-out_h)*$progress" }
                3 { $x = "(in_w-out_w)/2"; $y = "(in_h-out_h)*(1-$progress)" }
            }
            if ([int]$Clip.Motion -eq 4) {
                return "[$InputIndex`:v]scale=w='ceil($zoomWidth*(1+0.08*$progress)/2)*2':h='ceil($zoomHeight*(1+0.08*$progress)/2)*2':force_original_aspect_ratio=increase:eval=frame,crop=${TargetWidth}:${TargetHeight}:x='(in_w-out_w)/2':y='(in_h-out_h)/2',$tail"
            }
            if ([int]$Clip.Motion -eq 5) {
                return "[$InputIndex`:v]scale=w='ceil($zoomWidth*1.08*(1-0.08*$progress)/2)*2':h='ceil($zoomHeight*1.08*(1-0.08*$progress)/2)*2':force_original_aspect_ratio=increase:eval=frame,crop=${TargetWidth}:${TargetHeight}:x='(in_w-out_w)/2':y='(in_h-out_h)/2',$tail"
            }
            return "[$InputIndex`:v]scale=${zoomWidth}:${zoomHeight}:force_original_aspect_ratio=increase,crop=${TargetWidth}:${TargetHeight}:x='$x':y='$y',$tail"
        }

        JobLog ("生成第 {0}/{1} 个视频..." -f $RenderIndex, $RenderCount)
        foreach ($clip in $ClipData) {
            JobLog ("  计划片段: {0} 秒 - {1}" -f ("{0:N2}" -f [double]$clip.Duration), $clip.Name)
        }

        $args = @("-hide_banner", "-loglevel", "error", "-stats_period", "5", "-stats", "-y")
        $outputDuration = (($ClipData | Measure-Object -Property Duration -Sum).Sum).ToString('0.###', [Globalization.CultureInfo]::InvariantCulture)
        foreach ($clip in $ClipData) {
            if ($clip.IsImage) {
                $args += @("-loop", "1", "-framerate", "$Fps", "-t", ("{0:0.###}" -f [double]$clip.Duration), "-i", $clip.Source)
            } else {
                $args += @("-ss", ("{0:0.###}" -f [double]$clip.Start), "-t", ("{0:0.###}" -f [double]$clip.Duration), "-i", $clip.Source)
            }
        }
        $audioInputIndex = $ClipData.Count
        $args += @("-i", $AudioPath)

        $filterParts = @()
        $concatInputs = ""
        for ($i = 0; $i -lt $ClipData.Count; $i += 1) {
            $filterParts += Get-JobClipVisualFilter $i $ClipData[$i]
            $concatInputs += "[v$i]"
        }

        if ($UseSubtitle) {
            $localSubtitle = Join-Path $AudioWork "subtitles.srt"
            $sourceSubtitlePath = (Resolve-Path -LiteralPath $SubtitlePath).Path
            $targetSubtitlePath = $null
            if (Test-Path -LiteralPath $localSubtitle) {
                $targetSubtitlePath = (Resolve-Path -LiteralPath $localSubtitle).Path
            }
            if ($sourceSubtitlePath -ne $targetSubtitlePath) {
                Copy-Item -LiteralPath $SubtitlePath -Destination $localSubtitle -Force
            }
            $style = $SubtitleStyle
            $filterParts += "${concatInputs}concat=n=$($ClipData.Count):v=1:a=0[vcat]"
            $filterParts += "[vcat]subtitles=subtitles.srt:fontsdir=fonts:force_style='$style'[vout]"
        } else {
            $filterParts += "${concatInputs}concat=n=$($ClipData.Count):v=1:a=0[vout]"
        }

        $filterScriptPath = Join-Path $AudioWork ("filter_{0}_{1}.ffscript" -f $RenderIndex, ([guid]::NewGuid().ToString('N')))
        [IO.File]::WriteAllText($filterScriptPath, ($filterParts -join ";"), (New-Object System.Text.UTF8Encoding($false)))
        $args += @(
            "-filter_complex_script", $filterScriptPath,
            "-map", "[vout]",
            "-map", "$audioInputIndex`:a:0"
        )
        $args += $EncodeArgs
        $tempOutputPath = "$OutputPath.part.mp4"
        if (Test-Path -LiteralPath $tempOutputPath) {
            Remove-Item -LiteralPath $tempOutputPath -Force
        }

        $args += @(
            "-c:a", "aac",
            "-b:a", $AudioBitrate,
            "-t", $outputDuration,
            "-shortest",
            "-movflags", "+faststart",
            $tempOutputPath
        )

        Push-Location $AudioWork
        try {
            $outputParentName = Split-Path -Leaf (Split-Path -Parent $OutputPath)
            $renderLogDir = Join-Path (Join-Path (Split-Path -Parent $JobLog) "ffmpeg") $outputParentName
            New-Item -ItemType Directory -Force -Path $renderLogDir | Out-Null
            $ffmpegLog = Join-Path $renderLogDir ("{0}_{1}.ffmpeg.log" -f [IO.Path]::GetFileNameWithoutExtension($OutputPath), (Get-Date -Format "yyyyMMdd_HHmmss"))
            & $Ffmpeg @args *> $ffmpegLog
            if ($LASTEXITCODE -ne 0) {
                throw "FFmpeg 退出码：$LASTEXITCODE，日志：$ffmpegLog"
            }
            Move-Item -LiteralPath $tempOutputPath -Destination $OutputPath -Force
            JobLog "完成：$OutputPath"
        } catch {
            JobLog "失败：$OutputPath"
            JobLog $_.Exception.Message
            if (Test-Path -LiteralPath $tempOutputPath) {
                Remove-Item -LiteralPath $tempOutputPath -Force -ErrorAction SilentlyContinue
            }
            throw
        } finally {
            Pop-Location
            Remove-Item -LiteralPath $filterScriptPath -Force -ErrorAction SilentlyContinue
        }
    }

    return Start-Job -ScriptBlock $scriptBlock -ArgumentList @(
        $RenderIndex,
        $RenderCount,
        $clipData,
        $AudioPath,
        $OutputPath,
        $SubtitlePath,
        $UseSubtitle,
        $Ffmpeg,
        $audioWork,
        $targetWidth,
        $targetHeight,
        $aspect,
        $Fps,
        $encodeArgs,
        $AudioBitrate,
        (Get-SubtitleStyle),
        $jobLog,
        $EnableImageEffects
    )
}

Assert-File $Ffmpeg "ffmpeg"
Assert-File $Ffprobe "ffprobe"

foreach ($dir in @($VideoDir, $AudioDir, $OutputDir, $WorkDir, $LogDir, $BackupDir)) {
    Ensure-Directory $dir
}
Clear-UnimportantLogs
Remove-ExpiredWorkDirectories $WorkDir ([int]$FailedWorkRetentionHours)
Write-Log "运行开始：$RunStamp"
Write-Log "程序版本：$AutoCutVersion"
Write-Log "日志文件：$LogFile"
Backup-Software

$videos = Get-ChildItem -LiteralPath $VideoDir -File -Recurse |
    Where-Object { ($VideoExts + $ImageExts) -contains (Get-LowerExtension $_) }
$videos = @(Select-VideoSources $videos)
if ($AudioFile) {
    if (-not (Test-Path -LiteralPath $AudioFile)) {
        throw "指定音频不存在：$AudioFile"
    }
    $audioItem = Get-Item -LiteralPath $AudioFile
    if (-not ($AudioExts -contains (Get-LowerExtension $audioItem))) {
        throw "指定文件不是支持的音频格式：$AudioFile"
    }
    $audios = @($audioItem)
} else {
    $audios = Get-ChildItem -LiteralPath $AudioDir -File -Recurse |
        Where-Object { $AudioExts -contains (Get-LowerExtension $_) }
}

if (-not $videos) {
    throw "素材为空，请把视频或图片放到：$VideoDir"
}
if (-not $audios) {
    throw "音频素材为空，请把音频放到：$AudioDir"
}
if ($TestMode) {
    $audios = @($audios | Select-Object -First 1)
}

$target = Get-TargetSize $videos
$targetWidth = [int]$target.Width
$targetHeight = [int]$target.Height
$aspect = ($targetWidth / $targetHeight).ToString("0.############", $InvariantCulture)

Write-Log "视频素材：$(@($videos | Where-Object { -not (Test-IsImageSource $_) }).Count) 个；图片素材：$(@($videos | Where-Object { Test-IsImageSource $_ }).Count) 个"
Write-Log "音频素材：$($audios.Count) 个"
Write-Log "输出规格：$targetWidth x $targetHeight ($($target.Label))"
Write-Log "字幕功能：$EnableSubtitles"
Write-Log "字幕模型：$WhisperModel"
Write-Log "字幕设置：字号=$SubtitleFontSize，颜色=$SubtitleColor，描边=$SubtitleOutline，每行最多=$SubtitleMaxCharsPerLine，底部距离=$SubtitleMarginV"
if ($TestMode) {
    Write-Log "测试模式：只处理第一个音频的约 $TestSeconds 秒"
} else {
    Write-Log "每条音频生成：$VideosPerAudio 个视频，并发：$ParallelRenders"
}
Write-Log ""

$random = [Random]::new()
$runStamp = Get-Date -Format "yyyyMMdd_HHmmss"
$videoEncoder = Get-VideoEncoder
$encodeArgs = Get-EncodeArgs $videoEncoder
Write-Log "视频编码器：$videoEncoder"
Write-Log ""

foreach ($audio in $audios) {
    $audioBase = Safe-Name $audio.BaseName
    $audioOutputDir = Join-Path $OutputDir (Get-AudioOutputFolderName $audioBase)
    $audioWork = Join-Path $WorkDir "$audioBase`_$runStamp"
    $stagedOutputDir = if ($TestMode -or -not $FastSinglePass) { $audioOutputDir } else { Join-Path $audioWork "completed_set" }
    $segmentsDir = Join-Path $audioWork "segments"
    $concatList = Join-Path $audioWork "concat.txt"
    $concatVideo = Join-Path $audioWork "video_concat.mp4"
    $subtitleBase = Join-Path $audioWork "subtitles"
    $subtitleSrt = "$subtitleBase.srt"
    $whisperWav = Join-Path $audioWork "whisper.wav"
    $renderCount = if ($TestMode) { 1 } else { [int]$VideosPerAudio }

    Write-Log "开始处理：$($audio.FullName)"
    Ensure-Directory $segmentsDir
    Ensure-Directory $stagedOutputDir
    Prepare-AtmosphereFont $audioWork

    try {
        $audioDuration = Get-DurationSeconds $audio.FullName
    } catch {
        Write-ErrorLog "读取音频时长失败：$($audio.FullName)；$($_.Exception.Message)"
        throw
    }
    if ($TestMode) {
        $audioDuration = [Math]::Min([double]$TestSeconds, $audioDuration)
    }
    if ($audioDuration -le 0) {
        Write-Host "音频时长异常，跳过：$($audio.Name)"
        continue
    }

    Write-Host "开始处理：$($audio.Name)"
    Write-Host ("音频时长：{0:N2} 秒" -f $audioDuration)

    $useSubtitle = Prepare-SubtitleForRender $audio $audioDuration $subtitleSrt $TestMode $audioWork
    $output = Join-Path $stagedOutputDir (Get-OutputVideoFileName $audioBase 1 $renderCount $TestMode $TestSeconds)

    if ($FastSinglePass) {
        $retryRounds = if ($null -eq $SupplementRetryRounds) { 3 } else { [Math]::Max(0, [int]$SupplementRetryRounds) }
        $maxRenderRounds = 1 + $retryRounds
        $pendingIndexes = @(1..$renderCount)

        for ($renderRound = 1; $renderRound -le $maxRenderRounds -and $pendingIndexes.Count -gt 0; $renderRound += 1) {
            if ($renderRound -eq 1) {
                Write-Log "开始生成 $renderCount 条视频。"
            } else {
                Write-Log ("检测到成品不足，开始第 {0}/{1} 轮自动补剪；待补编号：{2}" -f ($renderRound - 1), $retryRounds, ($pendingIndexes -join ", "))
            }

            $roundIndexes = @($pendingIndexes)
            $batchSize = if ($TestMode) { 1 } else { [Math]::Max(1, [int]$ParallelRenders) }
            for ($batchStart = 0; $batchStart -lt $roundIndexes.Count; $batchStart += $batchSize) {
                $batchEnd = [Math]::Min($roundIndexes.Count - 1, $batchStart + $batchSize - 1)
                $batchIndexes = @($roundIndexes[$batchStart..$batchEnd])
                $jobs = @()

                foreach ($renderIndex in $batchIndexes) {
                    $output = Join-Path $stagedOutputDir (Get-OutputVideoFileName $audioBase $renderIndex $renderCount $TestMode $TestSeconds)

                    if ((Test-ValidOutputVideo $output) -and -not $OverwriteOutput) {
                        continue
                    }
                    try {
                        $clipPlan = @(Get-ClipPlan $videos $audioDuration)
                        for ($planIndex = 0; $planIndex -lt $clipPlan.Count; $planIndex += 1) {
                            $clip = $clipPlan[$planIndex]
                            Write-Log ("第 {0}/{1} 个视频 - 计划片段 {2}: {3} 秒 - {4}" -f $renderIndex, $renderCount, ($planIndex + 1), ("{0:N2}" -f $clip.Duration), $clip.Source.Name)
                        }

                        if ($TestMode -or $batchSize -le 1 -or $clipPlan.Count -gt 24) {
                            if ($clipPlan.Count -gt 24) {
                                Write-Log ("长音频分段渲染：$($clipPlan.Count) 个素材，每块最多 24 个素材。")
                            }
                            Write-Log ("生成第 {0}/{1} 个视频..." -f $renderIndex, $renderCount)
                            Invoke-SinglePassRender $clipPlan $audio.FullName $output $subtitleSrt $useSubtitle
                            Write-Log "完成：$output"
                        } else {
                            $job = Start-RenderJob $renderIndex $renderCount $clipPlan $audio.FullName $output $subtitleSrt $useSubtitle
                            $job | Add-Member -NotePropertyName RenderIndex -NotePropertyValue $renderIndex
                            $job | Add-Member -NotePropertyName RenderStartedAt -NotePropertyValue (Get-Date)
                            $job | Add-Member -NotePropertyName RenderTimeoutSeconds -NotePropertyValue (Get-RenderJobTimeoutSeconds $audioDuration)
                            $jobs += $job
                        }
                    } catch {
                        Write-ErrorLog ("第 {0}/{1} 个视频本轮生成失败，将在检查后补剪：{2}" -f $renderIndex, $renderCount, $_.Exception.Message)
                    }
                }

                foreach ($job in @($jobs)) {
                    while ($job.State -eq "Running" -or $job.State -eq "NotStarted") {
                        if (((Get-Date) - [datetime]$job.RenderStartedAt).TotalSeconds -ge [double]$job.RenderTimeoutSeconds) {
                            Write-ErrorLog ("第 {0}/{1} 个视频渲染超时（{2} 秒），停止该任务后补剪。" -f $job.RenderIndex, $renderCount, $job.RenderTimeoutSeconds)
                            Stop-Job -Job $job -ErrorAction SilentlyContinue
                            break
                        }
                        $done = Wait-Job -Job $job -Timeout 10
                        if ($done) { break }
                        Write-Heartbeat
                    }
                    $jobOutput = Receive-Job -Job $job -ErrorAction SilentlyContinue
                    if ($job.State -ne "Completed") {
                        Write-ErrorLog ("第 {0}/{1} 个视频并发任务失败，将在检查后补剪；状态：{2}" -f $job.RenderIndex, $renderCount, $job.State)
                        if ($jobOutput) {
                            Write-ErrorLog ($jobOutput | Out-String)
                        }
                    }
                    Remove-Job -Job $job -Force
                }
            }

            $pendingIndexes = @()
            for ($renderIndex = 1; $renderIndex -le $renderCount; $renderIndex += 1) {
                $output = Join-Path $stagedOutputDir (Get-OutputVideoFileName $audioBase $renderIndex $renderCount $TestMode $TestSeconds)
                if (-not (Test-ValidOutputVideo $output)) {
                    $pendingIndexes += $renderIndex
                    if (Test-Path -LiteralPath $output) {
                        Remove-Item -LiteralPath $output -Force -ErrorAction SilentlyContinue
                    }
                }
            }
            Write-Log ("本轮检查：合格 {0}/{1} 条，待补剪 {2} 条。" -f ($renderCount - $pendingIndexes.Count), $renderCount, $pendingIndexes.Count)
        }

        if ($pendingIndexes.Count -gt 0) {
            throw "自动补剪 $retryRounds 轮后仍未凑齐 $renderCount 条视频；缺少编号：$($pendingIndexes -join ', ')。成品不发布，源音频保留。"
        }
        if (-not $TestMode) {
            Publish-CompleteVideoFolder $stagedOutputDir $audioOutputDir $renderCount
            Add-TodayCompletedVideoCount $renderCount
        }
        Write-Log "本音频输出目录：$audioOutputDir"
        Write-Log ""
        Remove-SuccessfulWorkDirectory $audioWork $WorkDir
        continue
    }

    $remaining = $audioDuration
    $index = 0
    $segmentPaths = @()
    $clips = @()
    $usedSources = @{}
    $attempts = 0
    $maxAttempts = [Math]::Max(200, $videos.Count * 30)
    $videoBag = @()
    $bagIndex = 0

    while ($remaining -gt 0.05) {
        $attempts += 1
        if ($attempts -gt $maxAttempts) {
            throw "无法找到可用视频片段，请检查视频素材和取材方式设置。"
        }
        if ($bagIndex -ge $videoBag.Count) {
            $videoBag = @(New-ShuffledVideoBag $videos)
            $bagIndex = 0
        }
        $source = $videoBag[$bagIndex]
        $bagIndex += 1
        if ($ClipMode -eq "whole" -and $usedSources.ContainsKey($source.FullName) -and $usedSources.Count -lt $videos.Count) {
            continue
        }
        try {
            $sourceDuration = Get-DurationSeconds $source.FullName
        } catch {
            Write-Host "跳过损坏或不可读视频：$($source.Name)"
            continue
        }

        if ($sourceDuration -lt 0.5) {
            Write-Host "跳过过短视频：$($source.Name)"
            continue
        }

        if ($ClipMode -eq "whole") {
            $takeSeconds = [Math]::Min($remaining, $sourceDuration)
            $start = 0
            $usedSources[$source.FullName] = $true
        } else {
            if ([int]$MinClipSeconds -eq [int]$MaxClipSeconds) {
                $clipSeconds = [double]$MaxClipSeconds
            } else {
                $clipSeconds = $random.Next($MinClipSeconds * 1000, ($MaxClipSeconds * 1000) + 1) / 1000.0
            }
            $clipSeconds = [Math]::Min($clipSeconds, $remaining)
            if ($sourceDuration + 0.05 -lt $clipSeconds) {
                if ($ClipMode -eq "short" -and $sourceDuration + 0.05 -ge [double]$MinimumShortClipSeconds) {
                    # Keep short clips whole in the sequential fallback renderer too.
                    $takeSeconds = [Math]::Min($remaining, $sourceDuration)
                    $start = Get-NonOverlappingClipStart $source.FullName $sourceDuration $takeSeconds $clips
                } else {
                    Write-Host "跳过过短视频：$($source.Name)，需要 $clipSeconds 秒，实际 $sourceDuration 秒"
                    continue
                }
            } else {
                $takeSeconds = $clipSeconds
                $start = Get-NonOverlappingClipStart $source.FullName $sourceDuration $takeSeconds $clips
            }
        }

        if ($null -eq $start -or -not (Test-SourceSegmentUnused $source.FullName $start $takeSeconds $clips)) {
            continue
        }

        $segment = Join-Path $segmentsDir ("segment_{0:D5}.mp4" -f $index)
        $vf = "scale='if(gte(iw/ih,$aspect),-2,$targetWidth)':'if(gte(iw/ih,$aspect),$targetHeight,-2)',crop=${targetWidth}:${targetHeight},setsar=1,fps=$Fps,format=yuv420p"

        $args = @(
            "-y",
            "-ss", ("{0:0.###}" -f $start),
            "-t", ("{0:0.###}" -f $takeSeconds),
            "-i", $source.FullName,
            "-an",
            "-vf", $vf,
            "-r", "$Fps",
            "-movflags", "+faststart",
            $segment
        )
        $args = $args[0..7] + $encodeArgs + $args[8..($args.Count - 1)]
        Write-Host ("  正在生成片段 {0}: {1} 秒 - {2}" -f ($index + 1), ("{0:N2}" -f $takeSeconds), $source.Name)
        Invoke-Checked $Ffmpeg $args "生成片段"

        $segmentPaths += $segment
        $clips += (New-ClipPlanItem $source $start $takeSeconds $false)
        $remaining -= $takeSeconds
        $index += 1
        Write-Host ("  片段 {0} 完成，剩余约 {1} 秒" -f $index, ("{0:N2}" -f [Math]::Max(0, $remaining)))
    }

    $concatLines = foreach ($segment in $segmentPaths) {
        "file '$((Escape-ConcatPath $segment))'"
    }
    [IO.File]::WriteAllLines($concatList, $concatLines, [Text.UTF8Encoding]::new($false))

    Invoke-Checked $Ffmpeg @(
        "-y",
        "-f", "concat",
        "-safe", "0",
        "-i", $concatList,
        "-c", "copy",
        $concatVideo
    ) "合并视频片段"

    if ($useSubtitle) {
        Push-Location $audioWork
        try {
            $style = Get-SubtitleStyle
            $finalArgs = @(
                "-y",
                "-i", $concatVideo,
                "-i", $audio.FullName,
                "-vf", "subtitles=subtitles.srt:fontsdir=fonts:force_style='$style'",
                "-map", "0:v:0",
                "-map", "1:a:0"
            ) + $encodeArgs + @(
                "-c:a", "aac",
                "-b:a", $AudioBitrate,
                "-shortest",
                $output
            )
            Invoke-Checked $Ffmpeg $finalArgs "合成带字幕成片"
        } finally {
            Pop-Location
        }
    } else {
        Invoke-Checked $Ffmpeg @(
            "-y",
            "-i", $concatVideo,
            "-i", $audio.FullName,
            "-map", "0:v:0",
            "-map", "1:a:0",
            "-c:v", "copy",
            "-c:a", "aac",
            "-b:a", $AudioBitrate,
            "-shortest",
            $output
        ) "合成成片"
    }

    Write-Host "完成：$output"
    Write-Host ""
    Remove-SuccessfulWorkDirectory $audioWork $WorkDir
}

Write-Host "全部任务完成，输出目录：$OutputDir"











