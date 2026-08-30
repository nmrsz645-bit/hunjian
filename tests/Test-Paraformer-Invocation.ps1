$ErrorActionPreference = 'Stop'

function Assert-True($Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function ConvertTo-WindowsCommandLineArgument([string]$Argument) {
    if ($Argument.Length -eq 0) { return '""' }
    if ($Argument -notmatch '[\s"]') { return $Argument }
    $escaped = [regex]::Replace($Argument, '(\\*)"', '$1$1\"')
    $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
    return '"' + $escaped + '"'
}

$root = Split-Path -Parent $PSScriptRoot
$python = Join-Path $root 'tools\paraformer\runtime\python.exe'
if (-not (Test-Path -LiteralPath $python -PathType Leaf)) {
    $python = (Get-Command python.exe -ErrorAction Stop).Source
    Write-Output "INFO Test fallback Python: $python"
}
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('paraformer-invocation-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($tempRoot) | Out-Null
$worker = Join-Path $tempRoot 'worker.py'
$audio = Join-Path $tempRoot (([string][char]0x4E2D) + ([string][char]0x6587) + ' ' + ([string][char]0x97F3) + ([string][char]0x9891) + '.mp3')
$srt = Join-Path $tempRoot (([string][char]0x5B57) + ([string][char]0x5E55) + ' ' + ([string][char]0x6587) + ([string][char]0x4EF6) + '.srt')
$json = Join-Path $tempRoot (([string][char]0x53C2) + ([string][char]0x6570) + ' ' + ([string][char]0x6587) + ([string][char]0x4EF6) + '.json')
$stdout = Join-Path $tempRoot 'worker.stdout'
$stderr = Join-Path $tempRoot 'worker.stderr'
$argvJson = Join-Path $tempRoot 'argv.json'
$workerSource = @'
import json, sys
print('[INFO] ordinary worker log', file=sys.stderr)
with open(sys.argv[6], 'w', encoding='utf-8') as f:
    json.dump(sys.argv, f, ensure_ascii=False)
'@
[IO.File]::WriteAllText($worker, $workerSource, [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllBytes($audio, [byte[]]@())

try {
    # This deliberately reproduces the former invocation: stderr + EAP=Stop raises NativeCommandError despite exit 0.
    $previousEap = $ErrorActionPreference
    $ErrorActionPreference = 'Stop'
    $sawNativeCommandError = $false
    try {
        & $python $worker '--audio' $audio '--srt' $srt '--json' $argvJson 1> $stdout 2> $stderr
    } catch {
        $sawNativeCommandError = $_.FullyQualifiedErrorId -match 'NativeCommandError'
    } finally {
        $ErrorActionPreference = $previousEap
    }
    Assert-True $sawNativeCommandError 'Expected direct native invocation to raise NativeCommandError for normal stderr output.'
    Assert-True (Test-Path -LiteralPath $argvJson -PathType Leaf) 'Expected direct worker to complete and write argv JSON before NativeCommandError.'

    $argumentString = (@($worker, '--audio', $audio, '--srt', $srt, '--json', $argvJson) | ForEach-Object { ConvertTo-WindowsCommandLineArgument $_ }) -join ' '
    $process = Start-Process -FilePath $python -ArgumentList $argumentString -Wait -PassThru -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    Assert-True ($process.ExitCode -eq 0) "Expected redirected worker exit 0, got $($process.ExitCode)"
    Assert-True (([IO.File]::ReadAllText($stderr, [Text.UTF8Encoding]::new($false))) -match '\[INFO\] ordinary worker log') 'Expected INFO stderr in redirected stderr file.'
    $argv = Get-Content -LiteralPath $argvJson -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True ($argv[2] -eq $audio) 'Audio path was not preserved as one argv item.'
    Assert-True ($argv[4] -eq $srt) 'SRT path was not preserved as one argv item.'
    Assert-True ($argv[6] -eq $argvJson) 'JSON path was not preserved as one argv item.'
    Write-Output 'PASS Test-Paraformer-Invocation'
} finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
