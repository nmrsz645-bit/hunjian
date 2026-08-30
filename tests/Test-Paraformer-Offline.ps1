$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$worker = [IO.File]::ReadAllText((Join-Path $root 'tools\paraformer\paraformer_worker.py'), [Text.Encoding]::UTF8)
$autoCut = [IO.File]::ReadAllText((Join-Path $root 'AutoCut.ps1'), [Text.Encoding]::UTF8)

foreach ($expected in @('MODELSCOPE_CACHE', 'local_snapshot', 'iic--speech_seaco_paraformer_large_asr_nat-zh-cn-16k-common-vocab8404-pytorch', 'iic--speech_fsmn_vad_zh-cn-16k-common-pytorch', 'iic--punc_ct-transformer_cn-en-common-vocab471067-large', 'disable_update=True')) {
    if (-not $worker.Contains($expected)) { throw "Missing offline Paraformer requirement: $expected" }
}
foreach ($expected in @('$workerExitCode = $process.ExitCode', 'ConvertTo-WindowsCommandLineArgument', 'Start-Process -FilePath $ParaformerPython -ArgumentList $workerArgumentString', '[IO.File]::WriteAllText($runLog', 'Test-ParaformerRuntimeReady')) {
    if (-not $autoCut.Contains($expected)) { throw "Missing Paraformer diagnostic requirement: $expected" }
}
$ui = [IO.File]::ReadAllText((Join-Path $root 'Subtitle-Settings.ps1'), [Text.Encoding]::UTF8)
foreach ($expected in @('$env:MODELSCOPE_CACHE = $ParaformerModelCache', 'Start-Process -FilePath $ParaformerPython', "'--warmup'")) {
    if (-not $ui.Contains($expected)) { throw "Missing manual Paraformer readiness check: $expected" }
}
$runtimeCheck = [regex]::Match($autoCut, '(?s)function\s+Test-ParaformerRuntimeReady\s*\([^)]*\)\s*\{.*?\n\}').Value
if ([string]::IsNullOrWhiteSpace($runtimeCheck)) { throw 'Missing production Paraformer runtime check.' }
if ($runtimeCheck -match '--warmup|Start-Process') { throw 'Production Paraformer runtime check must not load models before recognition.' }
foreach ($expected in @('PathType Leaf', 'model.pt', 'Length -le 0', 'return $true')) {
    if (-not $runtimeCheck.Contains($expected)) { throw "Missing lightweight production runtime check: $expected" }
}
foreach ($expected in @("Local\\HunJian_Paraformer", 'WaitOne', 'WaitForExit\(\$timeoutMilliseconds\)', 'Paraformer 识别超时')) {
    if ($autoCut -notmatch $expected) { throw "Missing Paraformer concurrency or timeout protection: $expected" }
}
$setup = [IO.File]::ReadAllText((Join-Path $root 'tools\paraformer\Setup-Paraformer.ps1'), [Text.Encoding]::UTF8)
foreach ($expected in @('Get-ParaformerTorchPackage', 'RTX\s*50\d{2}', 'torch==2.7.1+cu128', 'https://download.pytorch.org/whl/cu128', 'PARAFORMER_DEVICE_FALLBACK=cpu')) {
    if (-not $setup.Contains($expected) -and -not $worker.Contains($expected)) { throw "Missing GPU compatibility requirement: $expected" }
}
Write-Output 'PASS Test-Paraformer-Offline'
