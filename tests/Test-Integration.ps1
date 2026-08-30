$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Test-Helpers.ps1"

$root = Split-Path -Parent $PSScriptRoot
$configText = [IO.File]::ReadAllText((Join-Path $root 'config.ps1'), [Text.Encoding]::UTF8)
$autoCutText = [IO.File]::ReadAllText((Join-Path $root 'AutoCut.ps1'), [Text.Encoding]::UTF8)

foreach ($name in @(
    'SubtitleSourceMode',
    'AliyunSubtitlesEnabled',
    'AliyunModel',
    'AliyunEndpoint',
    'AliyunTimeoutMinutes',
    'SubtitleFontName',
    'SubtitleFontFile',
    'SubtitleOutlineColor',
    'SubtitleMinChars',
    'SubtitleSafeWidthPercent',
    'SubtitleMarginVPortrait',
    'SubtitleMarginVLandscape',
    'SubtitleMinimumDuration'
)) {
    Assert-True ($configText -match ('\$' + [regex]::Escape($name) + '\s*=')) "配置必须包含 $name"
}

Assert-True ($configText -match '(?m)^\s*\$SubtitleSourceMode\s*=\s*[''"]paraformer_local[''"]\s*$') '默认字幕来源必须为 paraformer_local'
. (Join-Path $root 'config.ps1')
Assert-True (-not [string]::IsNullOrWhiteSpace($SubtitleFontName)) '字幕配置必须保存当前选择的字体名称'
if (-not [string]::IsNullOrWhiteSpace($SubtitleFontFile)) {
    Assert-True (Test-Path -LiteralPath (Join-Path $root $SubtitleFontFile) -PathType Leaf) '字幕配置指定的便携字体文件必须存在'
}
Assert-True ($autoCutText -match "paraformer_local.+aliyun_only.+aliyun_fallback.+text_preferred") '主程序必须允许本地 Paraformer 和原有字幕来源模式'
Assert-True ($autoCutText -match 'SafeWidthPercent\s*=\s*94') '正式字幕安全宽度必须固定为94%'

$cacheFunction = [regex]::Match($autoCutText, '(?s)function\s+Get-SubtitleCachePath\s*\([^)]*\)\s*\{.*?\n\}').Value
Assert-True ($cacheFunction -match '\$SubtitleSourceMode') '字幕缓存标识必须包含字幕来源模式'
Assert-True ($cacheFunction -match 'GetFullPath') '字幕缓存标识必须包含规范化音频完整路径'
Assert-True ($cacheFunction -match 'Get-FileHash[^\r\n]+SHA256|SHA256[^\r\n]+Get-FileHash') '字幕缓存标识必须包含音频内容SHA-256'

$prepareStart = $autoCutText.IndexOf('function Prepare-Subtitle')
$prepareEnd = $autoCutText.IndexOf('function New-ShuffledVideoBag', $prepareStart)
$prepareFunction = $autoCutText.Substring($prepareStart, $prepareEnd - $prepareStart)
Assert-True ($prepareFunction -match '\$SubtitleSourceMode\s*-eq\s*[''"]aliyun_only[''"]') '严格模式必须有独立决策分支'
Assert-True ($prepareFunction -match '严格阿里云模式.+API Key') '严格模式缺少API Key时必须抛出清晰中文错误'
Assert-True ($prepareFunction -match '严格阿里云字幕失败') '严格模式请求失败或结果无效时必须抛出清晰中文错误'
Assert-True ($prepareFunction -match 'Convert-AliyunResultToSegments[\s\S]*-AudioDuration\s+\$Duration[\s\S]*Limit-SubtitleSegments') '阿里云原始时间戳必须带音频时长校验后才能进入Limit-SubtitleSegments'
Assert-True ($prepareFunction -match 'Clamp-SrtTimelineToAudio[\s\S]*Assert-TwoLineSubtitleFile') '阿里云字幕在最终验证前必须硬裁切到音频时长'
Assert-True ($prepareFunction -match 'aliyun_raw\.json') '阿里云字幕诊断必须保存原始返回结果'
Assert-True ($autoCutText -match 'function\s+Add-TodayCompletedVideoCount') '正式成品发布后必须更新当日视频统计'
Assert-True ($autoCutText -match 'if\s*\(\$TestMode\s*-or\s*\$Count\s*-le\s*0\)') '10秒测试不得计入当日视频统计'
Assert-True ($autoCutText -match 'Add-TodayCompletedVideoCount\s+\$renderCount') '统计必须使用实际发布的视频数量'
Assert-True ($prepareFunction -match 'segments_before_repair\.json') '阿里云字幕诊断必须保存修复前分段'
Assert-True ($prepareFunction -match 'segments_after_repair\.json') '阿里云字幕诊断必须保存修复后分段'
Assert-True ($prepareFunction -match 'subtitles_before_clamp\.srt') '阿里云字幕诊断必须保存裁切前SRT'
Assert-True ($prepareFunction -match 'subtitles_after_clamp\.srt') '阿里云字幕诊断必须保存裁切后SRT'

$validatorFunction = [regex]::Match($autoCutText, '(?s)function\s+Assert-TwoLineSubtitleFile\s*(?:\([^)]*\))?\s*\{.*?\n\}').Value
Assert-True (-not [string]::IsNullOrWhiteSpace($validatorFunction)) '主程序必须提供两行字幕文件验证入口'
Assert-True ($validatorFunction -match 'Convert-SrtToSegments') '两行字幕验证必须解析SRT分段'
Assert-True ($validatorFunction -match 'PreserveEvents') '两行字幕验证必须校验磁盘中的原始SRT事件而非重拆结果'
Assert-True ($validatorFunction -match 'MinimumDuration\s+0\.0') 'SRT复检不得重新拉长靠近音频结尾的字幕'
Assert-True ($validatorFunction -match 'Test-SubtitleSegments') '两行字幕验证必须调用字幕段校验'
Assert-True ($validatorFunction -match 'Get-SubtitleSplitOptions') '两行字幕验证必须使用当前字幕布局选项'
Assert-True ($validatorFunction -match 'textLines.Count.+2') '两行字幕验证必须拒绝超过两行的事件'
Assert-True ($prepareFunction -match '缓存.+Assert-TwoLineSubtitleFile|Assert-TwoLineSubtitleFile.+缓存') '缓存命中后必须重新验证'
Assert-True ($prepareFunction -match 'Remove-Item.+\$cachePath') '缓存验证失败后必须删除缓存'
Assert-True ($prepareFunction -match 'Convert-SrtToSimplified\s+\$DestinationSrt[\s\S]*Assert-TwoLineSubtitleFile[\s\S]*Copy-Item.+\$cachePath') '字幕转换成功后必须先验证再写缓存'
$formatFunction = [regex]::Match($autoCutText, '(?s)function\s+Format-SrtLineLength\s*\([^)]*\)\s*\{.*?\n\}').Value
Assert-True ($formatFunction -match 'Subtitle-Core\\Convert-SrtToSegments') 'Whisper和文本稿字幕整理必须复用两行语义分段器'
Assert-True ($formatFunction -match 'Subtitle-Core\\New-SrtFromSegments') 'Whisper和文本稿字幕整理必须写回两行SRT事件'

$subtitleGateFunction = [regex]::Match($autoCutText, '(?s)function\s+Prepare-SubtitleForRender\s*\([^)]*\)\s*\{.*?\n\}').Value
Assert-True (-not [string]::IsNullOrWhiteSpace($subtitleGateFunction)) '渲染前必须存在统一字幕准备入口'
Assert-True ($subtitleGateFunction -match 'Prepare-Subtitle') '统一字幕准备入口必须执行字幕准备和验证'
$fontPrepareFunction = [regex]::Match($autoCutText, '(?s)function\s+Prepare-PortableFontDirectory\s*\([^)]*\)\s*\{.*?\n\}').Value
Assert-True (-not [string]::IsNullOrWhiteSpace($fontPrepareFunction)) '正式剪辑必须存在便携字体准备入口'
$openccConvertFunction = [regex]::Match($autoCutText, '(?s)function\s+Convert-SrtToSimplified\s*\([^)]*\)\s*\{.*?\n\}').Value
Assert-True (-not [string]::IsNullOrWhiteSpace($openccConvertFunction)) '主程序必须存在OpenCC简体转换入口'
Assert-True ($openccConvertFunction -match 'ReadAllText\(\$SrtPath,\s*\[Text\.Encoding\]::UTF8\)[\s\S]*WriteAllText\(\$input,[\s\S]*UTF8Encoding\]::new\(\$false\)') 'OpenCC临时输入必须由目标SRT按UTF-8读取后显式写成无BOM UTF-8'
Assert-True ($openccConvertFunction -match 'ReadAllText\(\$output,\s*\[Text\.Encoding\]::UTF8\)[\s\S]*WriteAllText\(\$SrtPath,[\s\S]*UTF8Encoding\]::new\(\$true\)') 'OpenCC输出必须按UTF-8读取后显式写成带BOM目标SRT'
Assert-True ($openccConvertFunction -notmatch 'Move-Item\s+-LiteralPath\s+\$output') 'OpenCC输出不得再以原始字节Move到目标SRT'
$audioLoopStart = $autoCutText.IndexOf('foreach ($audio in $audios)')
$remainingStart = $autoCutText.IndexOf('$remaining = $audioDuration', $audioLoopStart)
$firstFalsePathFfmpeg = $autoCutText.IndexOf('Invoke-Checked $Ffmpeg', $remainingStart)
$subtitleGateCall = $autoCutText.IndexOf('Prepare-SubtitleForRender', $audioLoopStart)
Assert-True ($subtitleGateCall -ge 0 -and $subtitleGateCall -lt $remainingStart) 'FastSinglePass=false时字幕准备必须早于片段工作'
Assert-True ($firstFalsePathFfmpeg -gt $remainingStart) 'FastSinglePass=false路径必须包含FFmpeg片段工作'
Assert-True ($autoCutText -match '\$stagedOutputDir\s*=\s*if\s*\(\$TestMode\s*-or\s*-not\s+\$FastSinglePass\)\s*\{\s*\$audioOutputDir') '非快速成品必须写入不会随audioWork清理的输出目录'

$autoCutPath = Join-Path $root 'AutoCut.ps1'
$parseTokens = $null
$parseErrors = $null
$autoCutAst = [Management.Automation.Language.Parser]::ParseFile($autoCutPath, [ref]$parseTokens, [ref]$parseErrors)
Assert-Equal 0 $parseErrors.Count 'AutoCut.ps1必须可供执行级集成测试解析'

Import-Module (Join-Path $root 'Subtitle-Core.psm1') -Force -DisableNameChecking
Invoke-Expression $validatorFunction
$SubtitleMinimumDuration = 0.8
function Get-SubtitleSplitOptions {
    return @{
        FontName = 'Microsoft YaHei'
        FontSize = 32
        FrameWidth = 240
        FrameHeight = 1920
        Outline = 2
        SafeWidthPercent = 84
        MaxChars = 0
        MinChars = 1
    }
}
$wideSrtPath = Join-Path ([IO.Path]::GetTempPath()) ('autocut_wide_source_' + [guid]::NewGuid().ToString('N') + '.srt')
try {
    [IO.File]::WriteAllText($wideSrtPath, "1`r`n00:00:00,000 --> 00:00:10,000`r`n$('W' * 40)", [Text.Encoding]::UTF8)
    $wideSrtMessage = $null
    try {
        Assert-TwoLineSubtitleFile -SubtitlePath $wideSrtPath -Duration 10 -Stage '磁盘SRT' | Out-Null
    } catch {
        $wideSrtMessage = $_.Exception.Message
    }
    Assert-True ($wideSrtMessage -match '像素宽度') '磁盘SRT中每个原始事件必须直接通过当前像素宽度门禁'
} finally {
    Remove-Item -LiteralPath $wideSrtPath -Force -ErrorAction SilentlyContinue
}

$corePathForCacheTest = (Join-Path $root 'Subtitle-Core.psm1').Replace("'", "''")
$cacheFunctionForTest = $cacheFunction.Replace("(Join-Path `$PSScriptRoot 'Subtitle-Core.psm1')", "'$corePathForCacheTest'")
Invoke-Expression $cacheFunctionForTest
function Safe-Name($Name) { return ($Name -replace '[\\/:*?""<>|]', '_') }
$cacheIdentityRoot = Join-Path ([IO.Path]::GetTempPath()) ('autocut_cache_identity_' + [guid]::NewGuid().ToString('N'))
try {
    $WorkDir = Join-Path $cacheIdentityRoot 'work'
    $dirA = Join-Path $cacheIdentityRoot 'a'
    $dirB = Join-Path $cacheIdentityRoot 'b'
    New-Item -ItemType Directory -Path $dirA,$dirB -Force | Out-Null
    $audioAPath = Join-Path $dirA 'same.wav'
    $audioBPath = Join-Path $dirB 'same.wav'
    [IO.File]::WriteAllBytes($audioAPath, [byte[]](1,2,3,4))
    [IO.File]::WriteAllBytes($audioBPath, [byte[]](4,3,2,1))
    $fixedTime = [datetime]::SpecifyKind([datetime]'2026-01-02T03:04:05', [DateTimeKind]::Utc)
    [IO.File]::SetLastWriteTimeUtc($audioAPath, $fixedTime)
    [IO.File]::SetLastWriteTimeUtc($audioBPath, $fixedTime)

    $SubtitleSourceMode = 'aliyun_only'
    $AliyunModel = 'paraformer-v2'
    $SubtitleFontName = 'Microsoft YaHei'
    $SubtitleFontSize = 16
    $SubtitleOutline = 2
    $SubtitleMaxCharsPerLine = 0
    $SubtitleMinChars = 6
    $SubtitleSafeWidthPercent = 84
    $targetWidth = 1080
    $targetHeight = 1920
    $TestSeconds = 10
    $pathA1 = Get-SubtitleCachePath (Get-Item -LiteralPath $audioAPath) $false
    $pathB = Get-SubtitleCachePath (Get-Item -LiteralPath $audioBPath) $false
    Assert-True ($pathA1 -ne $pathB) '同名同大小同时间但路径和内容不同的音频不得碰撞缓存'

    [IO.File]::WriteAllBytes($audioAPath, [byte[]](9,8,7,6))
    [IO.File]::SetLastWriteTimeUtc($audioAPath, $fixedTime)
    $pathA2 = Get-SubtitleCachePath (Get-Item -LiteralPath $audioAPath) $false
    Assert-True ($pathA1 -ne $pathA2) '同一路径内容替换后即使大小和时间不变也不得复用缓存'

    $textPathForCache = Join-Path $dirA 'same.txt'
    [IO.File]::WriteAllText($textPathForCache, 'AAAA', [Text.Encoding]::ASCII)
    [IO.File]::SetLastWriteTimeUtc($textPathForCache, $fixedTime)
    $SubtitleSourceMode = 'text_preferred'
    $textCache1 = Get-SubtitleCachePath (Get-Item -LiteralPath $audioAPath) $false $textPathForCache
    [IO.File]::WriteAllText($textPathForCache, 'BBBB', [Text.Encoding]::ASCII)
    [IO.File]::SetLastWriteTimeUtc($textPathForCache, $fixedTime)
    $textCache2 = Get-SubtitleCachePath (Get-Item -LiteralPath $audioAPath) $false $textPathForCache
    Assert-True ($textCache1 -ne $textCache2) 'text_preferred同名TXT内容变化后即使大小和时间不变也不得复用缓存'
} finally {
    Remove-Item -LiteralPath $cacheIdentityRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$fastIf = $autoCutAst.FindAll({
    param($node)
    $node -is [Management.Automation.Language.IfStatementAst] -and
        $node.Clauses[0].Item1.Extent.Text -eq '$FastSinglePass'
}, $true) | Select-Object -First 1
$outputInitializers = @($autoCutAst.FindAll({
    param($node)
    $node -is [Management.Automation.Language.AssignmentStatementAst] -and
        $node.Left.Extent.Text -eq '$output' -and
        $node.Extent.StartLineNumber -gt 1315 -and
        $node.Extent.EndLineNumber -lt $fastIf.Extent.StartLineNumber
}, $true))
Assert-Equal 1 $outputInitializers.Count 'FastSinglePass分支前必须确定初始化输出路径'

$legacyFinalIf = $autoCutAst.FindAll({
    param($node)
    $node -is [Management.Automation.Language.IfStatementAst] -and
        $node.Extent.Text -match '合成带字幕成片' -and
        $node.Extent.Text -match '合成成片'
}, $true) | Select-Object -Last 1
Assert-True ($null -ne $legacyFinalIf) '必须找到非快速最终合成生产分支'
$legacyTestDir = Join-Path ([IO.Path]::GetTempPath()) ('autocut_non_fast_output_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $legacyTestDir | Out-Null
try {
    $TestMode = $false
    $stagedOutputDir = $legacyTestDir
    $audioBase = 'sample'
    $TestSeconds = 10
    $renderCount = 1
    function Get-OutputVideoFileName($AudioBase, [int]$RenderIndex, [int]$RenderCount, [bool]$IsTest, [int]$TestSeconds) {
        if ($IsTest) { return "$AudioBase`_测试${TestSeconds}秒.mp4" }
        if ($RenderCount -le 1) { return "$AudioBase.mp4" }
        return ("{0}_{1:D2}.mp4" -f $AudioBase, $RenderIndex)
    }
    Invoke-Expression $outputInitializers[0].Extent.Text
    $expectedLegacyOutput = Join-Path $legacyTestDir 'sample.mp4'
    Assert-Equal $expectedLegacyOutput $output '非快速路径必须初始化到确定的成品路径'

    $script:legacyInvocationOutput = $null
    function Invoke-Checked($File, $Arguments, $Step) {
        $script:legacyInvocationOutput = [string]$Arguments[-1]
        [IO.File]::WriteAllText($script:legacyInvocationOutput, 'readable output', [Text.Encoding]::UTF8)
    }
    $useSubtitle = $false
    $Ffmpeg = 'fake-ffmpeg.exe'
    $concatVideo = Join-Path $legacyTestDir 'concat.mp4'
    $audio = [pscustomobject]@{ FullName = (Join-Path $legacyTestDir 'audio.wav') }
    $AudioBitrate = '192k'
    $encodeArgs = @()
    Invoke-Expression $legacyFinalIf.Extent.Text
    Assert-Equal $expectedLegacyOutput $script:legacyInvocationOutput '非快速最终FFmpeg调用必须收到有效输出路径'
    Assert-True (Test-Path -LiteralPath $expectedLegacyOutput -PathType Leaf) '非快速执行级路径必须产生可读输出文件'
} finally {
    Remove-Item Function:\Invoke-Checked -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $legacyTestDir -Recurse -Force -ErrorAction SilentlyContinue
}

$subtitleContractDir = Join-Path ([IO.Path]::GetTempPath()) ('autocut_subtitle_bool_contract_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $subtitleContractDir | Out-Null
try {
    $fontPath = Join-Path $subtitleContractDir 'font.ttf'
    [IO.File]::WriteAllBytes($fontPath, [byte[]](1,2,3,4))
    $contractOutputs = @(& {
        param($gateSource, $fontSource, $workDir, $selectedFont)
        Invoke-Expression $fontSource
        Invoke-Expression $gateSource
        $EnableSubtitles = $true
        function Prepare-Subtitle { return $true }
        function Ensure-Directory($Path) { [IO.Directory]::CreateDirectory($Path) | Out-Null }
        function Get-SubtitleFontPath { return $selectedFont }
        function Copy-Item {
            param([string]$LiteralPath, [string]$Destination, [switch]$Force)
            $copiedPath = Join-Path $Destination ([IO.Path]::GetFileName($LiteralPath))
            [IO.File]::Copy($LiteralPath, $copiedPath, $true)
            return Get-Item -LiteralPath $copiedPath
        }
        Prepare-SubtitleForRender ([pscustomobject]@{ FullName = 'audio.wav' }) 1.0 (Join-Path $workDir 'subtitle.srt') $false $workDir
    } $subtitleGateFunction $fontPrepareFunction $subtitleContractDir $fontPath)
    Assert-Equal 1 $contractOutputs.Count 'Prepare-SubtitleForRender必须只输出一个返回值，字体复制对象不得污染管道'
    Assert-True ($contractOutputs[0] -is [bool]) 'Prepare-SubtitleForRender返回契约必须严格为bool'
    Assert-True $contractOutputs[0] '字幕准备成功时Prepare-SubtitleForRender必须返回true'
} finally {
    Remove-Item -LiteralPath $subtitleContractDir -Recurse -Force -ErrorAction SilentlyContinue
}

$openccEncodingTestDir = Join-Path ([IO.Path]::GetTempPath()) ('autocut_opencc_bom_contract_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $openccEncodingTestDir | Out-Null
try {
    $openccSrtPath = Join-Path $openccEncodingTestDir 'input.srt'
    $openccCachePath = Join-Path $openccEncodingTestDir 'cache.srt'
    $traditionalSrt = "1`r`n00:00:00,000 --> 00:00:01,000`r`n測試繁體轉簡體"
    [IO.File]::WriteAllText($openccSrtPath, $traditionalSrt, [Text.UTF8Encoding]::new($true))
    $openccFunctionForTest = $openccConvertFunction.Replace('$PSScriptRoot', '$AutoCutRoot')
    & {
        param($functionSource, $rootPath, $srtPath)
        $AutoCutRoot = $rootPath
        $OpenCC = Join-Path $rootPath 'tools\opencc\bin\opencc.exe'
        $OpenCCConfig = Join-Path $rootPath 'tools\opencc\share\opencc\t2s.json'
        function Ensure-Directory($Path) { [IO.Directory]::CreateDirectory($Path) | Out-Null }
        Invoke-Expression $functionSource
        Convert-SrtToSimplified $srtPath
    } $openccFunctionForTest $root $openccSrtPath

    $convertedBytes = [IO.File]::ReadAllBytes($openccSrtPath)
    Assert-True ($convertedBytes.Length -ge 3 -and $convertedBytes[0] -eq 0xEF -and $convertedBytes[1] -eq 0xBB -and $convertedBytes[2] -eq 0xBF) 'OpenCC转换后的目标SRT必须使用UTF-8 BOM'
    $convertedText = [IO.File]::ReadAllText($openccSrtPath, [Text.Encoding]::UTF8)
    Assert-True ($convertedText -match '测试繁体转简体') '带BOM的繁体SRT经生产OpenCC流程后必须得到正确简体内容'
    $mojibakePattern = 'æ²|è©|ç¹|é«|è½|ç°|Ã|Â'
    Assert-True ($convertedText -notmatch $mojibakePattern) 'OpenCC转换结果不得包含常见UTF-8 mojibake'
    Copy-Item -LiteralPath $openccSrtPath -Destination $openccCachePath -Force
    $cacheSrtText = [IO.File]::ReadAllText($openccCachePath, [Text.Encoding]::UTF8)
    Assert-True ($cacheSrtText -notmatch $mojibakePattern) '写入缓存的SRT不得包含常见UTF-8 mojibake'
    Assert-True ($cacheSrtText -match '测试繁体转简体') '缓存SRT必须保留正确简体内容'
} finally {
    Remove-Item -LiteralPath $openccEncodingTestDir -Recurse -Force -ErrorAction SilentlyContinue
}

Invoke-Expression $prepareFunction
Invoke-Expression $subtitleGateFunction
$subtitleValidationTestDir = Join-Path ([IO.Path]::GetTempPath()) ('autocut_subtitle_validation_test_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $subtitleValidationTestDir | Out-Null
try {
    $audioPath = Join-Path $subtitleValidationTestDir 'audio.wav'
    $textPath = Join-Path $subtitleValidationTestDir 'audio.txt'
    $cachePath = Join-Path $subtitleValidationTestDir 'cache.srt'
    $destinationPath = Join-Path $subtitleValidationTestDir 'destination.srt'
    [IO.File]::WriteAllBytes($audioPath, [byte[]](1, 2, 3))
    [IO.File]::WriteAllText($textPath, '测试文本', [Text.Encoding]::UTF8)
    $audio = Get-Item -LiteralPath $audioPath

    $SubtitleSourceMode = 'text_preferred'
    $AliyunSubtitlesEnabled = $false
    $Whisper = Join-Path $subtitleValidationTestDir 'missing-whisper.exe'
    $WhisperModel = Join-Path $subtitleValidationTestDir 'missing-model.bin'
    $SubtitleMinimumDuration = 0.8
    $script:validationCachePath = $cachePath
    $script:validationCalls = 0
    $script:textFallbackCalls = 0

    function Get-SidecarTextPath { return $textPath }
    function Get-SubtitleCachePath { return $script:validationCachePath }
    function Read-SubtitleTextFile { return '测试文本' }
    function Write-Log {}
    function Convert-SrtToSimplified {}
    function Clamp-SrtTimelineToAudio { return 1 }
    function Format-SrtLineLength {}
    function New-SrtFromTextFile($TextPath, [double]$Duration, $DestinationSrt) {
        $script:textFallbackCalls += 1
        [IO.File]::WriteAllText($DestinationSrt, "1`r`n00:00:00,000 --> 00:00:01,000`r`n$([IO.File]::ReadAllText($TextPath))", [Text.Encoding]::UTF8)
    }
    function Assert-TwoLineSubtitleFile($SubtitlePath, [double]$Duration, [string]$Stage) {
        $script:validationCalls += 1
        $content = [IO.File]::ReadAllText($SubtitlePath, [Text.Encoding]::UTF8)
        if ($content -match '坏字幕') {
            throw "$Stage验证失败：字幕格式无效。"
        }
    }

    [IO.File]::WriteAllText($cachePath, "1`r`n00:00:00,000 --> 00:00:01,000`r`n坏字幕", [Text.Encoding]::UTF8)
    [void](Prepare-Subtitle $audio 1 $destinationPath $false)
    Assert-Equal 2 $script:validationCalls '缓存失效后应验证缓存并验证重新生成的字幕'
    Assert-Equal 1 $script:textFallbackCalls '缓存失效后必须重新生成字幕'
    Assert-True ([IO.File]::ReadAllText($cachePath, [Text.Encoding]::UTF8) -match '测试文本') '缓存失效后必须写入新的合格字幕'

    Remove-Item -LiteralPath $cachePath -Force
    Remove-Item -LiteralPath $destinationPath -Force -ErrorAction SilentlyContinue
    $script:validationCalls = 0
    $script:textFallbackCalls = 0
    function New-SrtFromTextFile($TextPath, [double]$Duration, $DestinationSrt) {
        $script:textFallbackCalls += 1
        [IO.File]::WriteAllText($DestinationSrt, "1`r`n00:00:00,000 --> 00:00:01,000`r`n坏字幕", [Text.Encoding]::UTF8)
    }
    $caught = $null
    try {
        [void](Prepare-Subtitle $audio 1 $destinationPath $false)
    } catch {
        $caught = $_.Exception.Message
    }
    Assert-True ($caught -match '字幕格式无效|验证失败') '新字幕验证失败必须给出清晰中文错误'
    Assert-True (-not (Test-Path -LiteralPath $cachePath)) '字幕验证失败时不得写入缓存'
} finally {
    Remove-Item -LiteralPath $subtitleValidationTestDir -Recurse -Force -ErrorAction SilentlyContinue
}

$noSubtitleCachePath = Join-Path ([IO.Path]::GetTempPath()) ('autocut_bad_cache_no_subtitle_' + [guid]::NewGuid().ToString('N') + '.srt')
$noSubtitleDestinationPath = Join-Path ([IO.Path]::GetTempPath()) ('autocut_bad_cache_no_subtitle_destination_' + [guid]::NewGuid().ToString('N') + '.srt')
$noSubtitleOutputPath = Join-Path ([IO.Path]::GetTempPath()) ('autocut_bad_cache_no_subtitle_output_' + [guid]::NewGuid().ToString('N') + '.mp4')
try {
    $SubtitleSourceMode = 'text_preferred'
    $AliyunSubtitlesEnabled = $false
    $Whisper = Join-Path ([IO.Path]::GetTempPath()) 'missing-whisper.exe'
    $WhisperModel = Join-Path ([IO.Path]::GetTempPath()) 'missing-model.bin'
    $EnableSubtitles = $true
    $script:validationCachePath = $noSubtitleCachePath
    $script:renderCallsAfterSubtitleFailure = 0
    function Get-SidecarTextPath { return $null }
    function Invoke-SinglePassRender {
        $script:renderCallsAfterSubtitleFailure += 1
        [IO.File]::WriteAllText($noSubtitleOutputPath, '无字幕成品', [Text.Encoding]::UTF8)
    }

    [IO.File]::WriteAllText($noSubtitleCachePath, "1`r`n00:00:00,000 --> 00:00:01,000`r`n坏字幕", [Text.Encoding]::UTF8)
    $useSubtitle = $false
    $caught = $null
    try {
        $useSubtitle = Prepare-Subtitle $audio 1 $noSubtitleDestinationPath $false
    } catch {
        $caught = $_.Exception.Message
    }
    if ($EnableSubtitles -and -not $caught -and -not $useSubtitle) {
        Invoke-SinglePassRender
    }
    Assert-True ($caught -match '缓存验证失败|无法重新生成合格字幕') '坏缓存重新生成失败时必须抛出中文错误并停止任务'
    Assert-Equal 0 $script:renderCallsAfterSubtitleFailure '字幕生成失败时不得调用成品渲染'
    Assert-True (-not (Test-Path -LiteralPath $noSubtitleOutputPath)) '字幕生成失败时不得产生无字幕成品'
    Assert-True (-not (Test-Path -LiteralPath $noSubtitleCachePath)) '坏缓存必须被删除'
} finally {
    Remove-Item -LiteralPath $noSubtitleCachePath,$noSubtitleDestinationPath,$noSubtitleOutputPath -Force -ErrorAction SilentlyContinue
}

$falsePathCachePath = Join-Path ([IO.Path]::GetTempPath()) ('autocut_false_path_bad_cache_' + [guid]::NewGuid().ToString('N') + '.srt')
$falsePathDestinationPath = Join-Path ([IO.Path]::GetTempPath()) ('autocut_false_path_destination_' + [guid]::NewGuid().ToString('N') + '.srt')
$falsePathOutputPath = Join-Path ([IO.Path]::GetTempPath()) ('autocut_false_path_output_' + [guid]::NewGuid().ToString('N') + '.mp4')
$falsePathWork = Join-Path ([IO.Path]::GetTempPath()) ('autocut_false_path_work_' + [guid]::NewGuid().ToString('N'))
try {
    $SubtitleSourceMode = 'text_preferred'
    $AliyunSubtitlesEnabled = $false
    $Whisper = Join-Path ([IO.Path]::GetTempPath()) 'missing-whisper.exe'
    $WhisperModel = Join-Path ([IO.Path]::GetTempPath()) 'missing-model.bin'
    $EnableSubtitles = $true
    $FastSinglePass = $false
    $script:validationCachePath = $falsePathCachePath
    $script:falsePathFfmpegCalls = 0
    $script:falsePathPublishCalls = 0
    function Invoke-Checked {
        $script:falsePathFfmpegCalls += 1
    }
    function Publish-CompleteVideoFolder {
        $script:falsePathPublishCalls += 1
        [IO.File]::WriteAllText($falsePathOutputPath, '错误发布', [Text.Encoding]::UTF8)
    }

    [IO.File]::WriteAllText($falsePathCachePath, "1`r`n00:00:00,000 --> 00:00:01,000`r`n坏字幕", [Text.Encoding]::UTF8)
    $useSubtitle = $false
    $caught = $null
    try {
        $useSubtitle = Prepare-SubtitleForRender $audio 1 $falsePathDestinationPath $false $falsePathWork
    } catch {
        $caught = $_.Exception.Message
    }
    if (-not $caught) {
        Invoke-Checked
        Publish-CompleteVideoFolder
    }
    Assert-True ($caught -match '缓存验证失败|无法重新生成合格字幕') 'FastSinglePass=false坏缓存重建失败必须抛出中文错误'
    Assert-Equal 0 $script:falsePathFfmpegCalls 'FastSinglePass=false字幕失败时不得调用任何FFmpeg入口'
    Assert-Equal 0 $script:falsePathPublishCalls 'FastSinglePass=false字幕失败时不得调用发布入口'
    Assert-True (-not (Test-Path -LiteralPath $falsePathOutputPath)) 'FastSinglePass=false字幕失败时不得产生发布输出'
} finally {
    Remove-Item -LiteralPath $falsePathCachePath,$falsePathDestinationPath,$falsePathOutputPath,$falsePathWork -Recurse -Force -ErrorAction SilentlyContinue
}

$strictTestDir = Join-Path ([IO.Path]::GetTempPath()) ('autocut_strict_test_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $strictTestDir | Out-Null
try {
    $audioPath = Join-Path $strictTestDir 'audio.wav'
    $textPath = Join-Path $strictTestDir 'audio.txt'
    $toolPath = Join-Path $strictTestDir 'whisper.exe'
    $modelPath = Join-Path $strictTestDir 'model.bin'
    [IO.File]::WriteAllBytes($audioPath, [byte[]](1, 2, 3))
    [IO.File]::WriteAllText($textPath, '测试文本', [Text.Encoding]::UTF8)
    [IO.File]::WriteAllBytes($toolPath, [byte[]](1))
    [IO.File]::WriteAllBytes($modelPath, [byte[]](1))
    $audio = Get-Item -LiteralPath $audioPath

    $SubtitleSourceMode = 'aliyun_only'
    $AliyunSubtitlesEnabled = $true
    $AliyunEndpoint = 'test'
    $AliyunModel = 'test'
    $AliyunTimeoutMinutes = 1
    $SubtitleMinimumDuration = 0.8
    $whisperWav = Join-Path $strictTestDir 'whisper.wav'
    $script:strictScenario = ''
    $script:strictTextPath = $null
    $script:strictCachePath = Join-Path $strictTestDir 'cache.srt'
    $script:whisperCalls = 0
    $script:textFallbackCalls = 0

    function Get-SidecarTextPath { return $script:strictTextPath }
    function Get-SubtitleCachePath { return $script:strictCachePath }
    function Read-SubtitleTextFile { return '测试文本' }
    function Write-Log {}
    function Save-SubtitleDiagnosticJson {}
    function Save-SubtitleDiagnosticCopy {}
    function Get-AliyunApiKey {
        if ($script:strictScenario -eq 'missing_key') { return $null }
        return 'test-key'
    }
    function Invoke-AliyunTranscription { throw '模拟阿里云请求失败' }
    function Invoke-Checked { $script:whisperCalls += 1 }
    function Invoke-WhisperSrt { $script:whisperCalls += 1 }
    function New-SrtFromTextFile { $script:textFallbackCalls += 1 }

    foreach ($scenario in @('missing_key', 'aliyun_failure')) {
        foreach ($fallback in @('txt', 'whisper')) {
            $script:strictScenario = $scenario
            $script:strictTextPath = if ($fallback -eq 'txt') { $textPath } else { $null }
            $Whisper = if ($fallback -eq 'whisper') { $toolPath } else { Join-Path $strictTestDir 'missing-whisper.exe' }
            $WhisperModel = if ($fallback -eq 'whisper') { $modelPath } else { Join-Path $strictTestDir 'missing-model.bin' }
            $script:whisperCalls = 0
            $script:textFallbackCalls = 0
            $caught = $null
            try {
                [void](Prepare-Subtitle $audio 10 (Join-Path $strictTestDir 'output.srt') $false)
            } catch {
                $caught = $_.Exception.Message
            }
            Assert-True ($caught -match '^严格阿里云字幕失败：') "严格模式 $scenario/$fallback 必须抛出清晰中文错误"
            Assert-Equal 0 $script:whisperCalls "严格模式 $scenario/$fallback 不能调用Whisper"
            Assert-Equal 0 $script:textFallbackCalls "严格模式 $scenario/$fallback 不能调用TXT按时长兜底"
        }
    }

    Remove-Item -LiteralPath $script:strictCachePath -Force -ErrorAction SilentlyContinue
    $script:strictTextPath = $textPath
    $script:strictReadTextCalls = 0
    function Get-SubtitleSplitOptions {
        return @{
            FontName = 'Microsoft YaHei'
            FontSize = 16
            FrameWidth = 1080
            FrameHeight = 1920
            Outline = 2
            SafeWidthPercent = 84
            MaxChars = 0
            MinChars = 1
        }
    }
    function Read-SubtitleTextFile { $script:strictReadTextCalls++; return '错误TXT文字' }
    function Invoke-AliyunTranscription {
        return [pscustomobject]@{
            transcripts = @([pscustomobject]@{
                text = '阿里云文字'
                sentences = @([pscustomobject]@{ begin_time = 0; end_time = 1000; text = '阿里云文字'; words = @() })
            })
        }
    }
    $strictOutput = Join-Path $strictTestDir 'strict-success.srt'
    $strictSuccess = Prepare-Subtitle $audio 10 $strictOutput $false
    Assert-True $strictSuccess '严格阿里云成功结果必须生成字幕'
    Assert-Equal 0 $script:strictReadTextCalls 'aliyun_only必须完全忽略同名TXT'
    $strictSrtText = [IO.File]::ReadAllText($strictOutput, [Text.Encoding]::UTF8)
    $strictSrtSegments = @(Subtitle-Core\Convert-SrtToSegments -SrtPath $strictOutput -PreserveEvents)
    Assert-Equal (Subtitle-Core\Normalize-SubtitleText '阿里云文字') (Subtitle-Core\Normalize-SubtitleText ($strictSrtSegments.Text -join '')) 'aliyun_only字幕文字必须来自阿里云结果'
    Assert-True ($strictSrtText -notmatch '错误TXT文字') 'aliyun_only不得使用同名TXT替换文字'
} finally {
    Remove-Item -LiteralPath $strictTestDir -Recurse -Force -ErrorAction SilentlyContinue
}

Assert-True ($autoCutText -match 'Import-Module.+Subtitle-Core') '主程序必须加载字幕核心模块'
Assert-True ($autoCutText -match 'Import-Module.+Subtitle-Aliyun') '主程序必须加载阿里云模块'
Assert-True ($autoCutText -match 'Invoke-AliyunTranscription') '主程序必须优先尝试阿里云识别'
Assert-True ($autoCutText -match 'Convert-SrtToSegments') 'Whisper回退必须能够继续匹配TXT'
Assert-True ($autoCutText -match 'fontsdir') 'FFmpeg字幕滤镜必须加载便携字体目录'
Assert-True ($autoCutText -notmatch 'sk-[A-Za-z0-9]{8,}') '主程序不得包含明文API Key'

Assert-True ($fontPrepareFunction -match 'Get-SubtitleFontPath') '正式剪辑必须复制当前选中的便携字体，包括子目录字体'
Assert-True ($fontPrepareFunction -match 'Copy-Item[^\r\n]*\|\s*Out-Null') '字体复制必须抑制FileInfo管道输出'
Assert-True ($subtitleGateFunction -match 'return\s+\[bool\]\$useSubtitle') '渲染前字幕准备必须显式返回bool'

$publishFunction = [regex]::Match($autoCutText, '(?s)function\s+Publish-CompleteVideoFolder\s*\([^)]*\)\s*\{.*?\n\}').Value
Assert-True ($publishFunction -match '\$ExpectedCount') '成品发布日志必须显示当前配置的实际数量'
Assert-True ($publishFunction -notmatch '"6 条成品验证通过') '成品发布日志不得把数量写死为6条'

$styleFunction = [regex]::Match($autoCutText, '(?s)function\s+Get-SubtitleStyle\s*\{.*?\n\}').Value
Assert-True ($styleFunction -notmatch 'FontName=Microsoft YaHei') '字幕样式不得继续写死微软雅黑'

$runBackupFunction = [regex]::Match($autoCutText, '(?s)function\s+Backup-Software\s*\([^)]*\)\s*\{.*?\n\}').Value
Assert-True ($runBackupFunction -match 'Subtitle-Core\.psm1') '每次运行的软件备份必须包含字幕核心模块'
Assert-True ($runBackupFunction -match 'Subtitle-Aliyun\.psm1') '每次运行的软件备份必须包含阿里云模块'
Assert-True ($runBackupFunction -match 'Subtitle-Settings\.ps1') '每次运行的软件备份必须包含字幕设置器'
Assert-True ($runBackupFunction -match 'Subtitle-Preview-Worker\.ps1') '每次运行的软件备份必须包含后台预览程序'
Assert-True ($runBackupFunction -notmatch 'aliyun-key\.dat') '每次运行的软件备份不得包含API Key'
Assert-True ($runBackupFunction -notmatch '\(Join-Path \$PSScriptRoot "fonts"\)') '运行时软件备份不得打包可能正被字幕预览占用的字体目录'

$releaseReport = [IO.File]::ReadAllText((Join-Path $root '发布验证报告.txt'), [Text.Encoding]::UTF8)
Assert-True ($releaseReport -match '(?m)^版本：20260712_final_review_fix\s*$') '发布验证报告必须标记本次最终审查修复版本'
Assert-True ($releaseReport -notmatch '(?i)\b[A-Z]:\\') '对外发布验证报告不得包含固定Windows盘符路径'

Write-Host 'PASS Test-Integration' -ForegroundColor Green
