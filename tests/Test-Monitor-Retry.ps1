$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$monitorPath = Join-Path $root 'Auto-Monitor.ps1'
$source = [IO.File]::ReadAllText($monitorPath, [Text.Encoding]::UTF8)
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$errors)
if ($errors.Count -gt 0) { throw "Auto-Monitor.ps1 parse failed: $($errors[0].Message)" }
$functionAst = $ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Test-RetryableFailure' }, $true) | Select-Object -First 1
if (-not $functionAst) { throw 'Missing Test-RetryableFailure.' }
Invoke-Expression $functionAst.Extent.Text
foreach ($case in @(
    @{ Message = 'HTTP 500 temporary network failure'; Expected = $true },
    @{ Message = 'The process cannot access the file because it is being used by another process'; Expected = $true },
    @{ Message = 'Paraformer 识别失败（退出码：1）'; Expected = $false },
    @{ Message = 'CUDA out of memory'; Expected = $false },
    @{ Message = 'FFmpeg 退出码：-28，日志：x'; Expected = $false },
    @{ Message = 'No space left on device'; Expected = $false }
)) {
    if ((Test-RetryableFailure $case.Message) -ne $case.Expected) { throw "Unexpected retry classification: $($case.Message)" }
}

$removeFunctionAst = $ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Remove-ProcessedAudio' }, $true) | Select-Object -First 1
if (-not $removeFunctionAst) { throw 'Missing Remove-ProcessedAudio.' }
$removeFunctionText = $removeFunctionAst.Extent.Text
$audioDelete = $removeFunctionText.IndexOf('Remove-Item -LiteralPath $AudioPath')
$textDelete = $removeFunctionText.IndexOf('Remove-Item -LiteralPath $textPath')
if ($audioDelete -lt 0 -or $textDelete -lt 0 -or $audioDelete -ge $textDelete) { throw 'Source audio must be deleted before its sidecar TXT.' }
if ($removeFunctionText -notmatch 'try\s*\{[\s\S]*Remove-Item -LiteralPath \$textPath' -or $removeFunctionText -notmatch '保留同名文本稿') { throw 'A failed sidecar deletion must preserve the TXT and only log a warning.' }

function Get-SidecarTextPath($AudioPath) {
    $candidate = [IO.Path]::ChangeExtension($AudioPath, '.txt')
    if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    return $null
}
function Write-MonitorLog($Message, $Color) { }
Invoke-Expression $removeFunctionAst.Extent.Text
$cleanupRoot = Join-Path ([IO.Path]::GetTempPath()) ('monitor_sidecar_' + [guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path $cleanupRoot -Force | Out-Null
    $audio = Join-Path $cleanupRoot 'normal.mp3'
    $text = [IO.Path]::ChangeExtension($audio, '.txt')
    [IO.File]::WriteAllText($audio, 'audio', [Text.Encoding]::UTF8)
    [IO.File]::WriteAllText($text, 'sidecar', [Text.Encoding]::UTF8)
    Remove-ProcessedAudio $audio
    if ((Test-Path -LiteralPath $audio) -or (Test-Path -LiteralPath $text)) { throw 'Successful cleanup must remove both source audio and TXT.' }

    $lockedAudio = Join-Path $cleanupRoot 'locked.mp3'
    $lockedText = [IO.Path]::ChangeExtension($lockedAudio, '.txt')
    [IO.File]::WriteAllText($lockedAudio, 'audio', [Text.Encoding]::UTF8)
    [IO.File]::WriteAllText($lockedText, 'sidecar', [Text.Encoding]::UTF8)
    $lock = [IO.File]::Open($lockedAudio, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        $failed = $false
        try { Remove-ProcessedAudio $lockedAudio } catch { $failed = $true }
        if (-not $failed -or -not (Test-Path -LiteralPath $lockedText)) { throw 'If source audio cannot be deleted, its TXT must remain.' }
    } finally {
        $lock.Dispose()
    }
} finally {
    Remove-Item -LiteralPath $cleanupRoot -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Output 'PASS Test-Monitor-Retry'
