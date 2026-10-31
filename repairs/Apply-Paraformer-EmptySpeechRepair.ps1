[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$InstallRoot
)

$ErrorActionPreference = 'Stop'

function Get-RequiredFile([string]$Path, [string]$Description) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$Description was not found: $Path"
    }
    return (Get-Item -LiteralPath $Path -ErrorAction Stop)
}

$packageRoot = Split-Path -Parent $PSCommandPath
$payloadRoot = Join-Path $packageRoot 'payload'
$resolvedInstallRoot = (Resolve-Path -LiteralPath $InstallRoot -ErrorAction Stop).Path
$appRoot = Join-Path $resolvedInstallRoot 'app'
if (-not (Test-Path -LiteralPath $appRoot -PathType Container)) {
    throw "The selected install root does not contain an app directory: $resolvedInstallRoot"
}

$protectedPayloadPaths = @(
    (Join-Path $payloadRoot 'config.ps1'),
    (Join-Path $payloadRoot 'tools\paraformer\runtime'),
    (Join-Path $payloadRoot 'tools\paraformer\model_cache'),
    (Join-Path $payloadRoot 'tools\paraformer\downloads')
)
foreach ($path in $protectedPayloadPaths) {
    if (Test-Path -LiteralPath $path) {
        throw "Repair package contains forbidden protected data: $path"
    }
}

$files = @(
    [pscustomobject]@{
        RelativePath = 'AutoCut.ps1'
        Source = Join-Path $payloadRoot 'AutoCut.ps1'
        Target = Join-Path $appRoot 'AutoCut.ps1'
    },
    [pscustomobject]@{
        RelativePath = 'tools\paraformer\paraformer_worker.py'
        Source = Join-Path $payloadRoot 'tools\paraformer\paraformer_worker.py'
        Target = Join-Path $appRoot 'tools\paraformer\paraformer_worker.py'
    }
)
foreach ($file in $files) {
    Get-RequiredFile $file.Source "Repair payload $($file.RelativePath)" | Out-Null
    Get-RequiredFile $file.Target "Installed source $($file.RelativePath)" | Out-Null
}

Write-Host 'Close the desktop application and stop monitoring before applying this repair.' -ForegroundColor Yellow
$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$backupRoot = Join-Path $appRoot ("backups\paraformer-empty-speech-repair_$stamp")
New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null

$changed = @()
try {
    foreach ($file in $files) {
        $backup = Join-Path $backupRoot $file.RelativePath
        $backupParent = Split-Path -Parent $backup
        New-Item -ItemType Directory -Path $backupParent -Force | Out-Null
        Copy-Item -LiteralPath $file.Target -Destination $backup -Force
        Copy-Item -LiteralPath $file.Source -Destination $file.Target -Force
        $changed += [pscustomobject]@{ Target = $file.Target; Backup = $backup }
    }

    $worker = [IO.File]::ReadAllText((Join-Path $appRoot 'tools\paraformer\paraformer_worker.py'), [Text.Encoding]::UTF8)
    $autoCut = [IO.File]::ReadAllText((Join-Path $appRoot 'AutoCut.ps1'), [Text.Encoding]::UTF8)
    if (-not $worker.Contains('return False') -or $worker.Contains('if not sentences:')) {
        throw 'Installed Paraformer worker did not pass the no-speech verification.'
    }
    if (-not $autoCut.Contains('Get-Item -LiteralPath $DestinationSrt -ErrorAction Stop')) {
        throw 'Installed AutoCut source did not pass the no-subtitle verification.'
    }
} catch {
    foreach ($file in @($changed | Sort-Object { $_.Target.Length } -Descending)) {
        if (Test-Path -LiteralPath $file.Backup -PathType Leaf) {
            Copy-Item -LiteralPath $file.Backup -Destination $file.Target -Force -ErrorAction SilentlyContinue
        }
    }
    throw
}

Write-Host 'Repair applied successfully.' -ForegroundColor Green
Write-Host "Source backup: $backupRoot"
Write-Host 'Run the 10-second test, then restart monitoring.'
