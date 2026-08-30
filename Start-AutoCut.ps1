param(
    [switch]$CheckOnly,
    [switch]$Run,
    [switch]$Test
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$LauncherVersion = "V16.1.15-20260816"
$Root = $PSScriptRoot
$RunStamp = Get-Date -Format "yyyyMMdd_HHmmss"
$VersionBackupDir = Join-Path $Root "banbenbeifen"
$VersionLogDir = Join-Path $VersionBackupDir "logs"
$LauncherLog = Join-Path $VersionLogDir "launcher_$RunStamp.log"
$PluginPackageDir = Join-Path $Root "chajia"

try {
    [Console]::OutputEncoding = [Text.Encoding]::UTF8
} catch {}

[IO.Directory]::CreateDirectory($VersionBackupDir) | Out-Null
[IO.Directory]::CreateDirectory($VersionLogDir) | Out-Null
[IO.Directory]::CreateDirectory($PluginPackageDir) | Out-Null

function Clear-UnimportantLauncherLogs {
    $hours = 24
    $configPath = Join-Path $Root "config.ps1"
    if (Test-Path -LiteralPath $configPath) {
        . $configPath
        if ($null -ne $UnimportantLogRetentionHours) { $hours = [int]$UnimportantLogRetentionHours }
    }
    if ($hours -le 0 -or -not (Test-Path -LiteralPath $VersionLogDir)) { return }
    $cutoff = (Get-Date).AddHours(-$hours)
    Get-ChildItem -LiteralPath $VersionLogDir -File -Filter "launcher_*.log" -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt $cutoff } |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

function Remove-OldBackupFiles($Directory, $Pattern, $KeepCount) {
    if ($KeepCount -lt 1 -or -not (Test-Path -LiteralPath $Directory -PathType Container)) { return }
    Get-ChildItem -LiteralPath $Directory -File -Filter $Pattern -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -Skip $KeepCount |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

Clear-UnimportantLauncherLogs

function Write-LauncherLog($Text) {
    $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Text
    Add-Content -LiteralPath $LauncherLog -Value $line -Encoding UTF8
}

function Write-Ok($Text) {
    Write-Host ("[OK] " + $Text) -ForegroundColor Green
    Write-LauncherLog ("[OK] " + $Text)
}

function Write-WarnLine($Text) {
    Write-Host ("[注意] " + $Text) -ForegroundColor Yellow
    Write-LauncherLog ("[注意] " + $Text)
}

function Write-Bad($Text) {
    Write-Host ("[错误] " + $Text) -ForegroundColor Red
    Write-LauncherLog ("[错误] " + $Text)
}

function Ensure-Dir($Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "目录路径为空。"
    }
    if (Test-Path -LiteralPath $Path -PathType Container) {
        return
    }
    if (-not (Test-Path -LiteralPath $Path)) {
        [IO.Directory]::CreateDirectory($Path) | Out-Null
        Write-WarnLine "已自动创建目录：$Path"
    }
}

function Test-FileItem($Path, $Name) {
    if (Test-Path -LiteralPath $Path) {
        Write-Ok "$Name 存在"
        return $true
    }
    Write-Bad "$Name 不存在：$Path"
    return $false
}

function Install-PluginPackage($PackageName, $DisplayName) {
    $packagePath = Join-Path $PluginPackageDir $PackageName
    if (-not (Test-Path -LiteralPath $packagePath)) {
        Write-Bad "$DisplayName 缺失，且找不到本地安装包：$packagePath"
        return $false
    }
    try {
        $toolsDir = Join-Path $Root "tools"
        Ensure-Dir $toolsDir
        Write-WarnLine "正在从本地安装包恢复 $DisplayName：$packagePath"
        Expand-Archive -LiteralPath $packagePath -DestinationPath $toolsDir -Force
        Write-Ok "$DisplayName 已自动安装/恢复"
        return $true
    } catch {
        Write-Bad "$DisplayName 自动安装失败：$($_.Exception.Message)"
        return $false
    }
}

function Ensure-FileFromPackage($Path, $Name, $PackageName) {
    if (Test-Path -LiteralPath $Path) {
        Write-Ok "$Name 存在"
        return $true
    }
    Write-WarnLine "$Name 不存在，尝试自动安装"
    if (Install-PluginPackage $PackageName $Name) {
        if (Test-Path -LiteralPath $Path) {
            Write-Ok "$Name 自动安装后已存在"
            return $true
        }
    }
    Write-Bad "$Name 自动安装后仍不存在：$Path"
    return $false
}

function Test-ToolRun($Exe, $ToolArgs, $Name) {
    if (-not (Test-Path -LiteralPath $Exe)) {
        Write-Bad "$Name 不存在：$Exe"
        return $false
    }
    try {
        $argText = ($ToolArgs | ForEach-Object { '"' + ($_ -replace '"', '\"') + '"' }) -join " "
        $cmdLine = '"' + $Exe + '" ' + $argText + " >nul 2>nul"
        & cmd.exe /d /c $cmdLine
        if ($LASTEXITCODE -eq 0) {
            Write-Ok "$Name 可以运行"
            return $true
        }
    } catch {
        Write-Bad "$Name 运行失败：$($_.Exception.Message)"
        return $false
    }
    Write-Bad "$Name 运行失败"
    return $false
}

function Get-CountByExt($Dir, $Exts) {
    if (-not (Test-Path -LiteralPath $Dir)) {
        return 0
    }
    $items = Get-ChildItem -LiteralPath $Dir -File -Recurse -ErrorAction SilentlyContinue | Where-Object {
        $Exts -contains (Get-LowerExtension $_)
    }
    return @($items).Count
}

function Get-LowerExtension($Item) {
    if ($null -eq $Item -or [string]::IsNullOrWhiteSpace($Item.Extension)) {
        return ""
    }
    return ("" + $Item.Extension).ToLowerInvariant()
}

function Test-Nvenc($Ffmpeg) {
    if (-not (Test-Path -LiteralPath $Ffmpeg)) {
        Write-Bad "无法检测 NVENC，因为 FFmpeg 不存在"
        return $false
    }
    try {
        $encoders = & $Ffmpeg -hide_banner -encoders 2>$null
        if (($encoders | Select-String -SimpleMatch "h264_nvenc")) {
            Write-Ok "NVIDIA NVENC 编码器可用：h264_nvenc"
            return $true
        }
        Write-Bad "FFmpeg 没检测到 h264_nvenc，可能需要更新显卡驱动或更换 FFmpeg"
        return $false
    } catch {
        Write-Bad "NVENC 检测失败：$($_.Exception.Message)"
        return $false
    }
}

function Test-NvidiaDriver() {
    $cmd = Get-Command nvidia-smi.exe -ErrorAction SilentlyContinue
    if (-not $cmd) {
        Write-WarnLine "没有找到 nvidia-smi，仍会继续检测 FFmpeg NVENC"
        return
    }
    try {
        $gpu = & nvidia-smi.exe --query-gpu=name,driver_version --format=csv,noheader 2>$null | Select-Object -First 1
        if ($gpu) {
            Write-Ok "显卡：$gpu"
        } else {
            Write-WarnLine "nvidia-smi 没有返回显卡信息"
        }
    } catch {
        Write-WarnLine "nvidia-smi 检测失败：$($_.Exception.Message)"
    }
}

function Test-WhisperInference($Ffmpeg, $Whisper, $Model) {
    if (-not ((Test-Path -LiteralPath $Ffmpeg) -and (Test-Path -LiteralPath $Whisper) -and (Test-Path -LiteralPath $Model))) {
        Write-Bad "无法做 Whisper 实际识别测试，程序或模型缺失"
        return $false
    }

    $testRoot = Join-Path ([IO.Path]::GetTempPath()) ("autocut_check_whisper_{0}_{1}" -f $PID, (Get-Date -Format "yyyyMMddHHmmssfff"))
    $toolDir = Join-Path $testRoot "whisper_tool"
    try {
        Ensure-Dir $testRoot
        Ensure-Dir $toolDir
        $wav = Join-Path $testRoot "input.wav"
        $modelCopy = Join-Path $testRoot "model.bin"
        $outputBase = Join-Path $testRoot "out"
        $testLog = Join-Path $VersionLogDir ("whisper_check_{0}.log" -f $RunStamp)

        Copy-Item -Path (Join-Path $Root "tools\whisper\*") -Destination $toolDir -Recurse -Force
        Copy-Item -LiteralPath $Model -Destination $modelCopy -Force
        $whisperExe = Join-Path $toolDir "whisper-cli.exe"

        $oldErrorActionPreference = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try {
            & $Ffmpeg -y -f lavfi -i "sine=frequency=1000:duration=1" -ar 16000 -ac 1 -c:a pcm_s16le $wav *> $null
            $ffmpegExitCode = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $oldErrorActionPreference
        }
        if ($ffmpegExitCode -ne 0 -or -not (Test-Path -LiteralPath $wav)) {
            Write-Bad "Whisper 自检失败：测试音频生成失败"
            return $false
        }

        $oldErrorActionPreference = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try {
            & $whisperExe -m $modelCopy -f $wav -t 2 -l zh -osrt -of $outputBase -np *> $testLog
            $exitCode = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $oldErrorActionPreference
        }
        if ($exitCode -eq 0) {
            Write-Ok "Whisper 实际识别测试通过"
            return $true
        }
        Write-Bad "Whisper 实际识别测试失败，退出码：$exitCode，日志：$testLog"
        return $false
    } catch {
        Write-Bad "Whisper 实际识别测试异常：$($_.Exception.Message)"
        return $false
    } finally {
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Test-OpenCCConversion($OpenCC, $OpenCCConfig) {
    if (-not ((Test-Path -LiteralPath $OpenCC) -and (Test-Path -LiteralPath $OpenCCConfig))) {
        Write-Bad "OpenCC 实际转换测试失败：程序或配置缺失"
        return $false
    }
    $testRoot = Join-Path ([IO.Path]::GetTempPath()) ("autocut_check_opencc_{0}_{1}" -f $PID, (Get-Date -Format "yyyyMMddHHmmssfff"))
    $toolDir = Join-Path $testRoot "opencc_tool"
    $shareDir = Join-Path $toolDir "share\opencc"
    try {
        Ensure-Dir $testRoot
        Ensure-Dir $toolDir
        Ensure-Dir $shareDir
        $input = Join-Path $testRoot "input.txt"
        $output = Join-Path $testRoot "output.txt"
        $exe = Join-Path $toolDir "opencc.exe"
        $config = Join-Path $shareDir "t2s.json"
        [IO.File]::WriteAllText($input, "測試繁體轉簡體", [Text.UTF8Encoding]::new($true))
        Copy-Item -Path (Join-Path $Root "tools\opencc\bin\*") -Destination $toolDir -Recurse -Force
        Copy-Item -Path (Join-Path $Root "tools\opencc\share\opencc\*") -Destination $shareDir -Recurse -Force

        $oldErrorActionPreference = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try {
            & $exe -i $input -o $output -c $config *> (Join-Path $VersionLogDir ("opencc_check_{0}.log" -f $RunStamp))
            $exitCode = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $oldErrorActionPreference
        }
        if ($exitCode -eq 0 -and (Test-Path -LiteralPath $output)) {
            $convertedText = [IO.File]::ReadAllText($output, [Text.Encoding]::UTF8)
            if ($convertedText -match '测试繁体转简体') {
                Write-Ok "OpenCC 实际转换测试通过"
                return $true
            }
            Write-Bad "OpenCC 实际转换内容错误，未得到预期简体文本"
            return $false
        }
        Write-Bad "OpenCC 实际转换测试失败，退出码：$exitCode"
        return $false
    } catch {
        Write-Bad "OpenCC 实际转换测试异常：$($_.Exception.Message)"
        return $false
    } finally {
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Set-PortableConfigValue($Text, $Name, $ValueExpression) {
    $configName = [regex]::Escape('$' + $Name)
    $pattern = "(?m)^\s*$configName\s*=.*$"
    $line = '$' + $Name + ' = ' + $ValueExpression
    if ($Text -match $pattern) {
        return [regex]::Replace($Text, $pattern, $line)
    }
    return $Text.TrimEnd() + [Environment]::NewLine + $line + [Environment]::NewLine
}

function Repair-PortableConfig($ConfigPath) {
    $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $backupPath = Join-Path $VersionBackupDir "config_before_portable_repair_$stamp.ps1"
    Copy-Item -LiteralPath $ConfigPath -Destination $backupPath -Force

    $text = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8
    $text = Set-PortableConfigValue $text "AutoCutRoot" 'if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }'
    # Video, audio, and output locations are user data. Never reset them during startup.
    $text = Set-PortableConfigValue $text "WorkDir" 'Join-Path $AutoCutRoot "work"'
    $text = Set-PortableConfigValue $text "WhisperModel" 'Join-Path $AutoCutRoot "tools\models\ggml-tiny.bin"'

    $utf8Bom = New-Object System.Text.UTF8Encoding($true)
    [IO.File]::WriteAllText($ConfigPath, $text, $utf8Bom)
    Write-WarnLine "已修复程序内部路径，已保留你设置的视频、音频和完成位置；原配置备份：$backupPath"
}

function Test-PortableConfig($ConfigPath) {
    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        Write-Bad "配置文件不存在：$ConfigPath"
        return $false
    }
    $text = Get-Content -LiteralPath $ConfigPath -Raw
    if ($text -match '\$AutoCutRoot') {
        Write-Ok "配置已支持程序内部路径修复，用户目录将保持不变"
        return $true
    }
    try {
        Repair-PortableConfig $ConfigPath
        Write-Ok "配置路径已自动修复"
        return $true
    } catch {
        Write-Bad "配置自动修复失败：$($_.Exception.Message)"
        return $false
    }
}

function New-VersionBackup {
    try {
        $backupPath = Join-Path $VersionBackupDir ("program_version_{0}.zip" -f $RunStamp)
        $items = @(
            (Join-Path $Root "AutoCut.ps1"),
            (Join-Path $Root "config.ps1"),
            (Join-Path $Root "Subtitle-Core.psm1"),
            (Join-Path $Root "Subtitle-Aliyun.psm1"),
            (Join-Path $Root "Subtitle-Preview-Worker.ps1"),
            (Join-Path $Root "Start-AutoCut.ps1"),
            (Join-Path $Root "AutoCut-Manager.ps1"),
            (Join-Path $Root "Subtitle-Settings.ps1"),
            (Join-Path $Root "Auto-Monitor.ps1"),
            (Join-Path $Root "本地启动器.bat"),
            (Join-Path $Root "字幕设置器.bat"),
            (Join-Path $Root "自动监控.bat"),
            (Join-Path $Root "一键开始.bat"),
            (Join-Path $Root "测试10秒.bat"),
            (Join-Path $Root "fonts")
        ) | Where-Object { Test-Path -LiteralPath $_ }
        if (@($items).Count -eq 0) {
            Write-WarnLine "没有找到可备份的程序文件"
            return
        }
        Compress-Archive -LiteralPath $items -DestinationPath $backupPath -Force
        $keepCount = 5
        . (Join-Path $Root 'config.ps1')
        if ($null -ne $SoftwareBackupKeepCount) { $keepCount = [int]$SoftwareBackupKeepCount }
        Remove-OldBackupFiles $VersionBackupDir "program_version_*.zip" $keepCount
        Write-Ok "版本备份已保存：$backupPath"
    } catch {
        Write-WarnLine "版本备份失败：$($_.Exception.Message)"
    }
}

function Test-SubtitlePreviewRender($Ffmpeg, $CoreModule, $FontsDir) {
    if (-not ((Test-Path -LiteralPath $Ffmpeg) -and (Test-Path -LiteralPath $CoreModule))) { return $false }
    $testRoot = Join-Path ([IO.Path]::GetTempPath()) ("autocut_subtitle_check_{0}" -f ([guid]::NewGuid().ToString('N')))
    try {
        Ensure-Dir $testRoot
        $localFonts = Join-Path $testRoot 'fonts'
        Ensure-Dir $localFonts
        if (Test-Path -LiteralPath $FontsDir -PathType Container) {
            Get-ChildItem -LiteralPath $FontsDir -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Extension.ToLowerInvariant() -in @('.ttf', '.otf') } |
                ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $localFonts -Force }
        }
        Import-Module $CoreModule -Force -DisableNameChecking
        $srt = Join-Path $testRoot 'preview.srt'
        $png = Join-Path $testRoot 'preview.png'
        Subtitle-Core\New-SrtFromSegments -Segments @([pscustomobject]@{ Start = 0.0; End = 2.0; Text = '简体字幕自检' }) -Destination $srt
        $style = Subtitle-Core\Get-SubtitleAssStyle -FontName 'Microsoft YaHei' -FontSize 16 -PrimaryColor 'FFFFFF' -OutlineColor '000000' -Outline 2 -MarginV 30
        Push-Location $testRoot
        try {
            & $Ffmpeg -hide_banner -loglevel error -y -f lavfi -i 'color=c=black:s=640x360:d=1' -frames:v 1 -vf "subtitles=preview.srt:fontsdir=fonts:force_style='$style'" $png 2>$null
            $ok = ($LASTEXITCODE -eq 0) -and (Test-Path -LiteralPath $png) -and ((Get-Item -LiteralPath $png).Length -gt 0)
        } finally { Pop-Location }
        if ($ok) { Write-Ok 'FFmpeg字幕和便携字体目录实际渲染成功' } else { Write-Bad 'FFmpeg字幕实际渲染失败' }
        return $ok
    } catch {
        Write-Bad "FFmpeg字幕自检异常：$($_.Exception.Message)"
        return $false
    } finally {
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-EnvironmentCheck {
    Clear-Host
    Write-Host "====== 自动剪辑启动器：环境检测 ======" -ForegroundColor Cyan
    Write-Host "程序版本：$LauncherVersion"
    Write-Host "当前根目录：$Root"
    Write-Host "详细日志：$LauncherLog"
    Write-Host ""
    Write-LauncherLog "===== 环境检测开始 ====="
    Write-LauncherLog "程序版本：$LauncherVersion"
    Write-LauncherLog "当前根目录：$Root"
    Write-LauncherLog "详细日志：$LauncherLog"

    $configPath = Join-Path $Root "config.ps1"
    $autoCut = Join-Path $Root "AutoCut.ps1"
    $ffmpeg = Join-Path $Root "tools\ffmpeg\bin\ffmpeg.exe"
    $ffprobe = Join-Path $Root "tools\ffmpeg\bin\ffprobe.exe"
    $whisper = Join-Path $Root "tools\whisper\whisper-cli.exe"
    $tinyModel = Join-Path $Root "tools\models\ggml-tiny.bin"
    $baseModel = Join-Path $Root "tools\models\ggml-base.bin"
    $opencc = Join-Path $Root "tools\opencc\bin\opencc.exe"
    $openccConfig = Join-Path $Root "tools\opencc\share\opencc\t2s.json"
    $subtitleCore = Join-Path $Root 'Subtitle-Core.psm1'
    $subtitleAliyun = Join-Path $Root 'Subtitle-Aliyun.psm1'
    $subtitlePreviewWorker = Join-Path $Root 'Subtitle-Preview-Worker.ps1'
    $paraformerSetup = Join-Path $Root 'tools\paraformer\Setup-Paraformer.ps1'
    $paraformerWorker = Join-Path $Root 'tools\paraformer\paraformer_worker.py'
    $fontsDir = Join-Path $Root 'fonts'
    $configDir = Join-Path $Root 'config'

    $ok = $true
    if (-not (Test-FileItem $autoCut "主程序 AutoCut.ps1")) { $ok = $false }
    if (-not (Test-FileItem $subtitleCore '字幕核心 Subtitle-Core.psm1')) { $ok = $false }
    if (-not (Test-FileItem $subtitleAliyun '阿里云字幕 Subtitle-Aliyun.psm1')) { $ok = $false }
    if (-not (Test-FileItem $subtitlePreviewWorker '字幕后台预览 Subtitle-Preview-Worker.ps1')) { $ok = $false }
    if (-not (Test-FileItem $paraformerSetup '本地 Paraformer 安装器')) { $ok = $false }
    if (-not (Test-FileItem $paraformerWorker '本地 Paraformer 识别器')) { $ok = $false }
    if (-not (Test-PortableConfig $configPath)) { $ok = $false }

    . $configPath
    $videoDir = if ([string]::IsNullOrWhiteSpace($VideoDir)) { Join-Path $Root "视频位置" } else { $VideoDir }
    $audioDir = if ([string]::IsNullOrWhiteSpace($AudioDir)) { Join-Path $Root "音频位置" } else { $AudioDir }
    $outputDir = if ([string]::IsNullOrWhiteSpace($OutputDir)) { Join-Path $Root "完成" } else { $OutputDir }
    $workDir = if ([string]::IsNullOrWhiteSpace($WorkDir)) { Join-Path $Root "work" } else { $WorkDir }
    $logDir = Join-Path $Root "logs"
    $backupDir = Join-Path $Root "backups"

    Write-LauncherLog "配置视频目录：$videoDir"
    Write-LauncherLog "配置音频目录：$audioDir"
    Write-LauncherLog "配置完成目录：$outputDir"

    Ensure-Dir $PluginPackageDir
    Ensure-Dir $videoDir
    Ensure-Dir $audioDir
    Ensure-Dir $outputDir
    Ensure-Dir $workDir
    Ensure-Dir $logDir
    Ensure-Dir $backupDir
    Ensure-Dir $fontsDir
    Ensure-Dir $configDir
    Ensure-FileFromPackage $ffmpeg "FFmpeg 程序" "ffmpeg.zip" | Out-Null
    Ensure-FileFromPackage $ffprobe "FFprobe 程序" "ffmpeg.zip" | Out-Null
    Ensure-FileFromPackage $whisper "Whisper 字幕程序" "whisper.zip" | Out-Null
    Ensure-FileFromPackage $tinyModel "tiny 字幕模型" "models.zip" | Out-Null
    if (-not ((Test-Path -LiteralPath $opencc) -and (Test-Path -LiteralPath $openccConfig))) {
        Install-PluginPackage "opencc.zip" "OpenCC 简体转换" | Out-Null
    }
    if (-not (Test-ToolRun $ffmpeg @("-version") "FFmpeg")) { $ok = $false }
    if (-not (Test-ToolRun $ffprobe @("-version") "FFprobe")) { $ok = $false }
    if (-not (Test-FileItem $whisper "Whisper 字幕程序")) { $ok = $false }
    if (-not (Test-FileItem $tinyModel "tiny 字幕模型")) { $ok = $false }
    if (-not (Test-WhisperInference $ffmpeg $whisper $tinyModel)) { $ok = $false }
    if (Test-Path -LiteralPath $baseModel) {
        Write-Ok "base 字幕模型存在，可用于准确模式"
    } else {
        Write-WarnLine "base 字幕模型不存在，准确模式暂不可用：$baseModel"
    }
    if ((Test-Path -LiteralPath $opencc) -and (Test-Path -LiteralPath $openccConfig)) {
        Write-Ok "OpenCC 简体转换可用"
        if (-not (Test-OpenCCConversion $opencc $openccConfig)) { $ok = $false }
    } else {
        Write-Bad "OpenCC 不完整，无法保证字幕简体转换"
        $ok = $false
    }

    if (-not (Test-SubtitlePreviewRender $ffmpeg $subtitleCore $fontsDir)) { $ok = $false }
    if (Test-Path -LiteralPath $subtitleAliyun) {
        try {
            Import-Module $subtitleAliyun -Force -DisableNameChecking
            try {
                $curlPath = Get-WindowsCurlPath
                if (-not (Test-ToolRun $curlPath @("--version") "Windows curl.exe")) {
                    Write-Bad 'Windows curl.exe不可运行。新电脑请在“可选功能”中修复或安装系统curl，并确认curl.exe可从PATH运行。'
                    $ok = $false
                }
            } catch {
                Write-Bad "Windows curl.exe检查失败：$($_.Exception.Message)；新电脑请修复或安装系统curl后重试。"
                $ok = $false
            }
            $apiKey = Get-AliyunApiKey
            $strictAliyun = $SubtitleSourceMode -eq 'aliyun_only'
            if ([string]::IsNullOrWhiteSpace($apiKey)) {
                if ($strictAliyun) {
                    Write-Bad '仅阿里云模式：API Key尚未配置，音频任务将停止且不会回退本地Whisper。'
                    $ok = $false
                } else {
                    Write-WarnLine '阿里云API Key尚未配置，当前备用模式可使用本地Whisper。'
                }
            } else {
                $cloudCheck = Test-AliyunConnection -ApiKey $apiKey -Model $AliyunModel
                if ($cloudCheck.Success) {
                    Write-Ok $cloudCheck.Message
                } elseif ($strictAliyun) {
                    Write-Bad "仅阿里云模式：$($cloudCheck.Message)；音频任务将停止且不会回退本地Whisper。"
                    $ok = $false
                } else {
                    Write-WarnLine "$($cloudCheck.Message)；当前备用模式可使用本地Whisper。"
                }
            }
        } catch {
            if ($SubtitleSourceMode -eq 'aliyun_only') {
                Write-Bad "仅阿里云模式：阿里云字幕检查失败：$($_.Exception.Message)；音频任务将停止且不会回退本地Whisper。"
                $ok = $false
            } else {
                Write-WarnLine "阿里云字幕检查失败：$($_.Exception.Message)；当前备用模式可使用本地Whisper。"
            }
        }
    }

    Test-NvidiaDriver
    if (-not (Test-Nvenc $ffmpeg)) { $ok = $false }

    $videoCount = Get-CountByExt $videoDir @(".mp4", ".mov", ".mkv", ".webm", ".avi", ".m4v")
    $imageCount = Get-CountByExt $videoDir @(".jpg", ".jpeg", ".png", ".webp", ".bmp")
    $audioCount = Get-CountByExt $audioDir @(".mp3", ".wav", ".m4a", ".aac", ".flac", ".ogg", ".wma")
    if (($videoCount + $imageCount) -gt 0) {
        Write-Ok "视频素材：$videoCount 个；图片素材：$imageCount 个"
    } else {
        Write-Bad "视频或图片素材为空：$videoDir"
        $ok = $false
    }
    if ($audioCount -gt 0) {
        Write-Ok "音频素材：$audioCount 个"
    } else {
        Write-WarnLine "音频素材为空：$audioDir。自动监控模式可以先空着，放入音频后会自动处理。"
    }

    Write-Host ""
    if ($ok) {
        Write-Host "检测结果：可以开始剪辑。" -ForegroundColor Green
    } else {
        Write-Host "检测结果：有问题，请先看上面的红字。" -ForegroundColor Red
    }
    Write-Host "====================================" -ForegroundColor Cyan
    return $ok
}

function Start-AutoCut($IsTest) {
    $ok = Invoke-EnvironmentCheck
    if (-not $ok) {
        Write-Host ""
        Write-Host "环境没有通过检测，已停止启动。" -ForegroundColor Red
        return
    }
    Write-Host ""
    if ($IsTest) {
        Write-Host "开始 10 秒测试..." -ForegroundColor Cyan
        & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root "AutoCut.ps1") -TestMode
    } else {
        Write-Host "开始正式剪辑..." -ForegroundColor Cyan
        & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root "AutoCut.ps1")
    }
}

function Open-OutputFolder {
    $outputDir = Join-Path $Root "完成"
    Ensure-Dir $outputDir
    Start-Process explorer.exe $outputDir
}

function Open-VersionBackupFolder {
    Ensure-Dir $VersionBackupDir
    Start-Process explorer.exe $VersionBackupDir
}

function Start-SubtitleSettings {
    & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root "Subtitle-Settings.ps1")
}

function Start-AutoMonitor {
    & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root "Auto-Monitor.ps1")
}

New-VersionBackup
Write-LauncherLog "启动器已打开"

if ($CheckOnly) {
    Invoke-EnvironmentCheck | Out-Null
    exit
}
if ($Run) {
    Start-AutoCut $false
    exit
}
if ($Test) {
    Start-AutoCut $true
    exit
}

while ($true) {
    Clear-Host
    Write-Host "====== 自动剪辑本地启动器 ======" -ForegroundColor Cyan
    Write-Host "当前根目录：$Root"
    Write-Host ""
    Write-Host "1. 环境检测"
    Write-Host "2. 开始正式剪辑"
    Write-Host "3. 10 秒测试"
    Write-Host "4. 打开完成文件夹"
    Write-Host "5. 打开版本备份文件夹"
    Write-Host "6. 字幕设置器"
    Write-Host "7. 自动监控音频并剪辑"
    Write-Host "0. 退出"
    Write-Host ""
    $choice = Read-Host "请输入数字"
    switch ($choice) {
        "1" {
            Invoke-EnvironmentCheck | Out-Null
            Write-Host ""
            pause
        }
        "2" {
            Start-AutoCut $false
            Write-Host ""
            pause
        }
        "3" {
            Start-AutoCut $true
            Write-Host ""
            pause
        }
        "4" {
            Open-OutputFolder
        }
        "5" {
            Open-VersionBackupFolder
        }
        "6" {
            Start-SubtitleSettings
        }
        "7" {
            Start-AutoMonitor
        }
        "0" {
            break
        }
    }
}
