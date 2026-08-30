param(
    [switch]$SkipParaformer
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$Root = $PSScriptRoot
$TempRoot = Join-Path ([IO.Path]::GetTempPath()) ('hunjian_bootstrap_' + [guid]::NewGuid().ToString('N'))

function Write-Step([string]$Text) {
    Write-Host ("[配置] " + $Text) -ForegroundColor Cyan
}

function Test-ExpectedFile([string]$Path) {
    return (Test-Path -LiteralPath $Path -PathType Leaf) -and ((Get-Item -LiteralPath $Path).Length -gt 0)
}

function Ensure-Directory([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Invoke-VerifiedDownload([string]$Name, [string]$Uri, [string]$Sha256, [string]$Destination) {
    $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
    if (-not (Test-ExpectedFile $curl)) { throw '未找到 Windows curl.exe，无法下载运行依赖。请先修复 Windows curl 后重试。' }
    Write-Step "下载 $Name"
    & $curl '--fail' '--location' '--retry' '3' '--connect-timeout' '30' '--silent' '--show-error' '--output' $Destination $Uri
    if ($LASTEXITCODE -ne 0) { throw "$Name 下载失败，退出码：$LASTEXITCODE" }
    $actual = (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash.ToUpperInvariant()
    if ($actual -ne $Sha256.ToUpperInvariant()) { throw "$Name SHA-256 校验失败。期望：$Sha256；实际：$actual" }
}

function Install-ArchiveComponent(
    [string]$Name,
    [string]$Uri,
    [string]$Sha256,
    [string]$Destination,
    [string]$ExpectedRelativePath,
    [int]$RootParentDepth
) {
    $expectedDestination = Join-Path $Destination $ExpectedRelativePath
    if (Test-ExpectedFile $expectedDestination) {
        Write-Step "$Name 已存在，保持不覆盖：$expectedDestination"
        return
    }
    if (Test-Path -LiteralPath $Destination) {
        throw "$Name 目标目录已存在但不完整，为保护已有文件，不自动覆盖：$Destination"
    }

    $archive = Join-Path $TempRoot ($Name + '.zip')
    $expanded = Join-Path $TempRoot ($Name + '_expanded')
    Invoke-VerifiedDownload $Name $Uri $Sha256 $archive
    Expand-Archive -LiteralPath $archive -DestinationPath $expanded -Force

    $expectedName = ($ExpectedRelativePath -split '[\\/]')[-1]
    $matches = @(Get-ChildItem -LiteralPath $expanded -File -Recurse | Where-Object { $_.Name -ieq $expectedName })
    if ($matches.Count -ne 1) { throw "$Name 安装包结构异常，未找到唯一文件：$ExpectedRelativePath" }
    $sourceRoot = $matches[0].Directory.FullName
    for ($index = 1; $index -lt $RootParentDepth; $index += 1) {
        $sourceRoot = Split-Path -Parent $sourceRoot
    }
    if (-not (Test-ExpectedFile (Join-Path $sourceRoot $ExpectedRelativePath))) {
        throw "$Name 安装包结构异常，组件根目录无法确认。"
    }

    Ensure-Directory $Destination
    Copy-Item -Path (Join-Path $sourceRoot '*') -Destination $Destination -Recurse -Force
    if (-not (Test-ExpectedFile $expectedDestination)) { throw "$Name 解压后仍缺少：$expectedDestination" }
    Write-Step "$Name 已安装：$Destination"
}

function Initialize-Paraformer {
    $paraformerRoot = Join-Path $Root 'tools\paraformer'
    $runtimeDir = Join-Path $paraformerRoot 'runtime'
    $modelCacheDir = Join-Path $paraformerRoot 'model_cache'
    $readyFiles = @(
        (Join-Path $runtimeDir 'python.exe'),
        (Join-Path $modelCacheDir 'models\iic--speech_seaco_paraformer_large_asr_nat-zh-cn-16k-common-vocab8404-pytorch\snapshots\master\model.pt'),
        (Join-Path $modelCacheDir 'models\iic--speech_fsmn_vad_zh-cn-16k-common-pytorch\snapshots\master\model.pt'),
        (Join-Path $modelCacheDir 'models\iic--punc_ct-transformer_cn-en-common-vocab471067-large\snapshots\master\model.pt')
    )
    if (@($readyFiles | Where-Object { -not (Test-ExpectedFile $_) }).Count -eq 0) {
        Write-Step 'Paraformer 运行环境和模型已存在，保持不覆盖。'
        return
    }
    foreach ($path in @($runtimeDir, $modelCacheDir)) {
        if ((Test-Path -LiteralPath $path) -and @(Get-ChildItem -LiteralPath $path -Force -ErrorAction SilentlyContinue).Count -gt 0) {
            throw "Paraformer 目录不完整，为保护已有下载内容，不自动覆盖：$path"
        }
    }

    $worker = Join-Path $paraformerRoot 'paraformer_worker.py'
    $setup = Join-Path $paraformerRoot 'Setup-Paraformer.ps1'
    if (-not ((Test-ExpectedFile $worker) -and (Test-ExpectedFile $setup))) { throw 'Paraformer 安装脚本或识别器缺失，源码不完整。' }
    $logPath = Join-Path $Root 'logs\paraformer_setup.log'
    Ensure-Directory (Split-Path -Parent $logPath)
    Write-Step '下载并配置 Paraformer 运行环境和三套模型（首次耗时较长）。'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $setup -RuntimeDir $runtimeDir -ModelCacheDir $modelCacheDir -WorkerPath $worker -LogPath $logPath
    if ($LASTEXITCODE -ne 0) { throw "Paraformer 配置失败，详见：$logPath" }
    if (@($readyFiles | Where-Object { -not (Test-ExpectedFile $_) }).Count -gt 0) { throw "Paraformer 配置后仍不完整，详见：$logPath" }
}

try {
    Ensure-Directory $TempRoot
    Write-Step "项目目录：$Root"
    $config = Join-Path $Root 'config.ps1'
    if (-not (Test-Path -LiteralPath $config)) {
        Copy-Item -LiteralPath (Join-Path $Root 'config.example.ps1') -Destination $config
        Write-Step '已从 config.example.ps1 创建本机 config.ps1。'
    } else {
        Write-Step 'config.ps1 已存在，保持不覆盖。'
    }
    foreach ($directory in @('视频位置', '音频位置', '完成', 'work', 'logs', 'backups', 'config')) {
        Ensure-Directory (Join-Path $Root $directory)
    }

    Install-ArchiveComponent 'ffmpeg' 'https://www.gyan.dev/ffmpeg/builds/packages/ffmpeg-9.0.1-essentials_build.zip' 'FEC81AE03971D9DD4BE3EBE02E263BD2EC1D789483F931BDBA5F5715E65DA2E9' (Join-Path $Root 'tools\ffmpeg') 'bin\ffmpeg.exe' 2
    Install-ArchiveComponent 'whisper' 'https://github.com/ggml-org/whisper.cpp/releases/download/b4938/whisper-bin-x64.zip' 'C2A4B60EDB11F7E11A9191FFB50929535527D4D91C9903DBE3E554583BBBC63D' (Join-Path $Root 'tools\whisper') 'whisper-cli.exe' 1
    Install-ArchiveComponent 'opencc' 'https://github.com/BYVoid/OpenCC/releases/download/ver.1.4.2/OpenCC-1.4.2-windows-x64-portable.zip' 'DAB0142FF6401219A5E556CEE215323753EEAC38752DDE4CFDDF8035746605F1' (Join-Path $Root 'tools\opencc') 'bin\opencc.exe' 2

    $tinyModel = Join-Path $Root 'tools\models\ggml-tiny.bin'
    if (-not (Test-ExpectedFile $tinyModel)) {
        if (Test-Path -LiteralPath $tinyModel) { throw "Whisper tiny 模型文件为空，为保护已有文件，不自动覆盖：$tinyModel" }
        Ensure-Directory (Split-Path -Parent $tinyModel)
        Invoke-VerifiedDownload 'Whisper tiny 模型' 'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.bin' 'BE07E048E1E599AD46341C8D2A135645097A538221678B7ACDD1B1919C6E1B21' $tinyModel
    } else {
        Write-Step 'Whisper tiny 模型已存在，保持不覆盖。'
    }

    if (-not $SkipParaformer) { Initialize-Paraformer }
    Write-Host ''
    Write-Host '新电脑运行依赖已配置完成。放入视频和音频后，请执行：' -ForegroundColor Green
    Write-Host 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Start-AutoCut.ps1 -CheckOnly'
    Write-Host 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Start-AutoCut.ps1 -Test'
} finally {
    if (Test-Path -LiteralPath $TempRoot) { Remove-Item -LiteralPath $TempRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
