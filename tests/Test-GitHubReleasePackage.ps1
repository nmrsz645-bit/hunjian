[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$ArchivePath,
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$ChecksumPath,
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$RepairPath
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Test-Helpers.ps1"

$root = Split-Path -Parent $PSScriptRoot
$builder = Join-Path $root 'tools\Build-GitHubRelease.ps1'
Assert-True (Test-Path -LiteralPath $builder -PathType Leaf) 'GitHub release builder is missing.'
Assert-True (Test-Path -LiteralPath $ArchivePath -PathType Leaf) "Release archive is missing: $ArchivePath"
Assert-True (Test-Path -LiteralPath $ChecksumPath -PathType Leaf) "Release checksum manifest is missing: $ChecksumPath"
Assert-True (Test-Path -LiteralPath $RepairPath -PathType Leaf) "Standalone repair archive is missing: $RepairPath"

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('hun-jian-github-release-audit-' + [guid]::NewGuid().ToString('N'))
try {
    Expand-Archive -LiteralPath $ArchivePath -DestinationPath $tempRoot -Force
    $topLevel = @(Get-ChildItem -LiteralPath $tempRoot -Force)
    Assert-True ($topLevel.Count -eq 1 -and $topLevel[0].PSIsContainer) 'Release archive must have exactly one top-level install folder.'
    $installRoot = $topLevel[0].FullName
    $appRoot = Join-Path $installRoot 'app'
    Assert-True (Test-Path -LiteralPath $appRoot -PathType Container) 'Release archive must contain app directory.'

    foreach ($required in @(
        'Start.cmd',
        'README-INSTALL.txt',
        'SHA256SUMS.txt',
        'app\Start-AutoCut.ps1',
        'app\Initialize-NewComputer.ps1',
        'app\AutoCut.ps1',
        'app\Auto-Monitor.ps1',
        'app\config.example.ps1',
        'app\README.md',
        'app\HANDOFF.md',
        'app\repairs\Build-Paraformer-EmptySpeechRepair.ps1',
        'app\repairs\DoubleClick-Repair.bat'
    )) {
        Assert-True (Test-Path -LiteralPath (Join-Path $installRoot $required) -PathType Leaf) "Release archive is missing: $required"
    }
    Assert-True (@(Get-ChildItem -LiteralPath $appRoot -File -Filter '*.exe').Count -eq 1) 'Release archive must contain exactly one published desktop executable.'
    $allowedAppDirectories = @('effects', 'fonts', 'repairs', 'tools')
    $unexpectedAppDirectories = @(Get-ChildItem -LiteralPath $appRoot -Directory | Where-Object { $_.Name -notin $allowedAppDirectories })
    Assert-True ($unexpectedAppDirectories.Count -eq 0) ('Release archive contains unexpected top-level app directories: ' + ($unexpectedAppDirectories.Name -join ', '))

    $relativeFiles = @(Get-ChildItem -LiteralPath $installRoot -Recurse -Force | ForEach-Object {
        $_.FullName.Substring($installRoot.Length + 1).Replace('\', '/')
    })
    foreach ($forbidden in @(
        'app/config.ps1',
        'app/config/',
        'app/logs/',
        'app/work/',
        'app/完成/',
        'app/失败音频/',
        'app/视频位置/',
        'app/音频位置/',
        'app/backups/',
        'app/banbenbeifen/',
        'app/fonts/UserAdded/',
        'app/tools/paraformer/runtime/',
        'app/tools/paraformer/model_cache/',
        'app/tools/paraformer/downloads/',
        '.env'
    )) {
        Assert-True (-not (@($relativeFiles | Where-Object { $_ -eq $forbidden.TrimEnd('/') -or $_.StartsWith($forbidden) }).Count -gt 0)) "Release archive contains forbidden data: $forbidden"
    }

    $expectedHash = (Get-FileHash -LiteralPath $ArchivePath -Algorithm SHA256).Hash
    $checksums = [IO.File]::ReadAllText($ChecksumPath, [Text.Encoding]::UTF8)
    Assert-True ($checksums.Contains($expectedHash)) 'Checksum manifest does not contain release ZIP SHA-256.'
    Assert-True ($checksums -notmatch '(?im)^\s*(?:api[_-]?key|secret|password|token|cookie)\s*[=:]\s*[^$<\s]') 'Checksum manifest must not contain a credential.'

    $readme = [IO.File]::ReadAllText((Join-Path $appRoot 'README.md'), [Text.Encoding]::UTF8)
    $handoff = [IO.File]::ReadAllText((Join-Path $appRoot 'HANDOFF.md'), [Text.Encoding]::UTF8)
    Assert-True ($readme -match '1\.0\.68-rc\.1') 'README must identify the GitHub prerelease version.'
    Assert-True ($handoff -match 'Paraformer' -and $handoff -match '1\.0\.68-rc\.1') 'HANDOFF must describe Paraformer and this prerelease.'

    $repairRoot = Join-Path $tempRoot 'repair'
    Expand-Archive -LiteralPath $RepairPath -DestinationPath $repairRoot -Force
    foreach ($requiredRepairFile in @('DoubleClick-Repair.bat', 'OneClick-Paraformer-EmptySpeechRepair.ps1', 'Apply-Paraformer-EmptySpeechRepair.ps1', 'payload\AutoCut.ps1', 'payload\tools\paraformer\paraformer_worker.py', 'manifest.json')) {
        Assert-True (Test-Path -LiteralPath (Join-Path $repairRoot $requiredRepairFile) -PathType Leaf) "Standalone repair archive is missing: $requiredRepairFile"
    }
    foreach ($forbiddenRepairPath in @('payload\config.ps1', 'payload\tools\paraformer\runtime', 'payload\tools\paraformer\model_cache', 'payload\tools\paraformer\downloads')) {
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $repairRoot $forbiddenRepairPath))) "Standalone repair archive contains protected data: $forbiddenRepairPath"
    }
} finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host 'PASS Test-GitHubReleasePackage' -ForegroundColor Green
