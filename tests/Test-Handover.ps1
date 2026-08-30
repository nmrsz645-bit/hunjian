$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Test-Helpers.ps1"

$root = Split-Path -Parent $PSScriptRoot
$exampleConfig = Join-Path $root 'config.example.ps1'
$readme = Join-Path $root 'README.md'
$handoff = Join-Path $root 'HANDOFF.md'
$ignore = Join-Path $root '.gitignore'

Assert-True (Test-Path -LiteralPath $exampleConfig -PathType Leaf) '交接必须包含示例配置'
Assert-True (Test-Path -LiteralPath $handoff -PathType Leaf) '交接必须包含总交接文档'
$bytes = [IO.File]::ReadAllBytes($exampleConfig)
Assert-True ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) '示例配置必须为Windows PowerShell 5.1可读的UTF-8 BOM'
. $exampleConfig
Assert-Equal (Join-Path $root '视频位置') $VideoDir '示例配置在Windows PowerShell中必须保留中文目录名'
Assert-Equal (Join-Path $root 'tools\models\ggml-tiny.bin') $WhisperModel '示例配置必须指向便携Whisper模型文件'

$integrationText = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Test-Integration.ps1'), [Text.Encoding]::UTF8)
Assert-True ($integrationText -match "config\.example\.ps1") '集成测试在没有个人配置时必须回退到示例配置'

$readmeText = [IO.File]::ReadAllText($readme, [Text.Encoding]::UTF8)
foreach ($path in @('tools\paraformer\runtime', 'tools\paraformer\model_cache', 'tools\ffmpeg', 'tools\opencc')) {
    Assert-True ($readmeText.Contains($path)) "README必须说明恢复运行依赖：$path"
}

$handoffText = [IO.File]::ReadAllText($handoff, [Text.Encoding]::UTF8)
foreach ($expected in @('## 第一条操作', '## 新电脑接手与运行', '## 已完成验证', '## 已知边界', '## 严禁误动的数据')) {
    Assert-True ($handoffText.Contains($expected)) "总交接文档必须包含：$expected"
}
Assert-True ($handoffText.Contains("Set-Location '<你的克隆目录>'")) '第一条操作必须可在新电脑的克隆目录执行'
Assert-True (-not $handoffText.Contains("Set-Location 'E:\自动化\混剪\自动剪辑桌面版_V16'")) '第一条操作不能写死原开发电脑路径'
Assert-True (-not $handoffText.Contains('d36da04a98d385172edfda74411aa013d11d7c44')) '总交接文档不能依赖已过期的固定提交号'

$ignoreText = [IO.File]::ReadAllText($ignore, [Text.Encoding]::UTF8)
foreach ($path in @('config.ps1', 'logs/', 'work/', 'tools/paraformer/runtime/', 'tools/paraformer/model_cache/', 'fonts/UserAdded/')) {
    Assert-True ($ignoreText.Contains($path)) "Git忽略规则必须保护：$path"
}

Write-Output 'PASS Test-Handover'
