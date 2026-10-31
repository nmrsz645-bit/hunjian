$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Test-Helpers.ps1"

$root = Split-Path -Parent $PSScriptRoot
$builder = Join-Path $root 'repairs\Build-Paraformer-EmptySpeechRepair.ps1'
$repair = Join-Path $root 'repairs\Apply-Paraformer-EmptySpeechRepair.ps1'
$oneClick = Join-Path $root 'repairs\OneClick-Paraformer-EmptySpeechRepair.ps1'
$oneClickBatch = Join-Path $root 'repairs\DoubleClick-Repair.bat'

Assert-True (Test-Path -LiteralPath $builder -PathType Leaf) 'Empty-speech repair package builder is missing.'
Assert-True (Test-Path -LiteralPath $repair -PathType Leaf) 'Empty-speech repair installer is missing.'
Assert-True (Test-Path -LiteralPath $oneClick -PathType Leaf) 'One-click repair launcher is missing.'
Assert-True (Test-Path -LiteralPath $oneClickBatch -PathType Leaf) 'One-click repair batch file is missing.'

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('paraformer-empty-speech-repair-' + [guid]::NewGuid().ToString('N'))
try {
    $outputDir = Join-Path $tempRoot 'output'
    $installRoot = Join-Path $tempRoot 'legacy-install'
    $appRoot = Join-Path $installRoot 'app'
    $payloadRoot = Join-Path $tempRoot 'payload'
    [IO.Directory]::CreateDirectory($appRoot) | Out-Null
    [IO.Directory]::CreateDirectory((Join-Path $appRoot 'tools\paraformer')) | Out-Null
    [IO.Directory]::CreateDirectory((Join-Path $appRoot 'tools\paraformer\runtime')) | Out-Null
    [IO.Directory]::CreateDirectory((Join-Path $appRoot 'tools\paraformer\model_cache')) | Out-Null
    [IO.Directory]::CreateDirectory((Join-Path $appRoot 'tools\paraformer\downloads')) | Out-Null

    $oldAutoCut = (& git -C $root show 'HEAD:AutoCut.ps1') -join "`n"
    $oldWorker = (& git -C $root show 'HEAD:tools/paraformer/paraformer_worker.py') -join "`n"
    [IO.File]::WriteAllText((Join-Path $appRoot 'AutoCut.ps1'), $oldAutoCut, [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $appRoot 'tools\paraformer\paraformer_worker.py'), $oldWorker, [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $appRoot 'config.ps1'), 'sentinel-config', [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $appRoot 'tools\paraformer\runtime\sentinel.txt'), 'sentinel-runtime', [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $appRoot 'tools\paraformer\model_cache\sentinel.txt'), 'sentinel-model', [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $appRoot 'tools\paraformer\downloads\sentinel.txt'), 'sentinel-download', [Text.UTF8Encoding]::new($false))

    & $builder -OutputDirectory $outputDir -Version 'test'
    if (-not $?) { throw 'Repair package builder failed.' }
    $zip = Get-ChildItem -LiteralPath $outputDir -Filter '*.zip' -File | Select-Object -First 1
    Assert-True ($null -ne $zip) 'Repair package ZIP was not created.'
    Expand-Archive -LiteralPath $zip.FullName -DestinationPath $payloadRoot -Force

    foreach ($required in @('DoubleClick-Repair.bat', 'OneClick-Paraformer-EmptySpeechRepair.ps1', 'Apply-Paraformer-EmptySpeechRepair.ps1', 'README.txt', 'payload\AutoCut.ps1', 'payload\tools\paraformer\paraformer_worker.py', 'manifest.json')) {
        Assert-True (Test-Path -LiteralPath (Join-Path $payloadRoot $required) -PathType Leaf) "Repair package is missing: $required"
    }
    foreach ($forbidden in @('payload\config.ps1', 'payload\tools\paraformer\runtime', 'payload\tools\paraformer\model_cache', 'payload\tools\paraformer\downloads')) {
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $payloadRoot $forbidden))) "Repair package must not contain protected data: $forbidden"
    }

    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $payloadRoot 'OneClick-Paraformer-EmptySpeechRepair.ps1') -InstallRoot $installRoot
    if ($LASTEXITCODE -ne 0) { throw "One-click repair launcher failed with exit code $LASTEXITCODE." }

    $installedWorker = [IO.File]::ReadAllText((Join-Path $appRoot 'tools\paraformer\paraformer_worker.py'), [Text.Encoding]::UTF8)
    $installedAutoCut = [IO.File]::ReadAllText((Join-Path $appRoot 'AutoCut.ps1'), [Text.Encoding]::UTF8)
    Assert-True ($installedWorker.Contains('return False')) 'Repair must install no-speech Paraformer behavior.'
    Assert-True (-not $installedWorker.Contains('if not sentences:')) 'Repair must remove the legacy no-speech exception.'
    Assert-True ($installedAutoCut.Contains('Get-Item -LiteralPath $DestinationSrt -ErrorAction Stop')) 'Repair must install no-subtitle render behavior.'
    foreach ($protected in @('config.ps1', 'tools\paraformer\runtime\sentinel.txt', 'tools\paraformer\model_cache\sentinel.txt', 'tools\paraformer\downloads\sentinel.txt')) {
        Assert-True ([IO.File]::ReadAllText((Join-Path $appRoot $protected), [Text.Encoding]::UTF8) -like 'sentinel-*') "Repair must preserve protected data: $protected"
    }
    $backup = Get-ChildItem -LiteralPath (Join-Path $appRoot 'backups') -Directory | Select-Object -First 1
    Assert-True ($null -ne $backup) 'Repair must create a source backup before replacement.'
    Assert-True (Test-Path -LiteralPath (Join-Path $backup.FullName 'AutoCut.ps1') -PathType Leaf) 'Repair backup is missing AutoCut.ps1.'
    Assert-True (Test-Path -LiteralPath (Join-Path $backup.FullName 'tools\paraformer\paraformer_worker.py') -PathType Leaf) 'Repair backup is missing paraformer_worker.py.'
} finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host 'PASS Test-Paraformer-EmptySpeechRepair' -ForegroundColor Green
