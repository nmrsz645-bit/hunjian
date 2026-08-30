$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Test-Helpers.ps1"

$root = Split-Path -Parent $PSScriptRoot
$autoCutPath = Join-Path $root 'AutoCut.ps1'
$autoCut = [IO.File]::ReadAllText($autoCutPath, [Text.Encoding]::UTF8)
$functionText = [regex]::Match($autoCut, '(?s)function\s+Get-MediaInfo\s*\([^)]*\)\s*\{.*?\n\}').Value
Assert-True (-not [string]::IsNullOrWhiteSpace($functionText)) '必须能提取Get-MediaInfo函数'
Assert-True ($functionText -match '-show_entries') 'FFprobe JSON必须只输出程序需要的字段，避免中文文件名进入JSON'

$Ffprobe = Join-Path $root 'tools\ffmpeg\bin\ffprobe.exe'
$Ffmpeg = Join-Path $root 'tools\ffmpeg\bin\ffmpeg.exe'
$MediaInfoCache = @{}
$tempRoot = Join-Path (Join-Path $root '音频位置') ("中文媒体测试_{0}" -f ([guid]::NewGuid().ToString('N')))
$video = Join-Path $tempRoot '中文视频.mp4'
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
try {
    & $Ffmpeg -hide_banner -loglevel error -y -f lavfi -i 'color=c=black:s=320x240:d=1' -an $video
    Assert-Equal 0 $LASTEXITCODE '测试视频必须生成成功'
    Invoke-Expression $functionText
    $info = Get-MediaInfo $video
    Assert-True ([double]$info.format.duration -gt 0.5) '中文路径媒体必须读取到时长'
    $stream = $info.streams | Where-Object codec_type -eq 'video' | Select-Object -First 1
    Assert-Equal 320 ([int]$stream.width) '中文路径媒体必须读取到宽度'
    Assert-Equal 240 ([int]$stream.height) '中文路径媒体必须读取到高度'
} finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host 'PASS Test-MediaInfoUnicode' -ForegroundColor Green
