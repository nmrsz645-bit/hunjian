$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$sourcePath = Join-Path $root 'AutoCut.ps1'
$source = [IO.File]::ReadAllText($sourcePath, [Text.Encoding]::UTF8)
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$errors)
if ($errors.Count -gt 0) { throw "AutoCut.ps1 parse failed: $($errors[0].Message)" }

function Get-FunctionText([string]$Name) {
    $fn = $ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name }, $true) | Select-Object -First 1
    if (-not $fn) { throw "Missing function: $Name" }
    return $fn.Extent.Text
}

$functionTexts = @()
foreach ($name in @('Test-ParaformerRuntimeReady', 'Ensure-ParaformerRuntime', 'ConvertTo-WindowsCommandLineArgument', 'Invoke-ParaformerSrt', 'Invoke-ParaformerBatch')) {
    $functionText = Get-FunctionText $name
    $functionTexts += $functionText
    Invoke-Expression $functionText
}

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("paraformer_single_load_space_" + [guid]::NewGuid().ToString('N'))
try {
    [IO.Directory]::CreateDirectory($tempRoot) | Out-Null
    $ParaformerRoot = Join-Path $tempRoot 'paraformer'
    $ParaformerPython = Join-Path $root 'tools\paraformer\runtime\python.exe'
    if (-not (Test-Path -LiteralPath $ParaformerPython -PathType Leaf)) {
        $fallbackPython = Get-Command python.exe -ErrorAction Stop
        $ParaformerPython = $fallbackPython.Source
        Write-Output "INFO Test fallback Python: $ParaformerPython"
    }
    $ParaformerWorker = Join-Path $tempRoot 'fake_worker.py'
    $ParaformerSetup = Join-Path $tempRoot 'fake_setup.ps1'
    $ParaformerModelCache = Join-Path $ParaformerRoot 'model_cache'
    $LogDir = Join-Path $tempRoot 'logs'
    [IO.Directory]::CreateDirectory($LogDir) | Out-Null
    [IO.File]::WriteAllText($ParaformerSetup, '', [Text.UTF8Encoding]::new($true))
    $modelFiles = @()
    foreach ($modelName in @('iic--speech_seaco_paraformer_large_asr_nat-zh-cn-16k-common-vocab8404-pytorch', 'iic--speech_fsmn_vad_zh-cn-16k-common-pytorch', 'iic--punc_ct-transformer_cn-en-common-vocab471067-large')) {
        $modelFile = Join-Path $ParaformerModelCache ("models\$modelName\snapshots\master\model.pt")
        [IO.Directory]::CreateDirectory((Split-Path -Parent $modelFile)) | Out-Null
        [IO.File]::WriteAllBytes($modelFile, [byte[]](1))
        $modelFiles += $modelFile
    }
    $workerCode = @'
import argparse, json, os, time
p = argparse.ArgumentParser()
p.add_argument('--audio')
p.add_argument('--srt')
p.add_argument('--json')
p.add_argument('--batch-manifest')
a = p.parse_args()
count_path = os.environ['HUNJIAN_TEST_COUNT']
active_path = os.environ.get('HUNJIAN_TEST_ACTIVE', '')
overlap_path = os.environ.get('HUNJIAN_TEST_OVERLAP', '')
count = 0
if os.path.exists(count_path):
    with open(count_path, 'r', encoding='utf-8') as f:
        count = int(f.read() or '0')
with open(count_path, 'w', encoding='utf-8') as f:
    f.write(str(count + 1))
owns_active = False
if active_path:
    try:
        fd = os.open(active_path, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
        os.close(fd)
        owns_active = True
    except FileExistsError:
        with open(overlap_path, 'w', encoding='utf-8') as f:
            f.write('overlap')
try:
    time.sleep(float(os.environ.get('HUNJIAN_TEST_SLEEP', '0')))
    outputs = [{'srt': a.srt, 'json': a.json}] if not a.batch_manifest else json.load(open(a.batch_manifest, encoding='utf-8'))
    for output in outputs:
        with open(output['srt'], 'w', encoding='utf-8-sig') as f:
            f.write('1\n00:00:00,000 --> 00:00:01,000\n测试字幕\n')
        with open(output['json'], 'w', encoding='utf-8') as f:
            json.dump({'text': '测试字幕'}, f, ensure_ascii=False)
finally:
    if owns_active and os.path.exists(active_path):
        os.remove(active_path)
print('[INFO] fake Paraformer completed', file=__import__('sys').stderr)
'@
    [IO.File]::WriteAllText($ParaformerWorker, $workerCode, [Text.UTF8Encoding]::new($false))
    function Write-Log([string]$Message) {}

    $realPython = $ParaformerPython
    $ParaformerPython = Join-Path $tempRoot 'missing_python.exe'
    $runtimeReason = ''
    if (Test-ParaformerRuntimeReady ([ref]$runtimeReason)) { throw 'Missing Python must not pass runtime validation.' }
    $ParaformerPython = $realPython
    [IO.File]::WriteAllBytes($modelFiles[0], [byte[]]@())
    $runtimeReason = ''
    if (Test-ParaformerRuntimeReady ([ref]$runtimeReason)) { throw 'Empty model file must not pass runtime validation.' }
    [IO.File]::WriteAllBytes($modelFiles[0], [byte[]](1))
    $runtimeReason = ''
    if (-not (Test-ParaformerRuntimeReady ([ref]$runtimeReason))) { throw 'Complete runtime must pass lightweight validation.' }

    $audioPath = Join-Path $tempRoot 'one audio.mp3'
    [IO.File]::WriteAllBytes($audioPath, [byte[]](1,2,3))
    $audio = Get-Item -LiteralPath $audioPath
    $countPath = Join-Path $tempRoot 'count.txt'
    $env:HUNJIAN_TEST_COUNT = $countPath
    $env:HUNJIAN_TEST_SLEEP = '0'
    $srt = Join-Path $tempRoot 'one subtitle.srt'
    try {
        Invoke-ParaformerSrt $audio 1 $srt $false $tempRoot 10
    } catch {
        $evidence = Join-Path $tempRoot 'paraformer.log'
        if (Test-Path -LiteralPath $evidence -PathType Leaf) { Write-Output (Get-Content -LiteralPath $evidence -Raw -Encoding UTF8) }
        Get-ChildItem -LiteralPath $tempRoot -File -Force -ErrorAction SilentlyContinue | Select-Object Name,Length | Format-Table -AutoSize
        throw
    }
    if ((Get-Content -LiteralPath $countPath -Raw -Encoding UTF8) -ne '1') { throw 'One audio must start the recognition worker exactly once.' }
    if (-not (Test-Path -LiteralPath $srt -PathType Leaf)) { throw 'Single-load invocation did not create SRT.' }
    if ((Get-Content -LiteralPath (Join-Path $tempRoot 'paraformer.log') -Raw -Encoding UTF8) -notmatch 'fake Paraformer completed') { throw 'Redirected worker evidence is missing.' }

    [IO.File]::WriteAllText($countPath, '0', [Text.UTF8Encoding]::new($false))
    $batchDir = Join-Path $tempRoot 'batch'
    [IO.Directory]::CreateDirectory($batchDir) | Out-Null
    $batchEntries = @(
        [pscustomobject]@{ Audio = $audioPath; Srt = (Join-Path $batchDir 'one.srt'); Json = (Join-Path $batchDir 'one.json') },
        [pscustomobject]@{ Audio = $audioPath; Srt = (Join-Path $batchDir 'two.srt'); Json = (Join-Path $batchDir 'two.json') }
    )
    Invoke-ParaformerBatch $batchEntries 2 $batchDir 10
    if ((Get-Content -LiteralPath $countPath -Raw -Encoding UTF8) -ne '1') { throw 'A batch of timeline chunks must start one worker only.' }
    foreach ($entry in $batchEntries) {
        if (-not (Test-Path -LiteralPath $entry.Srt -PathType Leaf)) { throw 'Batch invocation did not create every chunk SRT.' }
    }
    if (-not (Test-Path -LiteralPath (Join-Path $batchDir 'paraformer_batch_manifest.json') -PathType Leaf)) { throw 'Batch manifest evidence is missing.' }

    $permissionDir = Join-Path $tempRoot 'permission'
    [IO.Directory]::CreateDirectory($permissionDir) | Out-Null
    $lockedSrt = Join-Path $tempRoot 'locked.srt'
    $lockStream = [IO.File]::Open($lockedSrt, [IO.FileMode]::Create, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    $permissionMessage = ''
    try {
        Invoke-ParaformerSrt $audio 1 $lockedSrt $false $permissionDir 10
    } catch {
        $permissionMessage = $_.Exception.Message
    } finally {
        $lockStream.Dispose()
    }
    if ([string]::IsNullOrWhiteSpace($permissionMessage)) { throw 'Locked subtitle output must fail explicitly.' }
    $permissionLog = Join-Path $permissionDir 'paraformer.log'
    if (-not (Test-Path -LiteralPath $permissionLog -PathType Leaf)) { throw 'Permission failure evidence log is missing.' }
    if ((Get-Content -LiteralPath $permissionLog -Raw -Encoding UTF8) -notmatch 'PermissionError') { throw 'Permission failure log must preserve the worker exception.' }

    $env:HUNJIAN_TEST_SLEEP = '3'
    $timeoutDir = Join-Path $tempRoot 'timeout'
    [IO.Directory]::CreateDirectory($timeoutDir) | Out-Null
    $timeoutSrt = Join-Path $tempRoot 'timeout subtitle.srt'
    $timeoutMessage = ''
    try {
        Invoke-ParaformerSrt $audio 1 $timeoutSrt $false $timeoutDir 1
    } catch {
        $timeoutMessage = $_.Exception.Message
    }
    $timeoutMarker = ([string][char]0x8D85) + ([string][char]0x65F6)
    if (-not $timeoutMessage.Contains($timeoutMarker)) { throw "Expected timeout error, got: $timeoutMessage" }
    if (-not (Test-Path -LiteralPath (Join-Path $timeoutDir 'paraformer.log') -PathType Leaf)) { throw 'Timeout evidence log is missing.' }

    $runnerTemplate = @'
param(
    [string]$ParaformerRootArg,
    [string]$ParaformerPythonArg,
    [string]$ParaformerWorkerArg,
    [string]$ParaformerSetupArg,
    [string]$LogDirArg,
    [string]$AudioPath,
    [string]$SrtPath,
    [string]$DiagnosticsDir
)
$ErrorActionPreference = 'Stop'
__FUNCTIONS__
$ParaformerRoot = $ParaformerRootArg
$ParaformerPython = $ParaformerPythonArg
$ParaformerWorker = $ParaformerWorkerArg
$ParaformerSetup = $ParaformerSetupArg
$ParaformerModelCache = Join-Path $ParaformerRoot 'model_cache'
$LogDir = $LogDirArg
function Write-Log([string]$Message) {}
$audio = Get-Item -LiteralPath $AudioPath
Invoke-ParaformerSrt $audio 1 $SrtPath $false $DiagnosticsDir 10
'@
    $runnerPath = Join-Path $tempRoot 'concurrent_runner.ps1'
    $runnerSource = $runnerTemplate.Replace('__FUNCTIONS__', ($functionTexts -join [Environment]::NewLine))
    [IO.File]::WriteAllText($runnerPath, $runnerSource, [Text.UTF8Encoding]::new($true))
    [IO.File]::WriteAllText($countPath, '0', [Text.UTF8Encoding]::new($false))
    $env:HUNJIAN_TEST_SLEEP = '1.5'
    $env:HUNJIAN_TEST_ACTIVE = Join-Path $tempRoot 'worker.active'
    $env:HUNJIAN_TEST_OVERLAP = Join-Path $tempRoot 'worker.overlap'
    $powershellExe = Join-Path $PSHOME 'powershell.exe'
    if (-not (Test-Path -LiteralPath $powershellExe -PathType Leaf)) {
        $powershellExe = (Get-Process -Id $PID).Path
    }
    $processes = @()
    foreach ($number in 1,2) {
        $diagnostics = Join-Path $tempRoot "concurrent_$number"
        [IO.Directory]::CreateDirectory($diagnostics) | Out-Null
        $concurrentSrt = Join-Path $tempRoot "concurrent_$number.srt"
        $processArgs = @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $runnerPath,
            '-ParaformerRootArg', $ParaformerRoot,
            '-ParaformerPythonArg', $ParaformerPython,
            '-ParaformerWorkerArg', $ParaformerWorker,
            '-ParaformerSetupArg', $ParaformerSetup,
            '-LogDirArg', $LogDir,
            '-AudioPath', $audioPath,
            '-SrtPath', $concurrentSrt,
            '-DiagnosticsDir', $diagnostics
        )
        $processArgString = ($processArgs | ForEach-Object { ConvertTo-WindowsCommandLineArgument $_ }) -join ' '
        $outPath = Join-Path $diagnostics 'runner.stdout'
        $errPath = Join-Path $diagnostics 'runner.stderr'
        $runnerProcess = Start-Process -FilePath $powershellExe -ArgumentList $processArgString -PassThru -WindowStyle Hidden -RedirectStandardOutput $outPath -RedirectStandardError $errPath
        $null = $runnerProcess.Handle
        $processes += $runnerProcess
        Start-Sleep -Milliseconds 100
    }
    foreach ($runnerProcess in $processes) {
        if (-not $runnerProcess.WaitForExit(15000)) {
            try { $runnerProcess.Kill() } catch {}
            throw 'Concurrent Paraformer wrapper test timed out.'
        }
        $runnerProcess.WaitForExit()
        $runnerProcess.Refresh()
        if ($runnerProcess.ExitCode -ne 0) { throw "Concurrent Paraformer wrapper failed with exit code $($runnerProcess.ExitCode)." }
    }
    if (Test-Path -LiteralPath $env:HUNJIAN_TEST_OVERLAP) { throw 'Concurrent Paraformer workers overlapped.' }
    if ((Get-Content -LiteralPath $countPath -Raw -Encoding UTF8) -ne '2') { throw 'Concurrent requests must each run once.' }
    foreach ($number in 1,2) {
        if (-not (Test-Path -LiteralPath (Join-Path $tempRoot "concurrent_$number.srt") -PathType Leaf)) { throw "Concurrent request $number did not create SRT." }
    }

    Write-Output 'PASS Test-Paraformer-SingleLoad'
} finally {
    Remove-Item Env:HUNJIAN_TEST_COUNT -ErrorAction SilentlyContinue
    Remove-Item Env:HUNJIAN_TEST_SLEEP -ErrorAction SilentlyContinue
    Remove-Item Env:HUNJIAN_TEST_ACTIVE -ErrorAction SilentlyContinue
    Remove-Item Env:HUNJIAN_TEST_OVERLAP -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
