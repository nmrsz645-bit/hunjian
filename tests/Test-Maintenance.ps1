$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Test-Helpers.ps1"

$root = Split-Path -Parent $PSScriptRoot
$autoCut = [IO.File]::ReadAllText((Join-Path $root 'AutoCut.ps1'), [Text.Encoding]::UTF8)
$launcher = [IO.File]::ReadAllText((Join-Path $root 'Start-AutoCut.ps1'), [Text.Encoding]::UTF8)
$config = [IO.File]::ReadAllText((Join-Path $root 'config.ps1'), [Text.Encoding]::UTF8)

Assert-True ($config -match '\$SoftwareBackupKeepCount\s*=\s*5') '软件备份数量必须配置为最近5个'
Assert-True ($config -match '\$FailedWorkRetentionHours\s*=\s*24') '失败任务临时目录必须保留24小时'

$backupFunction = [regex]::Match($autoCut, '(?s)function\s+Remove-OldBackupFiles\s*\([^)]*\)\s*\{.*?\n\}').Value
$expiredWorkFunction = [regex]::Match($autoCut, '(?s)function\s+Remove-ExpiredWorkDirectories\s*\([^)]*\)\s*\{.*?\n\}').Value
$successWorkFunction = [regex]::Match($autoCut, '(?s)function\s+Remove-SuccessfulWorkDirectory\s*\([^)]*\)\s*\{.*?\n\}').Value
foreach ($item in @($backupFunction, $expiredWorkFunction, $successWorkFunction)) {
    Assert-True (-not [string]::IsNullOrWhiteSpace($item)) '主程序必须包含长期运行清理函数'
    Invoke-Expression $item
}

$tempRoot = Join-Path $env:TEMP ("autocut_maintenance_{0}" -f ([guid]::NewGuid().ToString('N')))
$backupDir = Join-Path $tempRoot 'backups'
$workDir = Join-Path $tempRoot 'work'
New-Item -ItemType Directory -Path $backupDir, $workDir -Force | Out-Null
try {
    1..7 | ForEach-Object {
        $file = Join-Path $backupDir ("software_20260710_120{0}00.zip" -f $_)
        [IO.File]::WriteAllText($file, [string]$_)
        (Get-Item -LiteralPath $file).LastWriteTime = (Get-Date).AddMinutes($_)
    }
    Remove-OldBackupFiles $backupDir 'software_*.zip' 5
    Assert-Equal 5 @(Get-ChildItem -LiteralPath $backupDir -File).Count '软件备份必须只保留最近5个'

    $oldFailed = Join-Path $workDir '失败任务_20260701_120000'
    $recentFailed = Join-Path $workDir '失败任务_20260710_120000'
    $cache = Join-Path $workDir 'subtitle_cache'
    New-Item -ItemType Directory -Path $oldFailed, $recentFailed, $cache -Force | Out-Null
    (Get-Item -LiteralPath $oldFailed).LastWriteTime = (Get-Date).AddHours(-25)
    (Get-Item -LiteralPath $recentFailed).LastWriteTime = (Get-Date).AddHours(-2)
    (Get-Item -LiteralPath $cache).LastWriteTime = (Get-Date).AddDays(-30)
    Remove-ExpiredWorkDirectories $workDir 24
    Assert-True (-not (Test-Path -LiteralPath $oldFailed)) '超过24小时的失败任务目录必须删除'
    Assert-True (Test-Path -LiteralPath $recentFailed) '24小时内的失败任务目录必须保留'
    Assert-True (Test-Path -LiteralPath $cache) '字幕缓存目录不得被长期清理误删'

    Remove-SuccessfulWorkDirectory $recentFailed $workDir
    Assert-True (-not (Test-Path -LiteralPath $recentFailed)) '成功任务目录必须立即删除'
} finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Assert-True ($autoCut -match 'Remove-SuccessfulWorkDirectory\s+\$audioWork\s+\$WorkDir') '正式成功发布后必须清理当前任务目录'
Assert-True ($launcher -match 'Remove-OldBackupFiles.+program_version_\*\.zip') '启动器版本备份必须只保留最近数量'

Write-Host 'PASS Test-Maintenance' -ForegroundColor Green
