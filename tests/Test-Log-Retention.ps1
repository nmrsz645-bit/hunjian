$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Test-Helpers.ps1"

$root = Split-Path -Parent $PSScriptRoot
$config = [IO.File]::ReadAllText((Join-Path $root 'config.ps1'), [Text.Encoding]::UTF8)
Assert-True ($config -match '\$UnimportantLogRetentionHours\s*=\s*24') '低价值日志必须只保留24小时'

foreach ($name in @('AutoCut.ps1', 'Auto-Monitor.ps1', 'AutoCut-Manager.ps1', 'Start-AutoCut.ps1')) {
    $text = [IO.File]::ReadAllText((Join-Path $root $name), [Text.Encoding]::UTF8)
    Assert-True ($text -match 'AddHours\(-\$hours\)') "$name 必须按小时清理过期日志"
    Assert-True ($text -notmatch '\$hours\s*=\s*72') "$name 的默认保留期不得继续是72小时"
}

$autoCut = [IO.File]::ReadAllText((Join-Path $root 'AutoCut.ps1'), [Text.Encoding]::UTF8)
$cleanup = [regex]::Match($autoCut, '(?s)function\s+Clear-UnimportantLogs\s*\{.*?\n\}').Value
Assert-True ($cleanup -match 'File -Recurse -Filter "\*\.log"') '所有日志必须按24小时统一清理'
Assert-True ($cleanup -match 'activeLogPath') '清理时必须跳过当前正在写入的运行日志'
Assert-True ($autoCut -match 'LogMaxBytes\s*=\s*10MB') '运行日志必须在10MB分卷'
Assert-True ($autoCut -match '"-stats_period", "5", "-stats"') 'FFmpeg进度必须限制为每5秒一次'
$monitor = [IO.File]::ReadAllText((Join-Path $root 'Auto-Monitor.ps1'), [Text.Encoding]::UTF8)
Assert-True ($monitor -match 'MonitorLogMaxBytes\s*=\s*10MB') '监控日志必须在10MB分卷'
$desktop = [IO.File]::ReadAllText((Join-Path $root 'desktop-src\Program.cs'), [Text.Encoding]::UTF8)
Assert-True ($desktop -match 'ReadLatestLogLines\(2000\)') '界面必须只读取最近2000行日志'
Assert-True ($desktop -match 'stream\.Seek\(-tailBytes, SeekOrigin\.End\)') '界面不得从头遍历大日志'

$tempRoot = Join-Path $env:TEMP ("autocut_log_retention_{0}" -f ([guid]::NewGuid().ToString('N')))
try {
    New-Item -ItemType Directory -Path (Join-Path $tempRoot 'ffmpeg') -Force | Out-Null
    $oldJob = Join-Path $tempRoot 'old.job.log'
    $oldFfmpeg = Join-Path $tempRoot 'ffmpeg\old.ffmpeg.log'
    $oldImportantRun = Join-Path $tempRoot 'run_old.log'
    $recentImportantRun = Join-Path $tempRoot 'run_recent.log'
    $activeRun = Join-Path $tempRoot 'run_active.log'
    $recentJob = Join-Path $tempRoot 'recent.job.log'
    foreach ($path in @($oldJob, $oldFfmpeg, $oldImportantRun, $recentImportantRun, $recentJob, $activeRun)) { [IO.File]::WriteAllText($path, 'test') }
    (Get-Item -LiteralPath $oldJob).LastWriteTime = (Get-Date).AddHours(-25)
    (Get-Item -LiteralPath $oldFfmpeg).LastWriteTime = (Get-Date).AddHours(-25)
    (Get-Item -LiteralPath $oldImportantRun).LastWriteTime = (Get-Date).AddHours(-25)
    (Get-Item -LiteralPath $recentImportantRun).LastWriteTime = (Get-Date).AddHours(-23)
    (Get-Item -LiteralPath $activeRun).LastWriteTime = (Get-Date).AddHours(-25)
    Invoke-Expression $cleanup
    $LogDir = $tempRoot
    $UnimportantLogRetentionHours = 24
    $LogFile = $activeRun
    Clear-UnimportantLogs
    Assert-True (-not (Test-Path -LiteralPath $oldJob)) '超过24小时的任务日志必须删除'
    Assert-True (-not (Test-Path -LiteralPath $oldFfmpeg)) '超过24小时的FFmpeg日志必须删除'
    Assert-True (Test-Path -LiteralPath $recentJob) '24小时内的任务日志必须保留'
    Assert-True (-not (Test-Path -LiteralPath $oldImportantRun)) '超过24小时的运行日志必须删除'
    Assert-True (Test-Path -LiteralPath $recentImportantRun) '24小时内的运行日志必须保留'
    Assert-True (Test-Path -LiteralPath $activeRun) '当前正在写入的运行日志必须保留'
} finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host 'PASS Test-Log-Retention' -ForegroundColor Green
