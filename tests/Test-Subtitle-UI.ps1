$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Test-Helpers.ps1"

$root = Split-Path -Parent $PSScriptRoot
$uiPath = Join-Path $root 'Subtitle-Settings.ps1'
$managerPath = Join-Path $root 'AutoCut-Manager.ps1'
$configPath = Join-Path $root 'config.ps1'
$ui = [IO.File]::ReadAllText($uiPath, [Text.Encoding]::UTF8)
$manager = [IO.File]::ReadAllText($managerPath, [Text.Encoding]::UTF8)
$config = [IO.File]::ReadAllText($configPath, [Text.Encoding]::UTF8)

foreach ($pattern in @(
    'TabControl',
    '字幕样式',
    '字体管理',
    '阿里云接口',
    'InstalledFontCollection',
    'PrivateFontCollection',
    'FontGlyphProbe',
    '支持中文',
    '仿手写字体',
    '保存并应用到后续视频',
    '\.ttf',
    '\.otf',
    '\.ttc',
    '横屏',
    '竖屏',
    'ColorDialog',
    'SubtitleOutline',
    'SubtitleMaxCharsPerLine',
    'SubtitleMarginVPortrait',
    'SubtitleMarginVLandscape',
    'MouseDown',
    'MouseMove',
    'MouseUp',
    'ffmpeg',
    'subtitles=preview\.srt',
    'fontsdir=fonts',
    'SafeWidthPercent',
    'VideoDir'
)) {
    Assert-True ($ui -match $pattern) "字幕设置器缺少功能标记：$pattern"
}

foreach ($pattern in @(
    'Start-PreviewRender',
    'Diagnostics\.ProcessStartInfo',
    'previewPollTimer',
    '预览更新中',
    '显示密钥',
    '替换密钥',
    '删除密钥',
    'AliyunModel',
    'AliyunEndpoint'
)) {
    Assert-True ($ui -match $pattern) "字幕设置器缺少非阻塞或接口管理功能：$pattern"
}

$previewTick = [regex]::Match($ui, '(?s)\$previewTimer\.Add_Tick\(\{.*?\n\}\)').Value
Assert-True ($previewTick -notmatch 'Invoke-PreviewFfmpeg') '延迟计时器不得在界面线程同步执行FFmpeg'
Assert-True ($ui -match 'Get-ChildItem.+-Recurse') '便携字体必须递归扫描子目录'
Assert-True ($ui -match '最多两行字幕') '预览状态必须说明当前字幕事件最多显示两行'

$handwritingDir = Join-Path $root 'fonts\Handwriting'
foreach ($font in @(
    'MaShanZheng-Regular.ttf',
    'LiuJianMaoCao-Regular.ttf',
    'LongCang-Regular.ttf',
    'ZCOOLKuaiLe-Regular.ttf'
)) {
    Assert-True (Test-Path -LiteralPath (Join-Path $handwritingDir $font) -PathType Leaf) "发布版缺少中文手写字体：$font"
}

Assert-True ($ui -match '\$hasChinese\s*=\s*\(Test-FontSupportsChinese\s+\$family\)') '字体列表必须实际检测中文字形'
Assert-True ($ui -match "Category\s*=\s*'仿手写字体'") '手写字体必须进入独立分类'

$probeSource = [regex]::Match($ui, "(?s)Add-Type\s+-ReferencedAssemblies\s+System\.Drawing\s+-TypeDefinition\s+@'\r?\n(.*?)\r?\n'@").Groups[1].Value
Assert-True (-not [string]::IsNullOrWhiteSpace($probeSource)) '必须显式引用System.Drawing编译中文字形检测器'
Add-Type -TypeDefinition $probeSource -ReferencedAssemblies System.Drawing
Assert-True ($null -ne ('FontGlyphProbe' -as [type])) 'FontGlyphProbe必须能够在Windows PowerShell中编译'

Assert-True ($manager -match '字幕设置与预览') '管理界面必须提供字幕设置与预览按钮'
Assert-True ($manager -match 'Subtitle-Settings\.ps1') '管理界面按钮必须启动字幕设置器'

Assert-True ($config -match '\$SubtitleSourceMode\s*=\s*''paraformer_local''') '默认字幕来源必须是本地 Paraformer'
Assert-True ($config -match '\$SubtitleSafeWidthPercent\s*=\s*94') '安全宽度必须固定为94'
foreach ($mode in @('paraformer_local', 'aliyun_only', 'aliyun_fallback', 'text_preferred')) {
    Assert-True ($ui -match [regex]::Escape($mode)) "字幕设置器缺少来源模式：$mode"
}
foreach ($label in @('本地 Paraformer-large（首次自动下载）', '仅阿里云', '阿里云优先本地备用', '同名文本稿优先')) {
    Assert-True ($ui -match [regex]::Escape($label)) "字幕设置器缺少来源选项：$label"
}
Assert-True ($ui -match '当前字幕来源') '字幕设置器必须明确显示当前字幕来源'
Assert-True ($ui -match 'SubtitleSourceMode\s*=\s*if') '字幕设置器必须读取当前字幕来源'
Assert-True ($ui -match 'cmbSourceMode\.SelectedItem\.Value') '保存时必须写入所选字幕来源模式'
Assert-True ($ui -match 'subtitle_cache') '字幕设置器必须定位识别缓存目录'
Assert-True ($ui -match '打开识别缓存') '字幕设置器必须提供打开识别缓存按钮'
Assert-True ($ui -match 'WorkDir\s*=\s*if') '字幕设置器必须读取配置中的WorkDir'
Assert-True ($ui -match '\$SubtitleCacheDir\s*=\s*Join-Path \$cfg\.WorkDir') '缓存目录必须基于配置中的WorkDir'
Assert-True ($ui -notmatch '\$SubtitleCacheDir\s*=\s*Join-Path \$Root\s+''work\\subtitle_cache''') '缓存目录不得固定为Root下的work目录'
Assert-True ($ui -match 'Assert-AliyunEndpoint[^\r\n]*\$txtAliyunEndpoint') '保存阿里云设置前必须校验实际端点'
Assert-True ($ui -match 'Test-AliyunConnection[^\r\n]*-Endpoint') '连接测试必须测试界面中的实际任务端点'
Assert-True ($ui -match '可粘贴[^\r\n]+https://host/api/v1[^\r\n]+基础地址') '字幕设置器必须提示可粘贴workspace的/api/v1基础地址'
Assert-True ($ui -match 'SubtitleSafeWidthPercent\s*=\s*94') '字幕设置器安全宽度必须固定为94'
Assert-True ($ui -match '\$numSafeWidth\.Value = 94') '字幕设置器恢复默认值必须使用94'
Assert-True ($ui -match '\$numSafeWidth\.Enabled = \$false') '字幕设置器不得允许修改安全宽度'
Assert-True ($ui -match '检测/下载本地 Paraformer') '字幕设置器必须先提供本地 Paraformer 检测'
Assert-True ($ui -match '本地模型已就绪，无需下载') '本地检测成功必须明确提示无需下载'
Assert-True ($ui -match '下载缺失组件') '本地检测失败必须列出缺失项后再提供下载'
Assert-True ($ui -match '运行环境：tools\\paraformer\\runtime\\python\.exe') '本地检测必须明确列出缺失运行环境'
Assert-True ($ui -match '模型：\$modelName') '本地检测必须明确列出缺失模型'
Assert-True ($ui -match 'PARAFORMER_LOCAL_READY_NO_DOWNLOAD') '本地检测成功不得启动安装器'
Assert-True ($ui -match 'Setup-Paraformer\.ps1') '下载按钮必须调用本地 Paraformer 安装器'
Assert-True ($ui -match 'paraformer_setup\.log') '下载按钮必须保留可查看的安装日志'
Assert-True ($ui -match 'paraformer_setup_progress\.json') '下载按钮必须保存实时下载进度'
Assert-True ($ui -match '已下载：') '下载界面必须显示已下载大小'
Assert-True ($ui -match '剩余') '下载界面必须显示剩余下载大小'
Assert-True ($ui -match '本地模型已就绪，无需下载') '本地完整模型必须明确显示无需下载'
Assert-True ($ui -match '升级显卡运行环境') '显卡不兼容时必须提供显卡运行环境升级入口'
Assert-True ($ui -match 'PRECHECK_NOT_READY') '残留本地 Python 预检失败必须写日志并继续安装'
Assert-True ($ui -match 'Test-ParaformerWorkerReady') '字幕设置器必须进行真实 Paraformer 就绪检查'
Assert-True ($ui -match 'RedirectStandardOutput.+RedirectStandardError') '字幕设置器就绪检查必须隔离普通 Python STDERR'
Assert-True ($ui -match 'ExitCode -eq 0') '字幕设置器就绪检查必须只按退出码判断成功'
Assert-True ($ui -match "ToString\('hh\\:mm\\:ss'\)") '下载进度计时必须使用有效的 TimeSpan 格式'
Assert-True ($ui -notmatch "ToString\('hh\\\\:mm\\\\:ss'\)") '下载进度计时不得使用无效的双反斜杠格式'
Assert-True ($manager -match 'Where-Object \{ \$_ -ne ''SubtitleSourceMode'' \}') '管理界面保存配置时不得覆盖字幕来源模式'

Write-Host 'PASS Test-Subtitle-UI' -ForegroundColor Green
