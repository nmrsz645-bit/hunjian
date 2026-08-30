$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

function Remove-SubtitleLineBreaks {
    param([AllowEmptyString()][string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $clean = $Text -replace '[\r\n\t]', ''
    $clean = $clean -replace '\\[Nn]', ''
    return ($clean -replace ' {2,}', ' ').Trim()
}

function Remove-SubtitleDisplayPunctuation {
    param([AllowEmptyString()][string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    return [regex]::Replace($Text, '[\p{P}\p{S}]', '')
}

function Normalize-SubtitleText {
    param([AllowEmptyString()][string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    return ([regex]::Replace($Text, '[\p{P}\p{Z}\p{C}\s]+', '')).ToLowerInvariant()
}

function Get-TextBigrams {
    param([string]$Text)
    $normalized = Normalize-SubtitleText $Text
    if ($normalized.Length -lt 2) {
        if ($normalized.Length -eq 1) { return @($normalized) }
        return @()
    }
    $result = @()
    for ($i = 0; $i -lt $normalized.Length - 1; $i += 1) {
        $result += $normalized.Substring($i, 2)
    }
    return $result
}

function Get-TextSimilarity {
    param([string]$Left, [string]$Right)
    $a = Normalize-SubtitleText $Left
    $b = Normalize-SubtitleText $Right
    if ($a -eq $b) { return 1.0 }
    if ($a.Length -eq 0 -or $b.Length -eq 0) { return 0.0 }

    $leftPairs = @(Get-TextBigrams $a)
    $rightPairs = @(Get-TextBigrams $b)
    $counts = @{}
    foreach ($pair in $rightPairs) {
        if (-not $counts.ContainsKey($pair)) { $counts[$pair] = 0 }
        $counts[$pair] += 1
    }
    $matches = 0
    foreach ($pair in $leftPairs) {
        if ($counts.ContainsKey($pair) -and $counts[$pair] -gt 0) {
            $matches += 1
            $counts[$pair] -= 1
        }
    }
    return (2.0 * $matches / ($leftPairs.Count + $rightPairs.Count))
}

function New-SubtitleFont {
    param(
        [string]$FontName,
        [string]$FontFile,
        [float]$PixelSize
    )
    $collection = $null
    if (-not [string]::IsNullOrWhiteSpace($FontFile) -and (Test-Path -LiteralPath $FontFile -PathType Leaf)) {
        $collection = New-Object Drawing.Text.PrivateFontCollection
        $collection.AddFontFile($FontFile)
        if ($collection.Families.Count -gt 0) {
            return [pscustomobject]@{
                Font = New-Object Drawing.Font($collection.Families[0], $PixelSize, [Drawing.FontStyle]::Regular, [Drawing.GraphicsUnit]::Pixel)
                Collection = $collection
            }
        }
    }
    return [pscustomobject]@{
        Font = New-Object Drawing.Font($FontName, $PixelSize, [Drawing.FontStyle]::Regular, [Drawing.GraphicsUnit]::Pixel)
        Collection = $collection
    }
}

function Get-SubtitleTextWidth {
    param(
        [string]$Text,
        [string]$FontName,
        [string]$FontFile,
        [int]$FontSize,
        [int]$FrameWidth,
        [int]$FrameHeight,
        [int]$Outline,
        [int]$SafeWidthPercent,
        [int]$MaxChars
    )
    if ($FrameWidth -le 0 -or $FrameHeight -le 0) { return 0.0 }

    $bitmap = New-Object Drawing.Bitmap(4, 4)
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    $fontHolder = $null
    try {
        $pixelSize = [Math]::Max(8.0, $FontSize * $FrameHeight / 288.0)
        $fontHolder = New-SubtitleFont $FontName $FontFile $pixelSize
        $format = [Drawing.StringFormat]::GenericTypographic
        $size = $graphics.MeasureString($Text, $fontHolder.Font, 100000, $format)
        return ($size.Width + (2 * $Outline * $FrameHeight / 288.0))
    } finally {
        if ($fontHolder -and $fontHolder.Font) { $fontHolder.Font.Dispose() }
        if ($fontHolder -and $fontHolder.Collection) { $fontHolder.Collection.Dispose() }
        $graphics.Dispose()
        $bitmap.Dispose()
    }
}

function Get-SubtitleSafeWidth {
    param([int]$FrameWidth, [int]$SafeWidthPercent)
    if ($FrameWidth -le 0) { return [double]::PositiveInfinity }
    return ($FrameWidth * ([Math]::Min(95, [Math]::Max(50, $SafeWidthPercent)) / 100.0))
}

function Test-SubtitleTextFits {
    param(
        [string]$Text,
        [string]$FontName,
        [string]$FontFile,
        [int]$FontSize,
        [int]$FrameWidth,
        [int]$FrameHeight,
        [int]$Outline,
        [int]$SafeWidthPercent,
        [int]$MaxChars
    )
    if ($MaxChars -gt 0 -and (Normalize-SubtitleText $Text).Length -gt $MaxChars) { return $false }
    return ((Get-SubtitleTextWidth $Text $FontName $FontFile $FontSize $FrameWidth $FrameHeight $Outline $SafeWidthPercent $MaxChars) -le (Get-SubtitleSafeWidth $FrameWidth $SafeWidthPercent))
}

function Split-SubtitleText {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [string]$FontName = 'Microsoft YaHei',
        [string]$FontFile = '',
        [int]$FontSize = 16,
        [int]$FrameWidth = 1920,
        [int]$FrameHeight = 1080,
        [int]$Outline = 2,
        [int]$SafeWidthPercent = 84,
        [int]$MaxChars = 0,
        [int]$MinChars = 6,
        [switch]$SingleSentence,
        [switch]$SinglePhrase
    )
    $clean = Remove-SubtitleLineBreaks $Text
    if ([string]::IsNullOrWhiteSpace($clean)) { return @() }

    $units = @()
    $buffer = New-Object Text.StringBuilder
    foreach ($ch in $clean.ToCharArray()) {
        [void]$buffer.Append($ch)
        if ('。！？!?'.IndexOf($ch) -ge 0) {
            $units += $buffer.ToString()
            [void]$buffer.Clear()
        }
    }
    if ($buffer.Length -gt 0) { $units += $buffer.ToString() }

    if (-not $SingleSentence) {
        $sentenceEvents = New-Object Collections.ArrayList
        foreach ($unit in $units) {
            $eventsForSentence = @(Split-SubtitleText -Text $unit -FontName $FontName -FontFile $FontFile -FontSize $FontSize -FrameWidth $FrameWidth -FrameHeight $FrameHeight -Outline $Outline -SafeWidthPercent $SafeWidthPercent -MaxChars $MaxChars -MinChars $MinChars -SingleSentence)
            foreach ($event in $eventsForSentence) { [void]$sentenceEvents.Add($event) }
        }
        return @($sentenceEvents | ForEach-Object { [string]$_ })
    }

    if (-not $SinglePhrase) {
        $phraseUnits = @()
        $phraseBuffer = New-Object Text.StringBuilder
        foreach ($ch in $clean.ToCharArray()) {
            [void]$phraseBuffer.Append($ch)
            if ('，,；;'.IndexOf($ch) -ge 0) {
                $phraseUnits += $phraseBuffer.ToString()
                [void]$phraseBuffer.Clear()
            }
        }
        if ($phraseBuffer.Length -gt 0) { $phraseUnits += $phraseBuffer.ToString() }

        $renderPhrases = New-Object Collections.ArrayList
        for ($phraseIndex = 0; $phraseIndex -lt $phraseUnits.Count; $phraseIndex += 1) {
            $phrase = [string]$phraseUnits[$phraseIndex]
            if ((Normalize-SubtitleText $phrase).Length -lt 4 -and $phraseIndex + 1 -lt $phraseUnits.Count) {
                $phraseUnits[$phraseIndex + 1] = $phrase + [string]$phraseUnits[$phraseIndex + 1]
                continue
            }
            [void]$renderPhrases.Add($phrase)
        }

        $phraseEvents = New-Object Collections.ArrayList
        for ($renderIndex = 0; $renderIndex -lt $renderPhrases.Count; $renderIndex += 1) {
            $phrase = [string]$renderPhrases[$renderIndex]
            $displayPhrase = Remove-SubtitleDisplayPunctuation (Remove-SubtitleLineBreaks $phrase)
            $currentFits = Test-SubtitleTextFits $displayPhrase $FontName $FontFile $FontSize $FrameWidth $FrameHeight $Outline $SafeWidthPercent $MaxChars
            $fillRatio = if ($currentFits) {
                (Get-SubtitleTextWidth $displayPhrase $FontName $FontFile $FontSize $FrameWidth $FrameHeight $Outline $SafeWidthPercent $MaxChars) / (Get-SubtitleSafeWidth $FrameWidth $SafeWidthPercent)
            } else { 1.0 }
            if ($currentFits -and $fillRatio -lt 0.60 -and $renderIndex + 1 -lt $renderPhrases.Count) {
                $nextPhrase = [string]$renderPhrases[$renderIndex + 1]
                $displayNext = Remove-SubtitleDisplayPunctuation (Remove-SubtitleLineBreaks $nextPhrase)
                $sameLine = $displayPhrase + $displayNext
                if (Test-SubtitleTextFits $sameLine $FontName $FontFile $FontSize $FrameWidth $FrameHeight $Outline $SafeWidthPercent $MaxChars) {
                    [void]$phraseEvents.Add($sameLine)
                    $renderIndex += 1
                    continue
                }
                if ((Test-SubtitleTextFits $displayNext $FontName $FontFile $FontSize $FrameWidth $FrameHeight $Outline $SafeWidthPercent $MaxChars) -and
                    (Normalize-SubtitleText $displayNext).Length -le (Normalize-SubtitleText $displayPhrase).Length) {
                    [void]$phraseEvents.Add("$displayPhrase`n$displayNext")
                    $renderIndex += 1
                    continue
                }
            }
            $eventsForPhrase = @(Split-SubtitleText -Text ([string]$phrase) -FontName $FontName -FontFile $FontFile -FontSize $FontSize -FrameWidth $FrameWidth -FrameHeight $FrameHeight -Outline $Outline -SafeWidthPercent $SafeWidthPercent -MaxChars $MaxChars -MinChars $MinChars -SingleSentence -SinglePhrase)
            foreach ($event in $eventsForPhrase) { [void]$phraseEvents.Add($event) }
        }
        return @($phraseEvents | ForEach-Object { [string]$_ })
    }
    $units = @($clean)

    $chunks = New-Object Collections.ArrayList
    foreach ($unit in $units) {
        $remaining = $unit
        while ($remaining.Length -gt 0) {
            if (Test-SubtitleTextFits $remaining $FontName $FontFile $FontSize $FrameWidth $FrameHeight $Outline $SafeWidthPercent $MaxChars) {
                [void]$chunks.Add($remaining)
                break
            }
            $limit = if ($MaxChars -gt 0) { [Math]::Min($MaxChars, $remaining.Length - 1) } else { $remaining.Length - 1 }
            while ($limit -gt 1 -and -not (Test-SubtitleTextFits $remaining.Substring(0, $limit) $FontName $FontFile $FontSize $FrameWidth $FrameHeight $Outline $SafeWidthPercent $MaxChars)) {
                $limit -= 1
            }
            if ($limit -lt 1) { $limit = 1 }
            $tailLength = (Normalize-SubtitleText $remaining.Substring($limit)).Length
            $headLength = (Normalize-SubtitleText $remaining.Substring(0, $limit)).Length
            if ($tailLength -gt 0 -and $tailLength -lt $MinChars) {
                $shift = $MinChars - $tailLength
                if ($headLength - $shift -ge $MinChars -and $limit -gt $shift) {
                    $limit -= $shift
                }
            }
            [void]$chunks.Add($remaining.Substring(0, $limit))
            $remaining = $remaining.Substring($limit)
        }
    }

    $i = 0
    while ($i -lt $chunks.Count) {
        $length = (Normalize-SubtitleText ([string]$chunks[$i])).Length
        if ($length -ge $MinChars -or $length -ge 3 -or $chunks.Count -eq 1) {
            $i += 1
            continue
        }
        $merged = $false
        if ($i + 1 -lt $chunks.Count) {
            $candidate = [string]$chunks[$i] + [string]$chunks[$i + 1]
            if (Test-SubtitleTextFits $candidate $FontName $FontFile $FontSize $FrameWidth $FrameHeight $Outline $SafeWidthPercent $MaxChars) {
                $chunks[$i] = $candidate
                $chunks.RemoveAt($i + 1)
                $merged = $true
            }
        }
        if (-not $merged -and $i -gt 0) {
            $previous = [string]$chunks[$i - 1]
            $current = [string]$chunks[$i]
            for ($move = 1; $move -lt $previous.Length; $move += 1) {
                $candidatePrevious = $previous.Substring(0, $previous.Length - $move)
                $candidateCurrent = $previous.Substring($previous.Length - $move) + $current
                if ((Normalize-SubtitleText $candidatePrevious).Length -ge 3 -and
                    (Normalize-SubtitleText $candidateCurrent).Length -ge 3 -and
                    (Test-SubtitleTextFits $candidatePrevious $FontName $FontFile $FontSize $FrameWidth $FrameHeight $Outline $SafeWidthPercent $MaxChars) -and
                    (Test-SubtitleTextFits $candidateCurrent $FontName $FontFile $FontSize $FrameWidth $FrameHeight $Outline $SafeWidthPercent $MaxChars)) {
                    $chunks[$i - 1] = $candidatePrevious
                    $chunks[$i] = $candidateCurrent
                    $merged = $true
                    break
                }
            }
        }
        if (-not $merged -and $i + 1 -lt $chunks.Count) {
            $current = [string]$chunks[$i]
            $next = [string]$chunks[$i + 1]
            for ($move = 1; $move -lt $next.Length; $move += 1) {
                $candidateCurrent = $current + $next.Substring(0, $move)
                $candidateNext = $next.Substring($move)
                if ((Normalize-SubtitleText $candidateCurrent).Length -ge 3 -and
                    (Normalize-SubtitleText $candidateNext).Length -ge 3 -and
                    (Test-SubtitleTextFits $candidateCurrent $FontName $FontFile $FontSize $FrameWidth $FrameHeight $Outline $SafeWidthPercent $MaxChars) -and
                    (Test-SubtitleTextFits $candidateNext $FontName $FontFile $FontSize $FrameWidth $FrameHeight $Outline $SafeWidthPercent $MaxChars)) {
                    $chunks[$i] = $candidateCurrent
                    $chunks[$i + 1] = $candidateNext
                    $merged = $true
                    break
                }
            }
        }
        if (-not $merged -and $i -gt 0) {
            $candidate = [string]$chunks[$i - 1] + [string]$chunks[$i]
            if (Test-SubtitleTextFits $candidate $FontName $FontFile $FontSize $FrameWidth $FrameHeight $Outline $SafeWidthPercent $MaxChars) {
                $chunks[$i - 1] = $candidate
                $chunks.RemoveAt($i)
                $i = [Math]::Max(0, $i - 1)
                $merged = $true
            }
        }
        if (-not $merged) { $i += 1 }
    }
    $displayLines = @($chunks | ForEach-Object { Remove-SubtitleDisplayPunctuation (Remove-SubtitleLineBreaks ([string]$_)) } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $events = New-Object Collections.ArrayList
    for ($eventIndex = 0; $eventIndex -lt $displayLines.Count; $eventIndex += 2) {
        $firstLine = [string]$displayLines[$eventIndex]
        if ($eventIndex + 1 -lt $displayLines.Count) {
            [void]$events.Add("$firstLine`n$([string]$displayLines[$eventIndex + 1])")
        } else {
            [void]$events.Add($firstLine)
        }
    }
    return @($events | ForEach-Object { [string]$_ })
}

function Convert-SecondsToSrtTime {
    param([double]$Seconds)
    if ($Seconds -lt 0) { $Seconds = 0 }
    $milliseconds = [int64][Math]::Round($Seconds * 1000)
    $ts = [TimeSpan]::FromMilliseconds($milliseconds)
    return '{0:00}:{1:00}:{2:00},{3:000}' -f [int][Math]::Floor($ts.TotalHours), $ts.Minutes, $ts.Seconds, $ts.Milliseconds
}

function Convert-HexColorToAssInternal {
    param([string]$HexColor, [string]$Fallback)
    $hex = ('' + $HexColor).Trim().TrimStart('#')
    if ($hex -notmatch '^[0-9A-Fa-f]{6}$') { $hex = $Fallback }
    return '&H00{0}{1}{2}' -f $hex.Substring(4, 2), $hex.Substring(2, 2), $hex.Substring(0, 2)
}

function Get-SubtitleAssStyle {
    param(
        [string]$FontName = 'Microsoft YaHei',
        [int]$FontSize = 16,
        [string]$PrimaryColor = 'FFFFFF',
        [string]$OutlineColor = '000000',
        [int]$Outline = 2,
        [int]$MarginV = 30
    )
    $primary = Convert-HexColorToAssInternal $PrimaryColor 'FFFFFF'
    $outlineColorAss = Convert-HexColorToAssInternal $OutlineColor '000000'
    return "FontName=$FontName,FontSize=$FontSize,PrimaryColour=$primary,OutlineColour=$outlineColorAss,BorderStyle=1,Outline=$Outline,Shadow=0,Alignment=2,MarginV=$MarginV,WrapStyle=2"
}

function Get-TimeForCharacterPosition {
    param($Words, [double]$Position, [double]$TotalCharacters)
    if ($Words.Count -eq 0) { return 0.0 }
    if ($TotalCharacters -le 0) { return $Words[0].Start }
    foreach ($word in $Words) {
        if ($Position -le $word.EndCharacter) {
            $width = [Math]::Max(1.0, $word.EndCharacter - $word.StartCharacter)
            $ratio = [Math]::Min(1.0, [Math]::Max(0.0, ($Position - $word.StartCharacter) / $width))
            return $word.Start + (($word.End - $word.Start) * $ratio)
        }
    }
    return $Words[-1].End
}

function New-SegmentsForTimedText {
    param(
        [string]$Text,
        [double]$Start,
        [double]$End,
        [hashtable]$SplitOptions,
        [double]$MinimumDuration
    )
    $chunks = @(Split-SubtitleText -Text $Text @SplitOptions)
    if ($chunks.Count -eq 0) { return @() }
    $weights = @($chunks | ForEach-Object { [Math]::Max(1, (Normalize-SubtitleText $_).Length) })
    $total = ($weights | Measure-Object -Sum).Sum
    $cursor = $Start
    $consumedWeight = 0.0
    $result = @()
    for ($i = 0; $i -lt $chunks.Count; $i += 1) {
        $consumedWeight += $weights[$i]
        $chunkEnd = if ($i -eq $chunks.Count - 1) { $End } else { $Start + (($End - $Start) * $consumedWeight / $total) }
        $result += [pscustomobject]@{ Start = $cursor; End = $chunkEnd; Text = $chunks[$i] }
        $cursor = $chunkEnd
    }
    return $result
}

function Merge-ShortSubtitleSegments {
    param(
        [Parameter(Mandatory = $true)]$Segments,
        [hashtable]$SplitOptions = @{},
        [int]$MaximumNextCharacters = 5,
        [double]$MaximumJoinGapSeconds = 1.2
    )
    $result = New-Object Collections.ArrayList
    foreach ($segment in @($Segments)) {
        if ($null -eq $segment) { continue }
        if ($result.Count -eq 0) {
            [void]$result.Add($segment)
            continue
        }

        $nextText = Normalize-SubtitleText (Remove-SubtitleDisplayPunctuation (Remove-SubtitleLineBreaks ([string]$segment.Text)))
        $previous = $result[$result.Count - 1]
        $gap = [double]$segment.Start - [double]$previous.End
        if ($nextText.Length -ge $MaximumNextCharacters -or $gap -gt $MaximumJoinGapSeconds) {
            [void]$result.Add($segment)
            continue
        }

        $combinedText = (Remove-SubtitleLineBreaks ([string]$previous.Text)) + (Remove-SubtitleLineBreaks ([string]$segment.Text))
        $combinedChunks = @(Split-SubtitleText -Text $combinedText @SplitOptions)
        if ($combinedChunks.Count -ne 1) {
            [void]$result.Add($segment)
            continue
        }

        $result[$result.Count - 1] = [pscustomobject]@{
            Start = [double]$previous.Start
            End = [double]$segment.End
            Text = [string]$combinedChunks[0]
        }
    }
    return @($result)
}

function New-SegmentsFromAliyunWords {
    param(
        [Parameter(Mandatory = $true)]$Words,
        [hashtable]$SplitOptions = @{},
        [double]$MinimumDuration = 0.8,
        [int]$PauseBoundaryMilliseconds = 450
    )
    $result = New-Object Collections.ArrayList
    $current = @()
    $currentText = ''
    foreach ($word in @($Words)) {
        if (-not (Test-AliyunTimeRangeInternal $word '词语')) { continue }
        $rawText = [string]$word.text
        $displayText = Remove-SubtitleDisplayPunctuation $rawText
        if ([string]::IsNullOrWhiteSpace($displayText)) { continue }
        $gap = if ($current.Count -gt 0) { [double]$word.begin_time - [double]$current[-1].end_time } else { 0.0 }
        $candidate = $currentText + $displayText
        if ($current.Count -gt 0 -and ($gap -ge $PauseBoundaryMilliseconds -or -not (Test-SubtitleTextFits $candidate @SplitOptions))) {
            [void]$result.Add([pscustomobject]@{ Start = ([double]$current[0].begin_time / 1000.0); End = ([double]$current[-1].end_time / 1000.0); Text = (Remove-SubtitleDisplayPunctuation $currentText) })
            $current = @()
            $currentText = ''
        }
        $current += $word
        $currentText += $displayText
        $punctuation = if ($word.PSObject.Properties['punctuation']) { [string]$word.punctuation } else { '' }
        if (($rawText + $punctuation) -match '[。！？!?]$') {
            [void]$result.Add([pscustomobject]@{ Start = ([double]$current[0].begin_time / 1000.0); End = ([double]$current[-1].end_time / 1000.0); Text = (Remove-SubtitleDisplayPunctuation $currentText) })
            $current = @()
            $currentText = ''
        }
    }
    if ($current.Count -gt 0) {
        [void]$result.Add([pscustomobject]@{ Start = ([double]$current[0].begin_time / 1000.0); End = ([double]$current[-1].end_time / 1000.0); Text = (Remove-SubtitleDisplayPunctuation $currentText) })
    }
    return @(Merge-ShortSubtitleSegments -Segments @($result) -SplitOptions $SplitOptions)
}

function Assert-AliyunTimeRangeInternal {
    param($Item, [string]$Label, [double]$AudioDuration = [double]::PositiveInfinity)
    $beginProperty = $Item.PSObject.Properties['begin_time']
    $endProperty = $Item.PSObject.Properties['end_time']
    $begin = 0.0
    $end = 0.0
    $styles = [Globalization.NumberStyles]::Float
    $culture = [Globalization.CultureInfo]::InvariantCulture
    if (-not $beginProperty -or -not $endProperty -or
        -not [double]::TryParse([string]$beginProperty.Value, $styles, $culture, [ref]$begin) -or
        -not [double]::TryParse([string]$endProperty.Value, $styles, $culture, [ref]$end) -or
        [double]::IsNaN($begin) -or [double]::IsNaN($end) -or
        [double]::IsInfinity($begin) -or [double]::IsInfinity($end) -or
        $begin -lt 0 -or ($end - $begin) -lt 50.0) {
        throw "阿里云${Label}时间戳无效。"
    }
    if (-not [double]::IsPositiveInfinity($AudioDuration) -and
        ($begin -gt ($AudioDuration * 1000.0) -or $end -gt ($AudioDuration * 1000.0))) {
        throw "阿里云${Label}时间戳超出音频时长。"
    }
}

function Test-AliyunTimeRangeInternal {
    param($Item, [string]$Label, [double]$AudioDuration = [double]::PositiveInfinity)
    try {
        Assert-AliyunTimeRangeInternal $Item $Label $AudioDuration
        return $true
    } catch {
        return $false
    }
}

function Repair-AliyunTimedItemInternal {
    param($Item, [string]$Label, [double]$AudioDuration = [double]::PositiveInfinity)
    if ($null -eq $Item) { return $null }
    $beginProperty = $Item.PSObject.Properties['begin_time']
    $endProperty = $Item.PSObject.Properties['end_time']
    $begin = 0.0
    $end = 0.0
    $styles = [Globalization.NumberStyles]::Float
    $culture = [Globalization.CultureInfo]::InvariantCulture
    if (-not $beginProperty -or -not $endProperty -or
        -not [double]::TryParse([string]$beginProperty.Value, $styles, $culture, [ref]$begin) -or
        -not [double]::TryParse([string]$endProperty.Value, $styles, $culture, [ref]$end) -or
        [double]::IsNaN($begin) -or [double]::IsNaN($end) -or
        [double]::IsInfinity($begin) -or [double]::IsInfinity($end)) {
        return $null
    }

    $begin = [Math]::Max(0.0, $begin)
    $end = [Math]::Max(0.0, $end)
    if (-not [double]::IsPositiveInfinity($AudioDuration)) {
        $limit = [Math]::Max(0.0, $AudioDuration * 1000.0)
        $begin = [Math]::Min($begin, $limit)
        $end = [Math]::Min($end, $limit)
    }
    if (($end - $begin) -lt 50.0) { return $null }

    return [pscustomobject]@{
        begin_time = [int][Math]::Round($begin)
        end_time = [int][Math]::Round($end)
        text = if ($Item.PSObject.Properties['text']) { [string]$Item.text } else { '' }
        words = if ($Item.PSObject.Properties['words']) { @($Item.words) } else { @() }
    }
}

function Merge-ShortAliyunPauseSentences {
    param(
        [Parameter(Mandatory = $true)]$Sentences,
        [int]$MinimumCharacters = 4,
        [int]$MaximumJoinGapMilliseconds = 500
    )
    $result = @()
    $pending = $null
    foreach ($sentence in @($Sentences)) {
        if ($null -eq $pending) {
            $pending = $sentence
            continue
        }
        $pendingLength = (Normalize-SubtitleText ([string]$pending.text)).Length
        $gap = [int]$sentence.begin_time - [int]$pending.end_time
        if ($pendingLength -lt $MinimumCharacters -and $gap -le $MaximumJoinGapMilliseconds) {
            $pending = [pscustomobject]@{
                begin_time = $pending.begin_time
                end_time = $sentence.end_time
                text = ([string]$pending.text + [string]$sentence.text)
                words = @($pending.words) + @($sentence.words)
            }
            continue
        }
        $result += $pending
        $pending = $sentence
    }
    if ($null -ne $pending) { $result += $pending }
    return @($result)
}

function Convert-AliyunResultToSegments {
    param(
        [Parameter(Mandatory = $true)]$AliyunResult,
        [string]$PreferredText = '',
        [hashtable]$SplitOptions = @{},
        [double]$MinimumDuration = 0.8,
        [double]$SimilarityThreshold = 0.45,
        [double]$AudioDuration = [double]::PositiveInfinity
    )
    $transcripts = @($AliyunResult.transcripts)
    $sourceSentences = @($transcripts | ForEach-Object { @($_.sentences) })
    if ($sourceSentences.Count -eq 0) { throw '阿里云识别结果中没有句子时间轴。' }
    $sentences = @()
    foreach ($sentence in $sourceSentences) {
        $repairedSentence = Repair-AliyunTimedItemInternal $sentence '句子' $AudioDuration
        if ($null -eq $repairedSentence) { continue }
        $validWords = @()
        foreach ($word in @($sentence.words)) {
            $repairedWord = Repair-AliyunTimedItemInternal $word '词语' $AudioDuration
            if ($null -ne $repairedWord) { $validWords += $repairedWord }
        }
        $sentences += [pscustomobject]@{
            begin_time = $repairedSentence.begin_time
            end_time = $repairedSentence.end_time
            text = $repairedSentence.text
            words = $validWords
        }
    }
    if ($sentences.Count -eq 0) { throw '阿里云识别结果没有有效句子时间戳。' }
    $asrText = ($sentences.Text) -join ''

    $preferredNormalized = Normalize-SubtitleText $PreferredText
    $asrNormalized = Normalize-SubtitleText $asrText
    $lengthRatio = if ([Math]::Max($preferredNormalized.Length, $asrNormalized.Length) -gt 0) {
        [Math]::Min($preferredNormalized.Length, $asrNormalized.Length) / [double][Math]::Max($preferredNormalized.Length, $asrNormalized.Length)
    } else { 0.0 }
    $usePreferred = -not [string]::IsNullOrWhiteSpace($PreferredText) -and $lengthRatio -ge 0.55 -and (Get-TextSimilarity $PreferredText $asrText) -ge $SimilarityThreshold

    if (-not $usePreferred) {
        $fallback = @()
        foreach ($sentence in @(Merge-ShortAliyunPauseSentences -Sentences $sentences)) {
            if (@($sentence.words).Count -gt 0) {
                $fallback += @(New-SegmentsFromAliyunWords -Words $sentence.words -SplitOptions $SplitOptions -MinimumDuration $MinimumDuration)
            } else {
                $fallback += @(New-SegmentsForTimedText -Text ([string]$sentence.text) -Start ($sentence.begin_time / 1000.0) -End ($sentence.end_time / 1000.0) -SplitOptions $SplitOptions -MinimumDuration $MinimumDuration)
            }
        }
        return @(Merge-ShortSubtitleSegments -Segments $fallback -SplitOptions $SplitOptions)
    }

    $wordTimeline = @()
    $characterCursor = 0.0
    foreach ($sentence in $sentences) {
        $sentenceWords = @($sentence.words)
        if ($sentenceWords.Count -eq 0) {
            $sentenceWords = @([pscustomobject]@{ begin_time = $sentence.begin_time; end_time = $sentence.end_time; text = $sentence.text })
        }
        foreach ($word in $sentenceWords) {
            $length = [Math]::Max(1, (Normalize-SubtitleText ([string]$word.text)).Length)
            $wordTimeline += [pscustomobject]@{
                StartCharacter = $characterCursor
                EndCharacter = $characterCursor + $length
                Start = $word.begin_time / 1000.0
                End = $word.end_time / 1000.0
            }
            $characterCursor += $length
        }
    }

    $chunks = @(Split-SubtitleText -Text $PreferredText @SplitOptions)
    $chunkLengths = @($chunks | ForEach-Object { [Math]::Max(1, (Normalize-SubtitleText $_).Length) })
    $totalPreferred = ($chunkLengths | Measure-Object -Sum).Sum
    $preferredCursor = 0.0
    $segments = @()
    for ($i = 0; $i -lt $chunks.Count; $i += 1) {
        $startPosition = if ($totalPreferred -gt 0) { $characterCursor * $preferredCursor / $totalPreferred } else { 0 }
        $preferredCursor += $chunkLengths[$i]
        $endPosition = if ($totalPreferred -gt 0) { $characterCursor * $preferredCursor / $totalPreferred } else { $characterCursor }
        $startTime = Get-TimeForCharacterPosition $wordTimeline $startPosition $characterCursor
        $endTime = Get-TimeForCharacterPosition $wordTimeline $endPosition $characterCursor
        if ($endTime -le $startTime) { $endTime = $startTime + 0.05 }
        $segments += [pscustomobject]@{ Start = $startTime; End = $endTime; Text = $chunks[$i] }
    }
    return @(Merge-ShortSubtitleSegments -Segments $segments -SplitOptions $SplitOptions)
}

function Convert-SrtTimeToSecondsInternal {
    param([string]$Value)
    $match = [regex]::Match($Value, '^\s*(\d{2}):(\d{2}):(\d{2})[,.](\d{3})\s*$')
    if (-not $match.Success) { throw "无效的SRT时间：$Value" }
    return ([int]$match.Groups[1].Value * 3600) + ([int]$match.Groups[2].Value * 60) + [int]$match.Groups[3].Value + ([int]$match.Groups[4].Value / 1000.0)
}

function Convert-SrtToSegments {
    param(
        [Parameter(Mandatory = $true)][string]$SrtPath,
        [string]$PreferredText = '',
        [hashtable]$SplitOptions = @{},
        [double]$MinimumDuration = 0.8,
        [double]$SimilarityThreshold = 0.45,
        [switch]$PreserveEvents
    )
    if (-not (Test-Path -LiteralPath $SrtPath -PathType Leaf)) { throw "SRT文件不存在：$SrtPath" }
    $raw = [IO.File]::ReadAllText($SrtPath, [Text.Encoding]::UTF8)
    $sentences = @()
    foreach ($block in [regex]::Split($raw.Trim(), '(\r?\n){2,}')) {
        if ([string]::IsNullOrWhiteSpace($block)) { continue }
        $lines = @($block -split '\r?\n')
        if ($lines.Count -lt 3 -or ($PreserveEvents -and ($lines.Count -lt 3 -or $lines.Count -gt 4))) {
            if ($PreserveEvents) { throw 'SRT字幕块必须包含且仅包含一行文本。' }
            continue
        }
        $timeMatch = [regex]::Match($lines[1], '^\s*(.+?)\s*-->\s*(.+?)\s*$')
        if (-not $timeMatch.Success) {
            if ($PreserveEvents) { throw 'SRT字幕块时间格式无效。' }
            continue
        }
        $text = (($lines | Select-Object -Skip 2) -join "`n")
        $sentences += [pscustomobject]@{
            begin_time = [int][Math]::Round((Convert-SrtTimeToSecondsInternal $timeMatch.Groups[1].Value) * 1000)
            end_time = [int][Math]::Round((Convert-SrtTimeToSecondsInternal $timeMatch.Groups[2].Value) * 1000)
            text = $text
            words = @()
        }
    }
    if ($sentences.Count -eq 0) { throw 'SRT文件中没有有效字幕。' }
    if ($PreserveEvents) {
        return @($sentences | ForEach-Object {
            [pscustomobject]@{
                Start = $_.begin_time / 1000.0
                End = $_.end_time / 1000.0
                Text = $_.text
            }
        })
    }
    $pseudoResult = [pscustomobject]@{
        transcripts = @([pscustomobject]@{
            text = ($sentences.Text -join '')
            sentences = $sentences
        })
    }
    return @(Convert-AliyunResultToSegments -AliyunResult $pseudoResult -PreferredText $PreferredText -SplitOptions $SplitOptions -MinimumDuration $MinimumDuration -SimilarityThreshold $SimilarityThreshold)
}

function New-SrtFromSegments {
    param(
        [Parameter(Mandatory = $true)]$Segments,
        [Parameter(Mandatory = $true)][string]$Destination
    )
    $blocks = @()
    $index = 1
    foreach ($segment in @($Segments)) {
        $text = ([string]$segment.Text -replace '\[Nn]', '' -replace "`r`n?", "`n" -replace "`t", '')
        $textLines = @($text -split "`n" | ForEach-Object { (Remove-SubtitleLineBreaks $_) } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($textLines.Count -gt 2) { throw '单条字幕最多只能显示两行。' }
        $text = $textLines -join "`r`n"
        if ([string]::IsNullOrWhiteSpace($text)) { continue }
        $blocks += ("{0}`r`n{1} --> {2}`r`n{3}" -f $index, (Convert-SecondsToSrtTime $segment.Start), (Convert-SecondsToSrtTime $segment.End), $text)
        $index += 1
    }
    [IO.File]::WriteAllText($Destination, ($blocks -join "`r`n`r`n"), [Text.UTF8Encoding]::new($true))
}

function Test-SubtitleSegments {
    param(
        [AllowEmptyCollection()][AllowNull()]$Segments,
        [hashtable]$SplitOptions = @{}
    )
    $items = @($Segments)
    if ($items.Count -eq 0) {
        return [pscustomobject]@{ Success = $false; Message = '字幕不能为空。' }
    }

    $options = @{
        FontName = 'Microsoft YaHei'
        FontFile = ''
        FontSize = 16
        FrameWidth = 1920
        FrameHeight = 1080
        Outline = 2
        SafeWidthPercent = 84
        MaxChars = 0
        MaxLines = 2
    }
    foreach ($key in @($options.Keys)) {
        if ($SplitOptions.ContainsKey($key) -and $null -ne $SplitOptions[$key]) {
            $options[$key] = $SplitOptions[$key]
        }
    }

    $previousStart = $null
    $previousEnd = $null
    foreach ($segment in $items) {
        $text = [string]$segment.Text
        if ([string]::IsNullOrWhiteSpace($text)) {
            return [pscustomobject]@{ Success = $false; Message = '字幕文本不能为空。' }
        }
        if ($text -match '\t|\\[Nn]') {
            return [pscustomobject]@{ Success = $false; Message = '字幕不能包含制表符或ASS换行标记。' }
        }
        $textLines = @($text -split "`r?`n")
        if ($textLines.Count -gt [int]$options.MaxLines -or $textLines.Count -eq 0 -or ($textLines | Where-Object { [string]::IsNullOrWhiteSpace($_) })) {
            return [pscustomobject]@{ Success = $false; Message = '字幕最多只能显示两行，且每行不能为空。' }
        }

        $start = 0.0
        $end = 0.0
        $numberStyles = [Globalization.NumberStyles]::Float
        $culture = [Globalization.CultureInfo]::InvariantCulture
        if (-not [double]::TryParse([string]$segment.Start, $numberStyles, $culture, [ref]$start) -or
            -not [double]::TryParse([string]$segment.End, $numberStyles, $culture, [ref]$end)) {
            return [pscustomobject]@{ Success = $false; Message = '字幕时间必须是数字。' }
        }
        if ([double]::IsNaN($start) -or [double]::IsNaN($end) -or [double]::IsInfinity($start) -or [double]::IsInfinity($end)) {
            return [pscustomobject]@{ Success = $false; Message = '字幕时间必须是有效数字。' }
        }
        if ($end -le $start) {
            return [pscustomobject]@{ Success = $false; Message = '字幕时长必须为正数。' }
        }
        if ($null -ne $previousStart -and $start -lt $previousStart) {
            return [pscustomobject]@{ Success = $false; Message = '字幕时间不能倒序。' }
        }
        if ($null -ne $previousEnd -and $start -lt $previousEnd) {
            return [pscustomobject]@{ Success = $false; Message = '字幕时间段不能重叠。' }
        }
        if ($textLines | Where-Object { -not (Test-SubtitleTextFits $_ $options.FontName $options.FontFile $options.FontSize $options.FrameWidth $options.FrameHeight $options.Outline $options.SafeWidthPercent $options.MaxChars) }) {
            return [pscustomobject]@{ Success = $false; Message = '字幕超过安全像素宽度。' }
        }
        $previousStart = $start
        $previousEnd = $end
    }
    return [pscustomobject]@{ Success = $true; Message = '' }
}

function Limit-SubtitleSegments {
    param(
        [Parameter(Mandatory = $true)]$Segments,
        [Parameter(Mandatory = $true)][double]$Duration
    )
    $result = @()
    foreach ($segment in @($Segments | Sort-Object Start)) {
        $start = [Math]::Max(0.0, [double]$segment.Start)
        if ($start -ge $Duration) { continue }
        $end = [Math]::Min($Duration, [double]$segment.End)
        if ($end -le $start) { continue }
        $result += [pscustomobject]@{ Start = $start; End = $end; Text = [string]$segment.Text }
    }
    return $result
}

function Repair-SubtitleSegments {
    param(
        [AllowEmptyCollection()][AllowNull()]$Segments,
        [Parameter(Mandatory = $true)][double]$Duration,
        [hashtable]$SplitOptions = @{}
    )
    $result = New-Object Collections.ArrayList
    $previousEnd = 0.0
    foreach ($segment in @($Segments | Sort-Object { [double]$_.Start })) {
        if ($null -eq $segment) { continue }
        $text = Remove-SubtitleDisplayPunctuation ([string]$segment.Text)
        if ([string]::IsNullOrWhiteSpace($text)) { continue }
        $start = [Math]::Max(0.0, [double]$segment.Start)
        $end = [Math]::Min($Duration, [double]$segment.End)
        $start = [Math]::Max($start, $previousEnd)
        if ($end -le $start) { continue }

        $chunks = @(Split-SubtitleText -Text $text @SplitOptions)
        if ($chunks.Count -eq 0) { continue }
        $lengths = @($chunks | ForEach-Object { [Math]::Max(1, (Normalize-SubtitleText $_).Length) })
        $totalLength = [double](($lengths | Measure-Object -Sum).Sum)
        $cursor = $start
        for ($i = 0; $i -lt $chunks.Count; $i += 1) {
            $portion = $lengths[$i] / $totalLength
            $chunkEnd = if ($i -eq ($chunks.Count - 1)) { $end } else { $cursor + (($end - $start) * $portion) }
            if ($chunkEnd -le $cursor) { continue }
            [void]$result.Add([pscustomobject]@{ Start = $cursor; End = $chunkEnd; Text = $chunks[$i] })
            $previousEnd = $chunkEnd
            $cursor = $chunkEnd
        }
    }
    return @($result)
}

Export-ModuleMember -Function @(
    'Remove-SubtitleLineBreaks',
    'Remove-SubtitleDisplayPunctuation',
    'Normalize-SubtitleText',
    'Get-TextSimilarity',
    'Split-SubtitleText',
    'Merge-ShortSubtitleSegments',
    'New-SegmentsFromAliyunWords',
    'Convert-SecondsToSrtTime',
    'Convert-AliyunResultToSegments',
    'Convert-SrtToSegments',
    'New-SrtFromSegments',
    'Test-SubtitleSegments',
    'Limit-SubtitleSegments',
    'Repair-SubtitleSegments',
    'Get-SubtitleAssStyle'
)
