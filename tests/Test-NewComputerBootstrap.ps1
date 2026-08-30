$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Test-Helpers.ps1"

$root = Split-Path -Parent $PSScriptRoot
$bootstrapPath = Join-Path $root 'Initialize-NewComputer.ps1'
Assert-True (Test-Path -LiteralPath $bootstrapPath -PathType Leaf) '新电脑必须提供一键依赖配置脚本'
$bootstrap = [IO.File]::ReadAllText($bootstrapPath, [Text.Encoding]::UTF8)
$paraformerSetup = [IO.File]::ReadAllText((Join-Path $root 'tools\paraformer\Setup-Paraformer.ps1'), [Text.Encoding]::UTF8)

foreach ($expected in @(
    'config.example.ps1',
    'ffmpeg-9.0.1-essentials_build.zip',
    'whisper-bin-x64.zip',
    'OpenCC-1.4.2-windows-x64-portable.zip',
    'ggml-tiny.bin',
    'Setup-Paraformer.ps1',
    'Get-FileHash',
    'SHA-256 校验失败'
)) {
    Assert-True ($bootstrap.Contains($expected)) "新电脑配置脚本缺少受控依赖步骤：$expected"
}
Assert-True ($bootstrap.Contains('保持不覆盖')) '新电脑配置脚本必须保护已存在的用户依赖'
Assert-True ($bootstrap.Contains('目标目录已存在但不完整')) '新电脑配置脚本遇到不完整依赖时必须停止而非覆盖'
Assert-True ($bootstrap.Contains('.new-computer-bootstrap.pending')) 'Paraformer中断后必须只允许引导脚本自身的下载续传'
Assert-True ($bootstrap.Contains('not (Test-Path -LiteralPath $resumeMarker)')) '未知Paraformer不完整目录必须继续受保护'
Assert-True ($bootstrap.Contains('[switch]$SkipParaformer')) '新电脑配置脚本必须允许独立验证非模型依赖'
Assert-True (-not $bootstrap.Contains('chajia\ffmpeg.zip')) '新电脑配置不能依赖旧电脑的 chajia 本地安装包'
Assert-True ($paraformerSetup.Contains('& $FilePath @Arguments 1> $stdout 2> $stderr')) 'Paraformer安装器必须直接执行下载命令，避免Start-Process丢失退出码'
Assert-True ($paraformerSetup.Contains('$exitCode = $LASTEXITCODE')) 'Paraformer安装器必须读取实际命令退出码'

Write-Host 'PASS Test-NewComputerBootstrap' -ForegroundColor Green
