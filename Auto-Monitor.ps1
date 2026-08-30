param()

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$Root = $PSScriptRoot
$createdMutex = $false
$monitorMutex = New-Object Threading.Mutex($false, 'Local\AutoCut-Monitor', [ref]$createdMutex)
if (-not $createdMutex) {
    Write-Host '监控已在运行，本次启动已跳过。' -ForegroundColor Yellow
    exit 0
}

try {
    [Console]::OutputEncoding = [Text.Encoding]::UTF8
} catch {}

. (Join-Path $Root "config.ps1")

$AudioExts = @(".mp3", ".wav", ".m4a", ".aac", ".flac", ".ogg", ".wma")
$CheckIntervalSeconds = 10
$StableSecondsRequired = 30
$FailedAudioDir = Join-Path $Root "失败音频"
$MonitorLogDir = Join-Path $Root "logs"
$MonitorLog = Join-Path $MonitorLogDir ("monitor_{0}.log" -f (Get-Date -Format "yyyyMMdd_HHmmss"))
$MonitorLogMaxBytes = 10MB
$LocalAudioQueueDir = Join-Path $WorkDir "monitor_audio_queue"
$RetryDelaysMinutes = @(5, 20, 60)
$MaxRetryAttempts = $RetryDelaysMinutes.Count

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

function Get-RotatedMonitorLogPath([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $Path }
    try {
        if ((Get-Item -LiteralPath $Path -ErrorAction Stop).Length -lt $MonitorLogMaxBytes) { return $Path }
        $dir = Split-Path -Parent $Path
        $base = [IO.Path]::GetFileNameWithoutExtension($Path)
        $ext = [IO.Path]::GetExtension($Path)
        return (Join-Path $dir ("{0}_{1}{2}" -f $base, (Get-Date -Format 'yyyyMMdd_HHmmss_fff'), $ext))
    } catch {
        return $Path
    }
}

function Write-MonitorLog($Message, $Color = $null) {
    $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
    if ($Color) {
        Write-Host $Message -ForegroundColor $Color
    } else {
        Write-Host $Message
    }
    try {
        $script:MonitorLog = Get-RotatedMonitorLogPath $MonitorLog
        Add-Content -LiteralPath $MonitorLog -Value $line -Encoding UTF8 -ErrorAction Stop
    } catch {
        Write-Host "日志写入失败：$($_.Exception.Message)" -ForegroundColor Red
    }
}

function Clear-UnimportantLogs {
    $hours = if ($null -eq $UnimportantLogRetentionHours) { 24 } else { [int]$UnimportantLogRetentionHours }
    if ($hours -le 0 -or -not (Test-Path -LiteralPath $MonitorLogDir)) { return }
    $cutoff = (Get-Date).AddHours(-$hours)
    $activeLogPath = [IO.Path]::GetFullPath($MonitorLog)
    Get-ChildItem -LiteralPath $MonitorLogDir -File -Recurse -Filter "*.log" -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt $cutoff -and [IO.Path]::GetFullPath($_.FullName) -ne $activeLogPath } |
        ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
    Get-ChildItem -LiteralPath $MonitorLogDir -Directory -Recurse -ErrorAction SilentlyContinue |
        Sort-Object FullName -Descending |
        Where-Object { -not (Get-ChildItem -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue) } |
        ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
}

function Get-UniqueDestinationPath($Dir, $Name) {
    $target = Join-Path $Dir $Name
    if (-not (Test-Path -LiteralPath $target)) {
        return $target
    }
    $base = [IO.Path]::GetFileNameWithoutExtension($Name)
    $ext = [IO.Path]::GetExtension($Name)
    $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
    return (Join-Path $Dir ("{0}_{1}{2}" -f $base, $stamp, $ext))
}

function Get-SidecarTextPath($AudioPath) {
    $dir = Split-Path -Parent $AudioPath
    $base = [IO.Path]::GetFileNameWithoutExtension($AudioPath)
    $textPath = Join-Path $dir "$base.txt"
    if (Test-Path -LiteralPath $textPath -PathType Leaf) {
        return $textPath
    }
    return $null
}

function Get-RetryStatePath($AudioPath) {
    return "$AudioPath.retry.json"
}

function Get-RetryState($AudioPath) {
    $path = Get-RetryStatePath $AudioPath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    try {
        return (Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json)
    } catch {
        Write-MonitorLog "重试状态损坏，将立即重试：$path；$($_.Exception.Message)" Yellow
        return $null
    }
}

function Test-RetryDue($AudioPath) {
    $state = Get-RetryState $AudioPath
    if ($null -eq $state -or [string]::IsNullOrWhiteSpace([string]$state.NextRetryAt)) { return $true }
    $nextRetryAt = [datetime]::MinValue
    if (-not [datetime]::TryParse([string]$state.NextRetryAt, [ref]$nextRetryAt)) { return $true }
    return $nextRetryAt -le (Get-Date)
}

function Save-RetryState($AudioPath, $ErrorMessage) {
    $previous = Get-RetryState $AudioPath
    $attempt = if ($previous) { [int]$previous.Attempt + 1 } else { 1 }
    if ($attempt -gt $MaxRetryAttempts) { return $null }
    $nextRetryAt = (Get-Date).AddMinutes([int]$RetryDelaysMinutes[$attempt - 1])
    $state = [pscustomobject]@{
        Attempt = $attempt
        NextRetryAt = $nextRetryAt.ToString('o')
        LastError = $ErrorMessage
        UpdatedAt = (Get-Date).ToString('o')
    }
    $path = Get-RetryStatePath $AudioPath
    $tempPath = "$path.$([guid]::NewGuid().ToString('N')).tmp"
    [IO.File]::WriteAllText($tempPath, ($state | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($true))
    Move-Item -LiteralPath $tempPath -Destination $path -Force
    return $state
}

function Remove-RetryState($AudioPath) {
    $path = Get-RetryStatePath $AudioPath
    Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
}

function Test-RetryableFailure($Message) {
    return $Message -notmatch '音频时长异常|不支持的音频|指定文件不是支持|素材为空|找不到可用视频片段|图片素材不足|目录路径为空|字幕来源模式无效|Paraformer 识别失败|CUDA out of memory|FFmpeg 退出码：-28|No space left on device'
}

function Move-SidecarText($SourceTextPath, $DestinationAudioPath, $Reason) {
    if ([string]::IsNullOrWhiteSpace($SourceTextPath)) {
        return
    }
    if (-not (Test-Path -LiteralPath $SourceTextPath -PathType Leaf)) {
        Write-MonitorLog "$Reason：同名文本稿已经不存在，跳过移动：$SourceTextPath" Yellow
        return
    }
    $destDir = Split-Path -Parent $DestinationAudioPath
    $destName = [IO.Path]::GetFileNameWithoutExtension($DestinationAudioPath) + ".txt"
    $destText = Get-UniqueDestinationPath $destDir $destName
    try {
        Move-Item -LiteralPath $SourceTextPath -Destination $destText -Force -ErrorAction Stop
        Write-MonitorLog "$Reason，同名文本稿已移动：$destText" Green
    } catch {
        if (-not (Test-Path -LiteralPath $SourceTextPath -PathType Leaf)) {
            Write-MonitorLog "$Reason：同名文本稿已经不存在，跳过移动：$SourceTextPath" Yellow
            return
        }
        throw
    }
}

function Get-PendingAudioFiles {
    if (-not (Test-Path -LiteralPath $AudioDir)) {
        return @()
    }
    return @(Get-ChildItem -LiteralPath $AudioDir -File -ErrorAction SilentlyContinue |
        Where-Object {
            if ($null -eq $_ -or [string]::IsNullOrWhiteSpace($_.Extension)) { return $false }
            ($AudioExts -contains ("" + $_.Extension).ToLowerInvariant()) -and (Test-RetryDue $_.FullName)
        } |
        Sort-Object Name)
}

function Get-RetryQueueAudioFiles {
    if (-not (Test-Path -LiteralPath $LocalAudioQueueDir)) { return @() }
    return @(Get-ChildItem -LiteralPath $LocalAudioQueueDir -File -ErrorAction SilentlyContinue |
        Where-Object {
            if ($null -eq $_ -or [string]::IsNullOrWhiteSpace($_.Extension)) { return $false }
            ($AudioExts -contains ("" + $_.Extension).ToLowerInvariant()) -and
                (Test-Path -LiteralPath (Get-RetryStatePath $_.FullName) -PathType Leaf) -and
                (Test-RetryDue $_.FullName)
        } |
        Sort-Object Name)
}

function Wait-AudioFileStable($File) {
    Write-MonitorLog "发现音频：$($File.Name)"
    Write-MonitorLog "等待文件复制完成：连续 $StableSecondsRequired 秒大小不变后开始剪辑。"
    $stableSeconds = 0
    $lastSize = -1

    while ($stableSeconds -lt $StableSecondsRequired) {
        if (-not (Test-Path -LiteralPath $File.FullName)) {
            Write-MonitorLog "音频文件已消失，跳过：$($File.FullName)" Yellow
            return $false
        }
        $current = Get-Item -LiteralPath $File.FullName
        if ($current.Length -eq $lastSize -and $current.Length -gt 0) {
            $stableSeconds += $CheckIntervalSeconds
        } else {
            $stableSeconds = 0
            $lastSize = $current.Length
        }
        Write-MonitorLog ("文件大小：{0:N2} MB，已稳定：{1}/{2} 秒" -f ($current.Length / 1MB), $stableSeconds, $StableSecondsRequired)
        if ($stableSeconds -lt $StableSecondsRequired) {
            Start-Sleep -Seconds $CheckIntervalSeconds
        }
    }
    return $true
}

function Move-AudioTo($AudioPath, $TargetDir, $Reason) {
    Ensure-Dir $TargetDir
    if (-not (Test-Path -LiteralPath $AudioPath)) {
        Write-MonitorLog "$Reason：音频已经不存在，无法移动：$AudioPath" Yellow
        return
    }
    $sourceText = Get-SidecarTextPath $AudioPath
    $name = Split-Path -Leaf $AudioPath
    $dest = Get-UniqueDestinationPath $TargetDir $name
    Move-Item -LiteralPath $AudioPath -Destination $dest -Force
    Move-SidecarText $sourceText $dest $Reason
    Write-MonitorLog "$Reason：$dest" Green
}

function Move-AudioToLocalQueue($AudioPath) {
    Ensure-Dir $LocalAudioQueueDir
    if (-not (Test-Path -LiteralPath $AudioPath)) {
        throw "待处理音频不存在，无法剪切到本机：$AudioPath"
    }
    $name = Split-Path -Leaf $AudioPath
    $dest = Get-UniqueDestinationPath $LocalAudioQueueDir $name
    $sourceRetryState = Get-RetryStatePath $AudioPath
    Copy-Item -LiteralPath $AudioPath -Destination $dest -Force -ErrorAction Stop
    $sourceLength = (Get-Item -LiteralPath $AudioPath -ErrorAction Stop).Length
    $destLength = (Get-Item -LiteralPath $dest -ErrorAction Stop).Length
    if ($sourceLength -ne $destLength) {
        Remove-Item -LiteralPath $dest -Force -ErrorAction SilentlyContinue
        throw "音频复制到本机待处理目录后大小不一致，已保留源文件：$AudioPath"
    }
    $sourceText = Get-SidecarTextPath $AudioPath
    if ($sourceText) {
        $destText = [IO.Path]::ChangeExtension($dest, [IO.Path]::GetExtension($sourceText))
        try {
            Copy-Item -LiteralPath $sourceText -Destination $destText -Force -ErrorAction Stop
            Remove-Item -LiteralPath $sourceText -Force -ErrorAction Stop
            Write-MonitorLog "同名文本稿已复制到本机待处理目录：$destText" Green
        } catch {
            Remove-Item -LiteralPath $destText -Force -ErrorAction SilentlyContinue
            Write-MonitorLog "同名文本稿同步失败，改用语音识别字幕，不影响音频剪辑：$($_.Exception.Message)" Yellow
        }
    }
    Remove-Item -LiteralPath $AudioPath -Force -ErrorAction Stop
    if (Test-Path -LiteralPath $sourceRetryState -PathType Leaf) {
        Move-Item -LiteralPath $sourceRetryState -Destination (Get-RetryStatePath $dest) -Force
    }
    Write-MonitorLog "已复制校验并转入本机待处理：$dest" Green
    return $dest
}

function Remove-ProcessedAudio($AudioPath) {
    if (-not (Test-Path -LiteralPath $AudioPath)) {
        Write-MonitorLog "剪辑完成：音频已经不存在，无需删除：$AudioPath" Yellow
        return
    }
    $textPath = Get-SidecarTextPath $AudioPath
    Remove-Item -LiteralPath $AudioPath -Force -ErrorAction Stop
    Write-MonitorLog "剪辑完成，已删除源音频：$AudioPath" Green
    if ($textPath) {
        try {
            Remove-Item -LiteralPath $textPath -Force -ErrorAction Stop
            Write-MonitorLog "剪辑完成，已删除同名文本稿：$textPath" Green
        } catch {
            Write-MonitorLog "源音频已删除，但保留同名文本稿（删除失败）：$textPath；$($_.Exception.Message)" Yellow
        }
    }
}

function Get-SafeName($Name) {
    $result = $Name
    foreach ($char in [IO.Path]::GetInvalidFileNameChars()) {
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

function Assert-CompletedOutputSet($AudioPath) {
    $audioBase = Get-SafeName ([IO.Path]::GetFileNameWithoutExtension($AudioPath))
    $completedFolder = Join-Path $OutputDir (Get-AudioOutputFolderName $audioBase)
    if (-not (Test-Path -LiteralPath $completedFolder -PathType Container)) {
        throw "未找到成品文件夹，保留源音频：$completedFolder"
    }

    $videos = @(Get-ChildItem -LiteralPath $completedFolder -File -Filter "*.mp4")
    $expectedCount = if ($null -eq $VideosPerAudio) { 6 } else { [int]$VideosPerAudio }
    if ($videos.Count -lt $expectedCount) {
        throw "成品至少需要 $expectedCount 条视频，当前为 $($videos.Count) 条；保留源音频。"
    }
    $invalidVideos = @($videos | Where-Object { $_.Length -le 0 })
    if ($invalidVideos.Count -gt 0) {
        throw "成品中存在空视频，保留源音频：$($invalidVideos[0].Name)"
    }

    Write-MonitorLog "成品检查通过：$expectedCount 条视频已整组到位：$completedFolder" Green
}

function Invoke-AudioCut($AudioPath) {
    Write-MonitorLog "开始剪辑：$AudioPath" Cyan
    $oldErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $autoCutOutput = & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root "AutoCut.ps1") -AudioFile $AudioPath *>&1
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $oldErrorActionPreference
    }
    foreach ($line in @($autoCutOutput)) {
        $text = [string]$line
        if ([string]::IsNullOrWhiteSpace($text)) { continue }
        if ($text -match '错误|失败|ERROR|Exception|退出码|不存在|无法') {
            Write-MonitorLog "剪辑输出：$text" Red
        } else {
            Write-MonitorLog "剪辑输出：$text"
        }
    }
    if ($exitCode -ne 0) {
        throw "剪辑进程退出码：$exitCode"
    }
}

Ensure-Dir $AudioDir
Ensure-Dir $OutputDir
Ensure-Dir $WorkDir
Ensure-Dir $FailedAudioDir
Ensure-Dir $MonitorLogDir
Ensure-Dir $LocalAudioQueueDir
Clear-UnimportantLogs

Clear-Host
Write-MonitorLog "====== 自动监控音频并剪辑 ======" Cyan
Write-MonitorLog "监控目录：$AudioDir"
Write-MonitorLog "检测间隔：$CheckIntervalSeconds 秒"
Write-MonitorLog "稳定要求：$StableSecondsRequired 秒"
Write-MonitorLog "本机待处理目录：$LocalAudioQueueDir"
Write-MonitorLog "临时失败重试：最多 $MaxRetryAttempts 次，间隔 $($RetryDelaysMinutes -join '/ ') 分钟。"
Write-MonitorLog "成功音频：剪辑完成后直接删除源音频"
Write-MonitorLog "失败音频：$FailedAudioDir"
Write-MonitorLog "监控日志：$MonitorLog"
Write-MonitorLog "按 Ctrl+C 可以停止监控。"
Write-MonitorLog "================================" Cyan

while ($true) {
    try {
        $files = @()
        $files += @(Get-RetryQueueAudioFiles)
        $files += @(Get-PendingAudioFiles)
        $files = @($files | Where-Object { $null -ne $_ })
        if ($files.Count -eq 0) {
            Write-MonitorLog ("等待音频中：{0}" -f (Get-Date -Format "HH:mm:ss"))
            Start-Sleep -Seconds $CheckIntervalSeconds
            continue
        }
    } catch {
        Write-MonitorLog "监控目录读取异常，将继续重试：$($_.Exception.Message)" Red
        Start-Sleep -Seconds $CheckIntervalSeconds
        continue
    }

    foreach ($file in $files) {
        $processingAudio = $null
        try {
            if ($file.DirectoryName -eq $LocalAudioQueueDir) {
                $processingAudio = $file.FullName
                Write-MonitorLog "重试剪辑：$processingAudio" Yellow
            } else {
                $freshFile = Get-Item -LiteralPath $file.FullName -ErrorAction Stop
                if (-not (Wait-AudioFileStable $freshFile)) {
                    continue
                }
                $processingAudio = Move-AudioToLocalQueue $freshFile.FullName
            }
            Invoke-AudioCut $processingAudio
            Assert-CompletedOutputSet $processingAudio
            Remove-RetryState $processingAudio
            Remove-ProcessedAudio $processingAudio
        } catch {
            Write-MonitorLog "运行出错：$($_.Exception.Message)" Red
            # A non-zero render exit can happen after some jobs have already finished.
            # Final output count is the only authority for audio success or failure.
            $audioToFinalize = if ($processingAudio -and (Test-Path -LiteralPath $processingAudio)) { $processingAudio } elseif (Test-Path -LiteralPath $file.FullName) { $file.FullName } else { $null }
            $finalOutputReady = $false
            if ($audioToFinalize) {
                try {
                    Assert-CompletedOutputSet $audioToFinalize
                    $finalOutputReady = $true
                } catch {
                    Write-MonitorLog "最终成品复核未通过：$($_.Exception.Message)" Yellow
                }
            }

            if ($finalOutputReady) {
                Write-MonitorLog "音频最终成功：成品数量已达到设定数量，忽略中间任务失败。" Green
                Remove-RetryState $audioToFinalize
                Remove-ProcessedAudio $audioToFinalize
            } elseif ($audioToFinalize -and (Test-RetryableFailure $_.Exception.Message)) {
                $retry = Save-RetryState $audioToFinalize $_.Exception.Message
                if ($retry) {
                    Write-MonitorLog ("临时失败，已保留待重试：第 {0}/{1} 次；下次重试 {2}；{3}" -f $retry.Attempt, $MaxRetryAttempts, $retry.NextRetryAt, $_.Exception.Message) Yellow
                    continue
                }
                Write-MonitorLog "重试次数已耗尽，转入失败音频：$audioToFinalize" Red
                Remove-RetryState $audioToFinalize
                Move-AudioTo $audioToFinalize $FailedAudioDir "临时失败重试耗尽"
            } elseif ($processingAudio -and (Test-Path -LiteralPath $processingAudio)) {
                Remove-RetryState $processingAudio
                Move-AudioTo $processingAudio $FailedAudioDir "最终成品数量不足，已移动本机待处理音频到失败"
            } elseif (Test-Path -LiteralPath $file.FullName) {
                Remove-RetryState $file.FullName
                Move-AudioTo $file.FullName $FailedAudioDir "最终成品数量不足，已移动音频到失败"
            }
        }
    }
}
