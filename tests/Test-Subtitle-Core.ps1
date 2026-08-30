$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Test-Helpers.ps1"

$modulePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'Subtitle-Core.psm1'
Assert-True (Test-Path -LiteralPath $modulePath -PathType Leaf) 'Subtitle-Core.psm1 必须存在'
Import-Module $modulePath -Force -DisableNameChecking

foreach ($name in @(
    'Remove-SubtitleLineBreaks',
    'Normalize-SubtitleText',
    'Get-TextSimilarity',
    'Split-SubtitleText',
    'Merge-ShortSubtitleSegments',
    'New-SegmentsFromAliyunWords',
    'Convert-SecondsToSrtTime',
    'Convert-AliyunResultToSegments',
    'Convert-SrtToSegments',
    'Limit-SubtitleSegments',
    'New-SrtFromSegments',
    'Test-SubtitleSegments',
    'Get-SubtitleAssStyle'
)) {
    Assert-True ($null -ne (Get-Command $name -ErrorAction SilentlyContinue)) "必须导出函数 $name"
}

Assert-Equal '甲乙丙丁 多' (Remove-SubtitleLineBreaks " 甲`r`n乙`t\N丙\n丁  多 ") '字幕清洗应删除换行、制表符和ASS换行标记并压缩普通空格'
Assert-Equal '' (Remove-SubtitleLineBreaks '') '空字幕清洗结果应为空'

Assert-Equal '你好World123' (Normalize-SubtitleText ' 你，好！ WORLD 123 ') '文字归一化应删除标点空格并统一英文大小写'
Assert-True ((Get-TextSimilarity '大考事件收尾即时七天' '大考事件收尾即时7天') -gt 0.65) '相近中文内容应有较高相似度'
Assert-True ((Get-TextSimilarity '完全不同的内容' '今天学校放假') -lt 0.35) '无关内容应有较低相似度'

$splitOptions = @{
    FontName = 'Microsoft YaHei'
    FontSize = 16
    FrameWidth = 1080
    FrameHeight = 1920
    Outline = 2
    SafeWidthPercent = 85
    MaxChars = 8
    MinChars = 4
}
$chunks = @(Split-SubtitleText -Text '这是第一句话，这是第二句话，最后一句结束。' @splitOptions)
Assert-True ($chunks.Count -ge 2) '长文案应拆成多条字幕事件'
Assert-True (-not (@($chunks | ForEach-Object { $_ -split "`r?`n" }) | Where-Object { $_.Length -gt 8 })) '每个视觉字幕行不得超过字数硬上限'
Assert-True (-not ($chunks | Where-Object { $_.Length -le 2 })) '正常连续文案不得出现一两个字的孤立字幕'
Assert-Equal '这是第一句话这是第二句话最后一句结束' (($chunks -join '') -replace "`r?`n", '') '拆分后应保留文字顺序并移除显示标点'
Assert-True (-not ($chunks | Where-Object { (@($_ -split "`r?`n")).Count -gt 2 })) '每条字幕事件最多只能显示两行'

$tailOptions = $splitOptions.Clone()
$tailOptions.FontSize = 8
$tailOptions.MaxChars = 26
$tailOptions.MinChars = 6
$tailChunks = @(Split-SubtitleText -Text ('喔' * 27) @tailOptions)
Assert-True (-not ($tailChunks | Where-Object { (Normalize-SubtitleText $_).Length -lt 6 })) '超长连续文字的最后一条也不得只剩一两个字'
Assert-Equal 27 (($tailChunks | ForEach-Object { (Normalize-SubtitleText $_).Length } | Measure-Object -Sum).Sum) '尾部重排不得丢字'

$longEnglish = @(Split-SubtitleText -Text ('A' * 70) -FontName 'Microsoft YaHei' -FontSize 8 -FrameWidth 1080 -FrameHeight 1920 -Outline 2 -SafeWidthPercent 84 -MinChars 6)
Assert-True ($longEnglish.Count -gt 1) '长英文应拆成多条字幕'
Assert-True (-not ($longEnglish | Where-Object { (@($_ -split "`r?`n")).Count -gt 2 -or $_ -match '\\[Nn]' })) '长英文拆分结果最多只能显示两行'
Assert-True (-not ($longEnglish | Where-Object { (Normalize-SubtitleText $_).Length -lt 6 })) '长英文不得产生一两个字的孤立尾字幕'
Assert-Equal 70 (($longEnglish | ForEach-Object { (Normalize-SubtitleText $_).Length } | Measure-Object -Sum).Sum) '长英文拆分不得丢字'

$longUnpunctuated = @(Split-SubtitleText -Text ('连续无标点字幕' * 12) -FontName 'Microsoft YaHei' -FontSize 8 -FrameWidth 1080 -FrameHeight 1920 -Outline 2 -SafeWidthPercent 84 -MinChars 6)
Assert-True ($longUnpunctuated.Count -gt 1) '连续无标点文本应拆成多条字幕'
Assert-True (-not ($longUnpunctuated | Where-Object { (@($_ -split "`r?`n")).Count -gt 2 -or $_ -match '\\[Nn]' })) '连续无标点拆分结果最多只能显示两行'
Assert-Equal 84 (($longUnpunctuated | ForEach-Object { (Normalize-SubtitleText $_).Length } | Measure-Object -Sum).Sum) '连续无标点拆分不得丢字'

$punctuationOptions = $splitOptions.Clone()
$punctuationOptions.MaxChars = 5
$punctuationOptions.MinChars = 6
$punctuationChunks = @(Split-SubtitleText -Text 'Hello. OK' @punctuationOptions)
Assert-True (-not ($punctuationChunks | Where-Object { (Normalize-SubtitleText $_).Length -lt 3 })) '标点单元边界不得产生一两个字的短尾字幕'
Assert-Equal 'Hello OK' (($punctuationChunks -join '') -replace "`r?`n", '') '标点边界重排后应保留文字顺序并移除显示标点'

$cleanedChunks = @(Split-SubtitleText -Text " 甲`r`n乙`t\N丙\n丁  多 " @splitOptions)
Assert-Equal '甲乙丙丁 多' (($cleanedChunks -join '') -replace "`r?`n", '') 'Split-SubtitleText必须统一使用字幕清洗函数'

$noPunctuationChunks = @(Split-SubtitleText -Text '李怀，是不是只要我原谅你？' @splitOptions)
Assert-Equal '李怀是不是只要我原谅你' (($noPunctuationChunks -join '') -replace "`r?`n", '') '最终显示字幕必须移除中文和英文标点符号'
Assert-True (-not (($noPunctuationChunks -join '') -match '[\p{P}]')) '最终显示字幕不得保留可见标点符号'

$twoLineOptions = @{
    FontName = 'Microsoft YaHei'
    FontSize = 16
    FrameWidth = 1080
    FrameHeight = 1920
    Outline = 2
    SafeWidthPercent = 85
    MaxChars = 16
    MinChars = 4
}
$twoLineChunks = @(Split-SubtitleText -Text '被接回相府的第一天就撞破病娇爹在' @twoLineOptions)
Assert-Equal 1 $twoLineChunks.Count '可容纳两行的完整语义段必须作为一个字幕事件显示'
Assert-True ($twoLineChunks[0] -match "`n") '长语义段必须使用两行排版'
Assert-Equal '被接回相府的第一天就撞破病娇爹在' (($twoLineChunks[0] -replace "`r?`n", '')) '两行排版不得丢字或改序'

$sentenceChunks = @(Split-SubtitleText -Text '第一句话说完。第二句话再显示。' @twoLineOptions)
Assert-Equal 2 $sentenceChunks.Count '两句完整语音不得合并为同一条字幕事件'
Assert-True (-not ($sentenceChunks | Where-Object { $_ -match "第一句话.*`n.*第二句话" })) '下一句字幕不得在上一句结束前提前显示'
Assert-True (-not ($sentenceChunks | Where-Object {
    $lines = @($_ -split "`r?`n")
    $lines.Count -eq 2 -and $lines[1].Length -gt $lines[0].Length
})) '两行字幕的第二行字数不得超过第一行'

$validSegments = @([pscustomobject]@{ Start = 0.0; End = 1.0; Text = '正常字幕' })
$validCheck = Test-SubtitleSegments -Segments $validSegments -SplitOptions $splitOptions
Assert-True $validCheck.Success '有效字幕段应通过校验'
Assert-True ($validCheck.PSObject.Properties.Name -contains 'Message') '字幕段校验结果必须包含Message'

$emptyCheck = Test-SubtitleSegments -Segments @() -SplitOptions $splitOptions
Assert-True (-not $emptyCheck.Success) '空字幕应校验失败'
Assert-True (-not [string]::IsNullOrWhiteSpace($emptyCheck.Message)) '空字幕失败时应返回原因'
$nullCheck = Test-SubtitleSegments -Segments $null -SplitOptions $splitOptions
Assert-True (-not $nullCheck.Success) '空值字幕应校验失败'

$lineBreakCheck = Test-SubtitleSegments -Segments @([pscustomobject]@{ Start = 0.0; End = 1.0; Text = '第一\N第二' }) -SplitOptions $splitOptions
Assert-True (-not $lineBreakCheck.Success) '包含换行标记的字幕应校验失败'

$reverseCheck = Test-SubtitleSegments -Segments @(
    [pscustomobject]@{ Start = 2.0; End = 3.0; Text = '后一句' },
    [pscustomobject]@{ Start = 1.0; End = 2.0; Text = '前一句' }
) -SplitOptions $splitOptions
Assert-True (-not $reverseCheck.Success) '时间倒序字幕应校验失败'

$durationCheck = Test-SubtitleSegments -Segments @([pscustomobject]@{ Start = 1.0; End = 1.0; Text = '无时长' }) -SplitOptions $splitOptions
Assert-True (-not $durationCheck.Success) '非正时长字幕应校验失败'

$invalidStartThrew = $false
$invalidStartCheck = $null
try {
    $invalidStartCheck = Test-SubtitleSegments -Segments @([pscustomobject]@{ Start = 'not-a-number'; End = 1.0; Text = '非法开始时间' }) -SplitOptions $splitOptions
} catch {
    $invalidStartThrew = $true
}
Assert-True (-not $invalidStartThrew) '非数值Start不得让字幕校验抛异常'
Assert-True (-not $invalidStartCheck.Success) '非数值Start应返回Success=false'

$invalidEndThrew = $false
$invalidEndCheck = $null
try {
    $invalidEndCheck = Test-SubtitleSegments -Segments @([pscustomobject]@{ Start = 0.0; End = 'not-a-number'; Text = '非法结束时间' }) -SplitOptions $splitOptions
} catch {
    $invalidEndThrew = $true
}
Assert-True (-not $invalidEndThrew) '非数值End不得让字幕校验抛异常'
Assert-True (-not $invalidEndCheck.Success) '非数值End应返回Success=false'

$overlapCheck = Test-SubtitleSegments -Segments @(
    [pscustomobject]@{ Start = 0.0; End = 2.0; Text = '前一条' },
    [pscustomobject]@{ Start = 1.0; End = 3.0; Text = '重叠条' }
) -SplitOptions $splitOptions
Assert-True (-not $overlapCheck.Success) '时间段重叠应校验失败'

$tooWideCheck = Test-SubtitleSegments -Segments @([pscustomobject]@{ Start = 0.0; End = 1.0; Text = ('W' * 40) }) -SplitOptions @{
    FontName = 'Microsoft YaHei'
    FontSize = 32
    FrameWidth = 240
    FrameHeight = 1920
    Outline = 2
    SafeWidthPercent = 84
    MaxChars = 0
    MinChars = 1
}
Assert-True (-not $tooWideCheck.Success) '超过安全像素宽度的字幕应校验失败'

$aliyunResult = [pscustomobject]@{
    transcripts = @(
        [pscustomobject]@{
            text = '大考事件收尾即时七天学校广播在大科坚时突然想起'
            sentences = @(
                [pscustomobject]@{
                    begin_time = 100
                    end_time = 2200
                    text = '大考事件收尾即时七天'
                    words = @(
                        [pscustomobject]@{ begin_time = 100; end_time = 900; text = '大考事件' },
                        [pscustomobject]@{ begin_time = 900; end_time = 1500; text = '收尾即时' },
                        [pscustomobject]@{ begin_time = 1500; end_time = 2200; text = '七天' }
                    )
                },
                [pscustomobject]@{
                    begin_time = 2600
                    end_time = 5200
                    text = '学校广播在大科坚时突然想起'
                    words = @(
                        [pscustomobject]@{ begin_time = 2600; end_time = 3500; text = '学校广播' },
                        [pscustomobject]@{ begin_time = 3500; end_time = 4300; text = '在大科坚时' },
                        [pscustomobject]@{ begin_time = 4300; end_time = 5200; text = '突然想起' }
                    )
                }
            )
        }
    )
}

$invalidTimelineCases = @(
    @{ Name = '缺少开始时间'; Sentence = [pscustomobject]@{ end_time = 1000; text = '测试'; words = @() } },
    @{ Name = '非数值时间'; Sentence = [pscustomobject]@{ begin_time = 'abc'; end_time = 1000; text = '测试'; words = @() } },
    @{ Name = 'NaN时间'; Sentence = [pscustomobject]@{ begin_time = [double]::NaN; end_time = 1000; text = '测试'; words = @() } },
    @{ Name = '无限时间'; Sentence = [pscustomobject]@{ begin_time = 0; end_time = [double]::PositiveInfinity; text = '测试'; words = @() } },
    @{ Name = '倒序时间'; Sentence = [pscustomobject]@{ begin_time = 1000; end_time = 500; text = '测试'; words = @() } },
    @{ Name = '实质空时间'; Sentence = [pscustomobject]@{ begin_time = 1000; end_time = 1010; text = '测试'; words = @() } }
)
foreach ($case in $invalidTimelineCases) {
    $invalidResult = [pscustomobject]@{
        transcripts = @([pscustomobject]@{ text = '测试'; sentences = @($case.Sentence) })
    }
    $timelineMessage = $null
    try {
        Convert-AliyunResultToSegments -AliyunResult $invalidResult -SplitOptions $splitOptions | Out-Null
    } catch {
        $timelineMessage = $_.Exception.Message
    }
    Assert-True ($timelineMessage -match '时间戳') "阿里云$($case.Name)必须在规范化前拒绝"
}

$invalidWordResult = [pscustomobject]@{
    transcripts = @([pscustomobject]@{
        text = '测试文字'
        sentences = @([pscustomobject]@{
            begin_time = 100
            end_time = 1000
            text = '测试文字'
            words = @([pscustomobject]@{ begin_time = 500; end_time = 500; text = '测试文字' })
        })
    })
}
$invalidWordSegments = $null
try {
    $invalidWordSegments = @(Convert-AliyunResultToSegments -AliyunResult $invalidWordResult -PreferredText '测试文字' -SplitOptions $splitOptions)
} catch {
    throw "词级时间戳异常不应中断整条字幕：$($_.Exception.Message)"
}
Assert-True ($invalidWordSegments.Count -gt 0) '阿里云词级实质空时间戳应回退到句子时间继续生成字幕'
Assert-Equal '测试文字' (Normalize-SubtitleText ($invalidWordSegments.Text -join '')) '词级回退不得丢失句子文字'

$outsideSentenceResult = [pscustomobject]@{
    transcripts = @([pscustomobject]@{
        text = '越界句子'
        sentences = @([pscustomobject]@{ begin_time = 100; end_time = 1200; text = '越界句子'; words = @() })
    })
}
$outsideSentenceSegments = @(Convert-AliyunResultToSegments -AliyunResult $outsideSentenceResult -AudioDuration 1.0 -SplitOptions $splitOptions)
Assert-True ($outsideSentenceSegments.Count -gt 0) '阿里云原始句子时间戳轻微越界时应裁正并继续生成字幕'
Assert-True ($outsideSentenceSegments[-1].End -le 1.0) '阿里云原始句子时间戳裁正后不得超出音频时长'

$outsideWordResult = [pscustomobject]@{
    transcripts = @([pscustomobject]@{
        text = '越界词语'
        sentences = @([pscustomobject]@{
            begin_time = 0
            end_time = 1000
            text = '越界词语'
            words = @([pscustomobject]@{ begin_time = 500; end_time = 1100; text = '越界词语' })
        })
    })
}
$outsideWordSegments = $null
try {
    $outsideWordSegments = @(Convert-AliyunResultToSegments -AliyunResult $outsideWordResult -AudioDuration 1.0 -PreferredText '越界词语' -SplitOptions $splitOptions)
} catch {
    throw "词级越界时间不应中断整条字幕：$($_.Exception.Message)"
}
Assert-True ($outsideWordSegments.Count -gt 0) '阿里云原始词级越界时间应回退到句子时间继续生成字幕'

$boundaryResult = [pscustomobject]@{
    transcripts = @([pscustomobject]@{
        text = '边界有效'
        sentences = @([pscustomobject]@{ begin_time = 0; end_time = 1000; text = '边界有效'; words = @() })
    })
}
$boundarySegments = @(Convert-AliyunResultToSegments -AliyunResult $boundaryResult -AudioDuration 1.0 -SplitOptions $splitOptions)
Assert-True ($boundarySegments.Count -gt 0) '结束时间等于音频时长的阿里云句子必须有效'

$shortSplitOptions = $splitOptions.Clone()
$shortSplitOptions.FontSize = 8
$shortSplitOptions.MaxChars = 1
$shortSplitOptions.MinChars = 1
$shortSentenceResult = [pscustomobject]@{
    transcripts = @([pscustomobject]@{
        text = '甲乙丙丁'
        sentences = @([pscustomobject]@{ begin_time = 1600; end_time = 2480; text = '甲乙丙丁'; words = @() })
    })
}
$shortSegments = @(Convert-AliyunResultToSegments `
    -AliyunResult $shortSentenceResult `
    -AudioDuration 3.0 `
    -SplitOptions $shortSplitOptions `
    -MinimumDuration 0.8)
Assert-True ($shortSegments.Count -gt 1) '真实短句必须产生多个字幕片段以覆盖回拨重叠场景'
Assert-Equal '甲乙丙丁' (($shortSegments.Text -join '') -replace "`r?`n", '') '短句多拆分必须保持原始文字顺序'
Assert-True ([Math]::Abs($shortSegments[0].Start - 1.6) -lt 0.001) '短句第一片必须从原始句子开始时间开始'
Assert-True ([Math]::Abs($shortSegments[-1].End - 2.48) -lt 0.001) '短句最后一片必须在原始句子结束时间结束'
for ($i = 0; $i -lt $shortSegments.Count; $i += 1) {
    Assert-True ($shortSegments[$i].End -gt $shortSegments[$i].Start) '短句拆分后的每个片段必须保持正时长'
    if ($i -gt 0) {
        Assert-True ($shortSegments[$i].Start -ge $shortSegments[$i - 1].End) '时间不足MinimumDuration时不得回拨cursor或产生重叠'
        Assert-True ($shortSegments[$i].Start -ge $shortSegments[$i - 1].Start) '短句拆分时间必须严格保序'
    }
}

$preferred = '大考事件收尾即时7天，学校广播在大课间时突然想起。'
$segments = @(Convert-AliyunResultToSegments -AliyunResult $aliyunResult -PreferredText $preferred -SplitOptions $splitOptions -MinimumDuration 0.8 -SimilarityThreshold 0.45)
Assert-True ($segments.Count -ge 2) '阿里云结果应转换为多条时间字幕'
Assert-Equal (Normalize-SubtitleText $preferred) (Normalize-SubtitleText (($segments.Text) -join '')) '匹配通过时最终文字必须来自TXT'
Assert-True ($segments[0].Start -ge 0.1) '字幕开始时间应使用语音时间轴'
Assert-True ($segments[-1].End -le 5.2) '字幕结束时间不得超过识别时间轴'
for ($i = 1; $i -lt $segments.Count; $i += 1) {
    Assert-True ($segments[$i].Start -ge $segments[$i - 1].Start) '字幕时间必须单调递增'
}

$fallback = @(Convert-AliyunResultToSegments -AliyunResult $aliyunResult -PreferredText '今天天气和识别内容完全无关' -SplitOptions $splitOptions -MinimumDuration 0.8 -SimilarityThreshold 0.45)
Assert-Equal (Normalize-SubtitleText $aliyunResult.transcripts[0].text) (Normalize-SubtitleText (($fallback.Text) -join '')) '文稿严重不一致时必须回退阿里云文字'
Assert-Equal 0.1 $fallback[0].Start '无文本稿首条字幕必须锚定首词开始时间'
Assert-Equal 5.2 $fallback[-1].End '无文本稿末条字幕必须锚定末词结束时间，不能按全文比例累计漂移'

$semanticPauseResult = [pscustomobject]@{
    transcripts = @([pscustomobject]@{
        text = '沈清之犹豫了一会还是把手松开了纪怀是不是只要我和江雨白离婚你就会原谅我了'
        sentences = @(
            [pscustomobject]@{ begin_time = 0; end_time = 900; text = '沈清之犹豫了一会'; words = @() },
            [pscustomobject]@{ begin_time = 1050; end_time = 1900; text = '还是把手松开了'; words = @() },
            [pscustomobject]@{ begin_time = 2050; end_time = 3400; text = '纪怀是不是只要我和江雨白离婚'; words = @() },
            [pscustomobject]@{ begin_time = 3550; end_time = 4400; text = '你就会原谅我了'; words = @() }
        )
    })
}
$semanticFallback = @(Convert-AliyunResultToSegments -AliyunResult $semanticPauseResult -SplitOptions $twoLineOptions -MinimumDuration 0.8)
Assert-Equal 4 $semanticFallback.Count '阿里云语义短停顿必须一段对应一条字幕事件'
Assert-Equal '沈清之犹豫了一会' (($semanticFallback[0].Text) -replace "`r?`n", '') '第一条字幕必须完整保留语义短句'
Assert-Equal '你就会原谅我了' (($semanticFallback[-1].Text) -replace "`r?`n", '') '最后一条字幕必须在短句结束后切换'
for ($i = 0; $i -lt $semanticFallback.Count; $i += 1) {
    Assert-True ([Math]::Abs($semanticFallback[$i].Start - ($semanticPauseResult.transcripts[0].sentences[$i].begin_time / 1000.0)) -lt 0.001) '字幕必须从对应语义短停顿的语音开始时刻出现'
    Assert-True ([Math]::Abs($semanticFallback[$i].End - ($semanticPauseResult.transcripts[0].sentences[$i].end_time / 1000.0)) -lt 0.001) '字幕必须在对应语义短停顿的语音结束后切换'
}

$brokenShortPauseResult = [pscustomobject]@{
    transcripts = @([pscustomobject]@{
        text = '沈清之犹豫了一会'
        sentences = @(
            [pscustomobject]@{ begin_time = 0; end_time = 300; text = '沈清之'; words = @() },
            [pscustomobject]@{ begin_time = 300; end_time = 900; text = '犹豫了一会'; words = @() }
        )
    })
}
$shortPauseFallback = @(Convert-AliyunResultToSegments -AliyunResult $brokenShortPauseResult -SplitOptions $twoLineOptions -MinimumDuration 0.8)
Assert-Equal 1 $shortPauseFallback.Count '过短的阿里云停顿片段必须与下一段合并，不能一句话没说完就切换'
Assert-Equal '沈清之犹豫了一会' (($shortPauseFallback[0].Text) -replace "`r?`n", '') '合并后的字幕必须覆盖完整语义短句'
Assert-True ([Math]::Abs($shortPauseFallback[0].Start - 0.0) -lt 0.001 -and [Math]::Abs($shortPauseFallback[0].End - 0.9) -lt 0.001) '合并后的字幕时间必须覆盖完整短句语音'

$punctuatedSentenceResult = [pscustomobject]@{
    transcripts = @([pscustomobject]@{
        text = '沈清之犹豫了一会，还是把手松开了。'
        sentences = @([pscustomobject]@{ begin_time = 80; end_time = 2480; text = '沈清之犹豫了一会，还是把手松开了。'; words = @() })
    })
}
$punctuatedFallback = @(Convert-AliyunResultToSegments -AliyunResult $punctuatedSentenceResult -SplitOptions $twoLineOptions -MinimumDuration 0.8)
Assert-Equal 2 $punctuatedFallback.Count '逗号两侧的完整语义短句必须分别显示为字幕事件'
Assert-Equal '沈清之犹豫了一会' (($punctuatedFallback[0].Text) -replace "`r?`n", '') '逗号前的语义短句必须完整显示'
Assert-Equal '还是把手松开了' (($punctuatedFallback[1].Text) -replace "`r?`n", '') '逗号后的语义短句必须完整显示'

$fillWidthChunks = @(Split-SubtitleText -Text '今天很好，转身就走。' @twoLineOptions)
Assert-Equal 1 $fillWidthChunks.Count '不足安全宽度六成的相邻语义短句应优先合并以填满画面'
Assert-Equal '今天很好转身就走' (($fillWidthChunks[0]) -replace "`r?`n", '') '填宽合并不得丢字或改变顺序'

$singleLineFirstOptions = $twoLineOptions.Clone()
$singleLineFirstOptions.MaxChars = 8
$singleLineFirst = @(Split-SubtitleText -Text '沈清之犹豫，还是把手松开。' @singleLineFirstOptions)
Assert-True (-not ($singleLineFirst | Where-Object { $_ -match "`n" })) '两个可独立单行显示的短句不得为了合并而强制两行'
Assert-Equal '沈清之犹豫还是把手松开' (($singleLineFirst -join '') -replace "`r?`n", '') '单行优先不得丢字或改变顺序'

$wordTimeline = @(
    [pscustomobject]@{ begin_time = 0; end_time = 300; text = '沈清之' },
    [pscustomobject]@{ begin_time = 300; end_time = 700; text = '犹豫了一会' },
    [pscustomobject]@{ begin_time = 1300; end_time = 1700; text = '还是把手' },
    [pscustomobject]@{ begin_time = 1700; end_time = 2100; text = '松开了。' },
    [pscustomobject]@{ begin_time = 2400; end_time = 2900; text = '转身就走' },
    [pscustomobject]@{ begin_time = 2900; end_time = 3400; text = '不再回头。' }
)
$wordTimedSegments = @(New-SegmentsFromAliyunWords -Words $wordTimeline -SplitOptions $twoLineOptions -MinimumDuration 0.1)
Assert-Equal 0.0 $wordTimedSegments[0].Start '词级字幕必须锚定首词开始时间'
Assert-Equal 3.4 $wordTimedSegments[-1].End '词级字幕必须锚定末词结束时间，不能累积漂移'
Assert-True ($wordTimedSegments.Count -ge 3) '词间超过450毫秒停顿时必须切换字幕'
Assert-True (-not ($wordTimedSegments | Where-Object { $_.End -le $_.Start })) '每条词级字幕必须有正时长'

$shortNextSegments = @(
    [pscustomobject]@{ Start = 0.0; End = 1.0; Text = '我没有说话' },
    [pscustomobject]@{ Start = 1.1; End = 1.7; Text = '转身走' }
)
$shortNextMerged = @(Merge-ShortSubtitleSegments -Segments $shortNextSegments -SplitOptions $twoLineOptions)
Assert-Equal 1 $shortNextMerged.Count '下一句少于五个字且没有明显停顿时应合并到上一句'
Assert-Equal '我没有说话转身走' (($shortNextMerged[0].Text) -replace "`r?`n", '') '短句合并不得丢字或改序'
Assert-Equal 1.7 $shortNextMerged[0].End '短句合并后结束时间必须延伸到下一句结束'

$longPauseShortNext = @(
    [pscustomobject]@{ Start = 0.0; End = 1.0; Text = '我没有说话' },
    [pscustomobject]@{ Start = 2.4; End = 3.0; Text = '转身走' }
)
Assert-Equal 2 (@(Merge-ShortSubtitleSegments -Segments $longPauseShortNext -SplitOptions $twoLineOptions)).Count '明显停顿后的短句不得跨停顿合并'

$tempSrt = Join-Path $env:TEMP ("autocut_core_test_{0}.srt" -f ([guid]::NewGuid().ToString('N')))
try {
    New-SrtFromSegments -Segments $segments -Destination $tempSrt
    $srt = [IO.File]::ReadAllText($tempSrt, [Text.Encoding]::UTF8)
    Assert-True ($srt -match '00:00:00,100 -->') 'SRT应使用标准毫秒时间格式'
    Assert-True ($srt.Contains("`r`n")) 'SRT必须包含真实换行符'
    Assert-True (-not $srt.Contains('`r`n')) 'SRT不得把换行符写成可见字符'
    New-SrtFromSegments -Segments @([pscustomobject]@{ Start = 0.0; End = 1.0; Text = "第一行字幕`n第二行字幕" }) -Destination $tempSrt
    $dirtySrt = [IO.File]::ReadAllText($tempSrt, [Text.Encoding]::UTF8)
    Assert-True ($dirtySrt -match "第一行字幕`r?`n第二行字幕") 'SRT输出必须保留同一字幕事件的两行排版'
    Assert-True ($dirtySrt -notmatch '\\[Nn]') 'SRT输出不得保留ASS换行标记'
} finally {
    Remove-Item -LiteralPath $tempSrt -Force -ErrorAction SilentlyContinue
}

$style = Get-SubtitleAssStyle -FontName 'Microsoft YaHei' -FontSize 16 -PrimaryColor 'FFFFFF' -OutlineColor '000000' -Outline 2 -MarginV 30
Assert-True ($style -match 'FontName=Microsoft YaHei') 'ASS样式应使用所选字体'
Assert-True ($style -match 'WrapStyle=2') 'ASS样式必须禁止自动换行'
Assert-True ($style -match 'MarginV=30') 'ASS样式应使用当前方向位置'
Assert-Equal '01:01:01,250' (Convert-SecondsToSrtTime 3661.25) 'SRT时间转换应正确'
Assert-Equal '00:30:01,060' (Convert-SecondsToSrtTime 1801.06) 'SRT时间转换在30分钟后不得把小时数四舍五入为1'

$tempWhisperSrt = Join-Path $env:TEMP ("autocut_whisper_align_{0}.srt" -f ([guid]::NewGuid().ToString('N')))
try {
    $whisperSrtText = "1`r`n00:00:00,100 --> 00:00:02,200`r`n大考事件收尾即时七天`r`n`r`n2`r`n00:00:02,600 --> 00:00:05,200`r`n学校广播在大科坚时突然想起"
    [IO.File]::WriteAllText($tempWhisperSrt, $whisperSrtText, [Text.UTF8Encoding]::new($true))
    $whisperAligned = @(Convert-SrtToSegments -SrtPath $tempWhisperSrt -PreferredText $preferred -SplitOptions $splitOptions -MinimumDuration 0.8 -SimilarityThreshold 0.45)
    Assert-Equal (Normalize-SubtitleText $preferred) (Normalize-SubtitleText (($whisperAligned.Text) -join '')) 'Whisper回退时仍应优先使用匹配的TXT文字'
Assert-True ($whisperAligned[-1].End -le 5.2) 'Whisper对齐不得越过原SRT时间轴'
} finally {
    Remove-Item -LiteralPath $tempWhisperSrt -Force -ErrorAction SilentlyContinue
}

$overrunSegments = @(
    [pscustomobject]@{ Start = 0.0; End = 8.0; Text = '第一条字幕' },
    [pscustomobject]@{ Start = 8.0; End = 30.0; Text = '第二条字幕' },
    [pscustomobject]@{ Start = 30.0; End = 31.0; Text = '越界字幕' }
)
$limited = @(Limit-SubtitleSegments -Segments $overrunSegments -Duration 10.0)
Assert-Equal 2 $limited.Count '开始时间超过音频长度的字幕必须删除'
Assert-Equal 10.0 $limited[-1].End '字幕结束时间必须裁到音频长度'

$repaired = @(Repair-SubtitleSegments -Segments @(
    [pscustomobject]@{ Start = -1.0; End = 1.0; Text = '第一条字幕' },
    [pscustomobject]@{ Start = 0.8; End = 4.0; Text = ('很长的字幕' * 8) },
    [pscustomobject]@{ Start = 5.0; End = 5.0; Text = '无效字幕' }
) -Duration 3.0 -SplitOptions $splitOptions)
Assert-True ($repaired.Count -gt 1) '字幕修复应保留可用片段并按安全宽度拆分'
Assert-True (-not ($repaired | Where-Object { $_.Start -lt 0 -or $_.End -gt 3.0 -or $_.End -le $_.Start })) '字幕修复后时间必须在音频范围内且为正时长'
Assert-True ((Test-SubtitleSegments -Segments $repaired -SplitOptions $splitOptions).Success) '字幕修复后每条字幕必须在安全宽度内'

Write-Host 'PASS Test-Subtitle-Core' -ForegroundColor Green
