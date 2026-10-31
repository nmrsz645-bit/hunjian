[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$OutputDirectory,
    [ValidatePattern('^[0-9A-Za-z._-]+$')]
    [string]$Version = '1.0.0'
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$repairScript = Join-Path $PSScriptRoot 'Apply-Paraformer-EmptySpeechRepair.ps1'
$oneClickScript = Join-Path $PSScriptRoot 'OneClick-Paraformer-EmptySpeechRepair.ps1'
$oneClickBatch = Join-Path $PSScriptRoot 'DoubleClick-Repair.bat'
$autoCut = Join-Path $root 'AutoCut.ps1'
$worker = Join-Path $root 'tools\paraformer\paraformer_worker.py'
foreach ($path in @($repairScript, $oneClickScript, $oneClickBatch, $autoCut, $worker)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Required repair source is missing: $path" }
}

$resolvedOutput = [IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Path $resolvedOutput -Force | Out-Null
$zipPath = Join-Path $resolvedOutput ("hun-jian-paraformer-empty-speech-repair-$Version.zip")
if (Test-Path -LiteralPath $zipPath) { throw "Refusing to overwrite existing repair package: $zipPath" }

$stageRoot = Join-Path ([IO.Path]::GetTempPath()) ('hun-jian-empty-speech-repair-' + [guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path $stageRoot -Force | Out-Null
    $payloadRoot = Join-Path $stageRoot 'payload'
    New-Item -ItemType Directory -Path (Join-Path $payloadRoot 'tools\paraformer') -Force | Out-Null
    Copy-Item -LiteralPath $repairScript -Destination (Join-Path $stageRoot 'Apply-Paraformer-EmptySpeechRepair.ps1') -Force
    Copy-Item -LiteralPath $oneClickScript -Destination (Join-Path $stageRoot 'OneClick-Paraformer-EmptySpeechRepair.ps1') -Force
    Copy-Item -LiteralPath $oneClickBatch -Destination (Join-Path $stageRoot 'DoubleClick-Repair.bat') -Force
    Copy-Item -LiteralPath $autoCut -Destination (Join-Path $payloadRoot 'AutoCut.ps1') -Force
    Copy-Item -LiteralPath $worker -Destination (Join-Path $payloadRoot 'tools\paraformer\paraformer_worker.py') -Force

    $readme = @'
Automatic video editor - Paraformer empty-speech offline repair

This package only replaces these application source files:
  app\AutoCut.ps1
  app\tools\paraformer\paraformer_worker.py

It does NOT contain or modify config.ps1, media, logs, work queues, output,
runtime, model_cache, or downloads.

1. Fully close the desktop program and stop monitoring.
2. Extract this ZIP to any temporary folder outside the application folder.
3. Double-click: DoubleClick-Repair.bat
4. In the folder picker, select the hun-jian install folder that directly contains app.
5. Run the 10-second test. If it passes, restart monitoring.

The repair creates a backup under app\backups before replacing either file.
'@
    [IO.File]::WriteAllText((Join-Path $stageRoot 'README.txt'), $readme.Trim() + "`r`n", [Text.UTF8Encoding]::new($false))

    $manifest = [ordered]@{
        id = 'hun-jian-paraformer-empty-speech-repair'
        version = $Version
        createdAtUtc = [DateTime]::UtcNow.ToString('o')
        protectedPathsExcluded = @('config.ps1', 'tools\paraformer\runtime', 'tools\paraformer\model_cache', 'tools\paraformer\downloads', 'work', 'logs', '完成', '视频位置', '音频位置')
        files = @(
            Get-ChildItem -LiteralPath $stageRoot -Recurse -File | ForEach-Object {
                [ordered]@{
                    path = $_.FullName.Substring($stageRoot.Length + 1).Replace('\', '/')
                    sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
                    bytes = $_.Length
                }
            }
        )
    }
    $manifestJson = $manifest | ConvertTo-Json -Depth 5
    [IO.File]::WriteAllText((Join-Path $stageRoot 'manifest.json'), $manifestJson + "`r`n", [Text.UTF8Encoding]::new($false))
    Compress-Archive -Path (Join-Path $stageRoot '*') -DestinationPath $zipPath -CompressionLevel Optimal
} finally {
    Remove-Item -LiteralPath $stageRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output $zipPath
