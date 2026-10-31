[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$OutputDirectory,
    [ValidatePattern('^[0-9A-Za-z][0-9A-Za-z._-]*$')]
    [string]$Version = '1.0.68-rc.1'
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$dotnet = (Get-Command dotnet.exe -ErrorAction Stop).Source
$resolvedOutput = [IO.Path]::GetFullPath($OutputDirectory)
$artifactStem = "hun-jian-v$Version-windows-x64"
$archivePath = Join-Path $resolvedOutput ($artifactStem + '.zip')
$checksumPath = Join-Path $resolvedOutput ($artifactStem + '.sha256')
$repairName = "hun-jian-paraformer-empty-speech-repair-$Version.zip"

foreach ($path in @(
    (Join-Path $root 'desktop-src\AutoCutDesktop.csproj'),
    (Join-Path $root 'repairs\Build-Paraformer-EmptySpeechRepair.ps1'),
    (Join-Path $root 'AutoCut.ps1'),
    (Join-Path $root 'tools\paraformer\paraformer_worker.py')
)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Required release source is missing: $path" }
}

New-Item -ItemType Directory -Path $resolvedOutput -Force | Out-Null
foreach ($path in @($archivePath, $checksumPath, (Join-Path $resolvedOutput $repairName))) {
    if (Test-Path -LiteralPath $path) { throw "Refusing to overwrite an existing release artifact: $path" }
}

function Copy-ReleaseFile([string]$RelativePath, [string]$AppRoot) {
    $source = Join-Path $root $RelativePath
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Required release file is missing: $RelativePath" }
    $destination = Join-Path $AppRoot $RelativePath
    $parent = Split-Path -Parent $destination
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    Copy-Item -LiteralPath $source -Destination $destination -Force
}

function Copy-ReleaseTree([string]$RelativeDirectory, [string]$AppRoot, [string[]]$ExcludedRelativePrefixes = @()) {
    $sourceRoot = Join-Path $root $RelativeDirectory
    if (-not (Test-Path -LiteralPath $sourceRoot -PathType Container)) { throw "Required release directory is missing: $RelativeDirectory" }
    Get-ChildItem -LiteralPath $sourceRoot -Recurse -File | ForEach-Object {
        $relativeFromTree = $_.FullName.Substring($sourceRoot.Length + 1).Replace('\', '/')
        if (@($ExcludedRelativePrefixes | Where-Object { $relativeFromTree.StartsWith($_, [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0) { return }
        $destination = Join-Path (Join-Path $AppRoot $RelativeDirectory) $relativeFromTree
        New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
        Copy-Item -LiteralPath $_.FullName -Destination $destination -Force
    }
}

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('hun-jian-github-release-' + [guid]::NewGuid().ToString('N'))
try {
    $publishRoot = Join-Path $tempRoot 'publish'
    $stageParent = Join-Path $tempRoot 'stage'
    $installRoot = Join-Path $stageParent $artifactStem
    $appRoot = Join-Path $installRoot 'app'
    $repairOutput = Join-Path $tempRoot 'repair'
    New-Item -ItemType Directory -Path $appRoot -Force | Out-Null

    & $dotnet publish (Join-Path $root 'desktop-src\AutoCutDesktop.csproj') -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -p:Version=$Version -o $publishRoot
    if ($LASTEXITCODE -ne 0) { throw "dotnet publish failed with exit code $LASTEXITCODE." }
    $desktopExe = @(Get-ChildItem -LiteralPath $publishRoot -File -Filter '*.exe') | Select-Object -First 1
    if ($null -eq $desktopExe) { throw "Published desktop executable is missing in: $publishRoot" }
    Copy-Item -LiteralPath $desktopExe.FullName -Destination (Join-Path $appRoot $desktopExe.Name) -Force

    $rootFiles = @(
        'AGENTS.md', 'Auto-Monitor.ps1', 'AutoCut-Manager.ps1', 'AutoCut.ps1', 'AutoStart.ps1', 'AutoUpdate.ps1',
        'Dedup-Core.psm1', 'HANDOFF.md', 'Initialize-NewComputer.ps1', 'README.md', 'Segment-Usage.psm1',
        'Start-AutoCut.ps1', 'Subtitle-Aliyun.psm1', 'Subtitle-Core.psm1', 'Subtitle-Preview-Worker.ps1',
        'Subtitle-Settings.ps1', 'TIMEOFF.md', 'UPDATER_HANDOFF.md', 'config.example.ps1'
    )
    foreach ($file in $rootFiles) { Copy-ReleaseFile $file $appRoot }
    Get-ChildItem -LiteralPath $root -File | Where-Object { $_.Extension -in @('.bat', '.txt') } | ForEach-Object {
        Copy-ReleaseFile $_.Name $appRoot
    }
    Copy-ReleaseTree 'effects' $appRoot
    Copy-ReleaseTree 'fonts' $appRoot @('UserAdded/')
    Copy-ReleaseTree 'repairs' $appRoot
    foreach ($file in @('tools\paraformer\Setup-Paraformer.ps1', 'tools\paraformer\paraformer_worker.py')) { Copy-ReleaseFile $file $appRoot }

    $commit = (& git -C $root rev-parse HEAD).Trim()
    $versionInfo = [ordered]@{
        id = 'hun-jian'
        version = $Version
        channel = 'github-prerelease'
        sourceCommit = $commit
        builtAtUtc = [DateTime]::UtcNow.ToString('o')
        productionOssVersion = '1.0.67'
    } | ConvertTo-Json
    [IO.File]::WriteAllText((Join-Path $appRoot 'version.json'), $versionInfo + "`r`n", [Text.UTF8Encoding]::new($false))

    $startCmd = @'
@echo off
setlocal
pushd "%~dp0app"
if not exist "config.ps1" (
  echo First-time setup is required. Run ..\初始化环境.bat, then open 管理界面.bat.
  popd
  pause
  exit /b 1
)
start "" "%CD%\自动剪辑.exe"
popd
'@
    [IO.File]::WriteAllText((Join-Path $installRoot 'Start.cmd'), $startCmd.Trim() + "`r`n", [Text.UTF8Encoding]::new($false))
    $setupCmd = @'
@echo off
setlocal
pushd "%~dp0app"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\Initialize-NewComputer.ps1"
set "SETUP_EXIT=%ERRORLEVEL%"
popd
if not "%SETUP_EXIT%"=="0" pause
exit /b %SETUP_EXIT%
'@
    [IO.File]::WriteAllText((Join-Path $installRoot 'Initialize-Dependencies.bat'), $setupCmd.Trim() + "`r`n", [Text.UTF8Encoding]::new($false))
$installReadme = @(
    "Automatic video editor GitHub prerelease $Version",
    '',
    'This GitHub prerelease does not modify OSS downloads, online manifests, or running legacy installs.',
    '',
    'Install and first start:',
    '1. Extract the entire folder to a writable directory. Do not extract over an active legacy install.',
    '2. When an offline Paraformer package is available, put runtime, model_cache, and downloads directly under app\tools\paraformer.',
    '3. Double-click Initialize-Dependencies.bat. With an offline Paraformer package, run Initialize-NewComputer.ps1 -SkipParaformer from app instead.',
    '4. Double-click Start.cmd after setup, then run environment check and the 10-second test in the desktop UI.',
    '',
    'Never copy config.ps1, media, logs, work, outputs, failed audio, or Paraformer runtime/model_cache/downloads to GitHub.',
    'For the final-silent-audio Paraformer repair, use the separately attached repair ZIP from the same GitHub Release.'
) -join "`r`n"
    [IO.File]::WriteAllText((Join-Path $installRoot 'README-INSTALL.txt'), $installReadme.Trim() + "`r`n", [Text.UTF8Encoding]::new($false))

    & (Join-Path $root 'repairs\Build-Paraformer-EmptySpeechRepair.ps1') -OutputDirectory $repairOutput -Version $Version
    if ($LASTEXITCODE -ne 0) { throw "Repair package build failed with exit code $LASTEXITCODE." }
    $repairPath = Join-Path $resolvedOutput $repairName
    Copy-Item -LiteralPath (Join-Path $repairOutput $repairName) -Destination $repairPath -Force
    Copy-Item -LiteralPath $repairPath -Destination (Join-Path $installRoot $repairName) -Force

    $checksums = Get-ChildItem -LiteralPath $installRoot -Recurse -File | Where-Object { $_.Name -ne 'SHA256SUMS.txt' } | ForEach-Object {
        $relative = $_.FullName.Substring($installRoot.Length + 1).Replace('\', '/')
        "{0}  {1}" -f (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash, $relative
    }
    [IO.File]::WriteAllLines((Join-Path $installRoot 'SHA256SUMS.txt'), @($checksums), [Text.UTF8Encoding]::new($false))
    Compress-Archive -LiteralPath $installRoot -DestinationPath $archivePath -CompressionLevel Optimal
    $archiveHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash
    [IO.File]::WriteAllText($checksumPath, "$archiveHash  $([IO.Path]::GetFileName($archivePath))`r`n", [Text.UTF8Encoding]::new($false))
} finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

[pscustomobject]@{
    ArchivePath = $archivePath
    ChecksumPath = $checksumPath
    RepairPath = Join-Path $resolvedOutput $repairName
    Version = $Version
} | ConvertTo-Json -Compress
