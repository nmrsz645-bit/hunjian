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
Write-Output 'PASS Test-Monitor-Retry'
