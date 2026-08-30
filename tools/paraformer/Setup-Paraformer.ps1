param(
    [Parameter(Mandatory = $true)][string]$RuntimeDir,
    [Parameter(Mandatory = $true)][string]$ModelCacheDir,
    [Parameter(Mandatory = $true)][string]$WorkerPath,
    [Parameter(Mandatory = $true)][string]$LogPath,
    [string]$ProgressPath = '',
    [string]$PrecheckReason = ''
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$setupStartedAt = Get-Date
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $LogPath) | Out-Null
[IO.File]::WriteAllText($LogPath, '', [Text.UTF8Encoding]::new($true))

function Write-SetupLog([string]$Message) {
    $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Write-Host $line
    [IO.File]::AppendAllText($LogPath, $line + [Environment]::NewLine, [Text.UTF8Encoding]::new($true))
}

function Write-SetupProgress([string]$Stage, [string]$CurrentFile = '', [Int64]$DownloadedBytes = 0, [Int64]$TotalBytes = 0, [string]$Speed = '') {
    if (-not $ProgressPath) { return }
    $data = [ordered]@{ Stage = $Stage; CurrentFile = $CurrentFile; DownloadedBytes = $DownloadedBytes; TotalBytes = $TotalBytes; Speed = $Speed; UpdatedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') }
    $tempPath = "$ProgressPath.tmp"
    [IO.File]::WriteAllText($tempPath, ($data | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($true))
    Move-Item -LiteralPath $tempPath -Destination $ProgressPath -Force
}

function ConvertTo-DownloadBytes([double]$Value, [string]$Unit) {
    switch ($Unit.ToUpperInvariant()) { 'KB' { return [Int64]($Value * 1KB) } 'MB' { return [Int64]($Value * 1MB) } 'GB' { return [Int64]($Value * 1GB) } default { return [Int64]$Value } }
}

function Update-SetupProgressFromText([string]$Text, [string]$Stage) {
    $matches = [regex]::Matches($Text, '(?<done>\d+(?:\.\d+)?)\s*(?<doneUnit>KB|MB|GB)\s*(?:/|of)\s*(?<total>\d+(?:\.\d+)?)\s*(?<totalUnit>KB|MB|GB)', 'IgnoreCase')
    if ($matches.Count -eq 0) { return }
    $match = $matches[$matches.Count - 1]
    $speedMatch = [regex]::Matches($Text, '(?<speed>\d+(?:\.\d+)?\s*(?:KB|MB|GB)/s)', 'IgnoreCase')
    $speed = if ($speedMatch.Count -gt 0) { $speedMatch[$speedMatch.Count - 1].Groups['speed'].Value } else { '' }
    Write-SetupProgress $Stage '' (ConvertTo-DownloadBytes ([double]$match.Groups['done'].Value) $match.Groups['doneUnit'].Value) (ConvertTo-DownloadBytes ([double]$match.Groups['total'].Value) $match.Groups['totalUnit'].Value) $speed
}

function Read-SharedText([string]$Path) {
    try {
        $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        try {
            $reader = New-Object IO.StreamReader($stream, [Text.UTF8Encoding]::new($false), $true)
            try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
        } finally { $stream.Dispose() }
    } catch [IO.IOException] {
        return ''
    }
}

function Invoke-LoggedProcess([string]$FilePath, [string[]]$Arguments, [string]$Name) {
    $token = [guid]::NewGuid().ToString('N')
    $stdout = Join-Path ([IO.Path]::GetTempPath()) "paraformer_$token.out.log"
    $stderr = Join-Path ([IO.Path]::GetTempPath()) "paraformer_$token.err.log"
    try {
        Write-SetupProgress $Name
        $process = Start-Process -FilePath $FilePath -ArgumentList $Arguments -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
        while (-not $process.HasExited) {
            $liveText = @($(foreach ($path in @($stdout, $stderr)) { if (Test-Path -LiteralPath $path) { Read-SharedText $path } })) -join "`n"
            Update-SetupProgressFromText $liveText $Name
            Start-Sleep -Milliseconds 500
        }
        foreach ($path in @($stdout, $stderr)) {
            if (Test-Path -LiteralPath $path) {
                $content = Read-SharedText $path
                if (-not [string]::IsNullOrWhiteSpace($content)) { [IO.File]::AppendAllText($LogPath, $content, [Text.UTF8Encoding]::new($true)) }
            }
        }
        if ($process.ExitCode -ne 0) { throw "$Name 失败，退出码：$($process.ExitCode)" }
    } finally {
        Remove-Item -LiteralPath $stdout, $stderr -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-Pip([string[]]$Arguments) {
    Write-SetupLog "执行：python -m pip $($Arguments -join ' ')"
    Invoke-LoggedProcess $python (@('-m', 'pip', '--progress-bar', 'raw') + $Arguments) '下载并安装依赖'
}

function Get-ParaformerTorchPackage {
    $name = ''
    $capability = ''
    $nvidiaSmi = Get-Command nvidia-smi.exe -ErrorAction SilentlyContinue
    if ($nvidiaSmi) {
        try {
            $gpuInfo = & $nvidiaSmi.Path '--query-gpu=name,compute_cap' '--format=csv,noheader' 2>$null | Select-Object -First 1
            if ($gpuInfo) {
                $parts = $gpuInfo -split ',', 2
                $name = $parts[0].Trim()
                if ($parts.Count -gt 1) { $capability = $parts[1].Trim() }
            }
        } catch {}
    }
    if ($name -match 'RTX\s*50\d{2}' -or $capability -match '^(10|12)\.') {
        return [pscustomobject]@{ Torch = 'torch==2.7.1+cu128'; Torchaudio = 'torchaudio==2.7.1+cu128'; IndexUrl = 'https://download.pytorch.org/whl/cu128'; Label = "CUDA 12.8（$name）" }
    }
    return [pscustomobject]@{ Torch = 'torch==2.6.0+cu124'; Torchaudio = 'torchaudio==2.6.0+cu124'; IndexUrl = 'https://download.pytorch.org/whl/cu124'; Label = 'CUDA 12.4' }
}

trap {
    Write-SetupLog ("FAILED: " + $_.Exception.Message)
    exit 1
}

New-Item -ItemType Directory -Force -Path $RuntimeDir, $ModelCacheDir | Out-Null
Write-SetupProgress '准备本地 Paraformer 安装环境'
if ($PrecheckReason) { Write-SetupLog "PRECHECK_NOT_READY: $PrecheckReason" }
Write-SetupLog '阶段：准备本地 Paraformer 安装环境。'
$python = Join-Path $RuntimeDir 'python.exe'
if (-not (Test-Path -LiteralPath $python)) {
    $downloadDir = Join-Path (Split-Path -Parent $RuntimeDir) 'downloads'
    $runtimeZip = Join-Path $downloadDir 'python-3.10.11-embed-amd64.zip'
    $getPip = Join-Path $downloadDir 'get-pip.py'
    $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
    New-Item -ItemType Directory -Force -Path $downloadDir | Out-Null
    Write-SetupLog "下载工具：$curl"
    if (-not (Test-Path -LiteralPath $curl)) { throw '未找到 Windows curl.exe，无法下载 Python 运行环境。' }
    if (-not (Test-Path -LiteralPath $runtimeZip)) {
        Write-SetupLog '阶段：下载 Python 3.10 便携运行环境。'
        Invoke-LoggedProcess $curl @('--fail', '--location', '--retry', '3', '--connect-timeout', '30', '--silent', '--show-error', '--output', $runtimeZip, 'https://www.python.org/ftp/python/3.10.11/python-3.10.11-embed-amd64.zip') 'Python 运行环境下载'
        if (-not (Test-Path -LiteralPath $runtimeZip)) { throw 'Python 运行环境下载后未找到文件。' }
    }
    Write-SetupLog '阶段：解压 Python 便携运行环境。'
    Expand-Archive -LiteralPath $runtimeZip -DestinationPath $RuntimeDir -Force
    $pthFile = Join-Path $RuntimeDir 'python310._pth'
    if (-not (Test-Path -LiteralPath $python)) { throw 'Python 便携版解压后未生成 python.exe。' }
    if (-not (Test-Path -LiteralPath $pthFile)) { throw 'Python 便携版缺少 python310._pth。' }
    [IO.File]::WriteAllLines($pthFile, @('python310.zip', '.', 'Lib\site-packages', 'import site'), [Text.Encoding]::ASCII)
    if (-not (Test-Path -LiteralPath $getPip)) {
        Invoke-LoggedProcess $curl @('--fail', '--location', '--retry', '3', '--connect-timeout', '30', '--silent', '--show-error', '--output', $getPip, 'https://bootstrap.pypa.io/get-pip.py') 'pip 安装器下载'
        if (-not (Test-Path -LiteralPath $getPip)) { throw 'pip 安装器下载后未找到文件。' }
    }
    Write-SetupLog '阶段：初始化本地 pip。'
    Invoke-LoggedProcess $python @($getPip) 'pip 初始化'
}

$pthFile = Join-Path $RuntimeDir 'python310._pth'
if (-not (Test-Path -LiteralPath $python)) { throw 'Python 便携版解压后未生成 python.exe。' }
if (-not (Test-Path -LiteralPath $pthFile)) { throw 'Python 便携版缺少 python310._pth。' }
[IO.File]::WriteAllLines($pthFile, @('python310.zip', '.', 'Lib\site-packages', 'import site'), [Text.Encoding]::ASCII)

Write-SetupLog '阶段：升级 pip。'
Invoke-Pip @('install', '--upgrade', 'pip')
$torchPackage = Get-ParaformerTorchPackage
Write-SetupLog "阶段：下载并安装 PyTorch $($torchPackage.Label)（首次或显卡兼容升级时可能较久）。"
Invoke-Pip @('install', '--upgrade', '--force-reinstall', $torchPackage.Torch, $torchPackage.Torchaudio, '--index-url', $torchPackage.IndexUrl)
Write-SetupLog '阶段：安装 FunASR、ModelScope 与 soundfile。'
Invoke-Pip @('install', '--upgrade', 'funasr==1.4.1', 'modelscope==1.39.1', 'soundfile==0.14.0')

$env:MODELSCOPE_CACHE = $ModelCacheDir
Write-SetupLog '阶段：下载 Paraformer-large、VAD 与标点模型；此步骤只在首次执行时发生。'
Invoke-LoggedProcess $python @($WorkerPath, '--warmup') 'Paraformer 模型初始化'
Write-SetupLog ("本地 Paraformer-large 已准备完成。总耗时：{0}" -f ((Get-Date) - $setupStartedAt).ToString('hh\:mm\:ss'))
