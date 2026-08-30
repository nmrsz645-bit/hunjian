$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$sourcePath = Join-Path $root 'AutoCut.ps1'
$source = [IO.File]::ReadAllText($sourcePath, [Text.Encoding]::UTF8)
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$errors)
if ($errors.Count -gt 0) { throw "AutoCut.ps1 parse failed: $($errors[0].Message)" }

function Get-FunctionText([string]$Name) {
    $fn = $ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name }, $true) | Select-Object -First 1
    if (-not $fn) { throw "Missing function: $Name" }
    return $fn.Extent.Text
}

Import-Module (Join-Path $root 'Subtitle-Core.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $root 'Segment-Usage.psm1') -Force -DisableNameChecking
Invoke-Expression (Get-FunctionText 'Get-NonOverlappingClipStart')
Invoke-Expression (Get-FunctionText 'Get-RenderJobTimeoutSeconds')
Invoke-Expression (Get-FunctionText 'Get-RenderChunks')
Invoke-Expression (Get-FunctionText 'Write-RenderChunkSubtitle')
Invoke-Expression (Get-FunctionText 'Merge-ParaformerChunkSrt')

$random = New-Object Random 20260831
$longSource = [pscustomobject]@{ FullName = 'C:\素材\long.mp4'; Name = 'long.mp4' }
$longPlan = @()
$longRemaining = 905.0
while ($longRemaining -gt 0.05) {
    $takeSeconds = [Math]::Min(30.0, $longRemaining)
    $start = Get-NonOverlappingClipStart $longSource.FullName 905.0 $takeSeconds $longPlan
    if ($null -eq $start) { throw 'A single long source must retain enough contiguous capacity for the final clip.' }
    if (-not (Test-SourceSegmentUnused $longSource.FullName $start $takeSeconds $longPlan)) { throw 'Long-source clip plan must not reuse source seconds.' }
    $longPlan += [pscustomobject]@{ Source = $longSource; Start = $start; Duration = $takeSeconds }
    $longRemaining -= $takeSeconds
}
if ($longPlan.Count -ne 31 -or [Math]::Abs((($longPlan | Measure-Object Duration -Sum).Sum) - 905.0) -gt 0.001) { throw 'Long-source clip plan must cover the full audio duration without random-fragmentation failure.' }
if ((Get-RenderJobTimeoutSeconds 60) -ne 1800) { throw 'Short render jobs must have a 30-minute total timeout floor.' }
if ((Get-RenderJobTimeoutSeconds 3600) -ne 11400) { throw 'One-hour render jobs must have a duration-aware total timeout.' }
if ((Get-RenderJobTimeoutSeconds 999999) -ne 43200) { throw 'Render job timeout must have a 12-hour ceiling.' }

$clips = 1..50 | ForEach-Object { [pscustomobject]@{ Duration = 10; Source = "clip$_" } }
$chunks = @(Get-RenderChunks $clips 24)
if ($chunks.Count -ne 3) { throw "Expected 3 render chunks, got $($chunks.Count)." }
if (@($chunks | ForEach-Object { $_.Clips.Count }) -join ',' -ne '24,24,2') { throw 'Render chunk sizes are incorrect.' }
if (($chunks | Select-Object -Last 1).Offset -ne 480) { throw 'Render chunk offset must equal all prior clip durations.' }

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('long_audio_render_' + [guid]::NewGuid().ToString('N'))
try {
    [IO.Directory]::CreateDirectory($tempRoot) | Out-Null
    $sourceSrt = Join-Path $tempRoot 'source.srt'
    $chunkSrt = Join-Path $tempRoot 'chunk.srt'
    [IO.File]::WriteAllText($sourceSrt, "1`r`n00:00:05,000 --> 00:00:15,000`r`n第一句`r`n`r`n2`r`n00:00:20,000 --> 00:00:30,000`r`n第二句`r`n`r`n3`r`n00:00:35,000 --> 00:00:45,000`r`n第三句`r`n", [Text.UTF8Encoding]::new($true))
    if (-not (Write-RenderChunkSubtitle $sourceSrt $chunkSrt 10 30)) { throw 'Expected overlapping subtitles for render chunk.' }
    $chunkText = [IO.File]::ReadAllText($chunkSrt, [Text.Encoding]::UTF8)
    if ($chunkText -notmatch '00:00:00,000 --> 00:00:05,000' -or $chunkText -notmatch '00:00:25,000 --> 00:00:30,000') { throw 'Chunk subtitles must be clipped and shifted to local time.' }
    if (Write-RenderChunkSubtitle $sourceSrt (Join-Path $tempRoot 'empty.srt') 60 10) { throw 'Silent chunk must not create subtitle filter input.' }

    $firstChunk = Join-Path $tempRoot 'asr_001.srt'
    $secondChunk = Join-Path $tempRoot 'asr_002.srt'
    $mergedSrt = Join-Path $tempRoot 'asr_merged.srt'
    [IO.File]::WriteAllText($firstChunk, "1`r`n00:00:58,000 --> 00:01:01,000`r`n边界字幕`r`n", [Text.UTF8Encoding]::new($true))
    [IO.File]::WriteAllText($secondChunk, "1`r`n00:00:00,000 --> 00:00:03,000`r`n边界字幕`r`n", [Text.UTF8Encoding]::new($true))
    Merge-ParaformerChunkSrt @(
        [pscustomobject]@{ Srt = $firstChunk; Start = 0; KeepStart = 0; KeepEnd = 60 },
        [pscustomobject]@{ Srt = $secondChunk; Start = 59; KeepStart = 60; KeepEnd = 120 }
    ) $mergedSrt
    $mergedText = [IO.File]::ReadAllText($mergedSrt, [Text.Encoding]::UTF8)
    if (($mergedText -split '边界字幕').Count -ne 3) { throw 'Timeline chunk overlap must not duplicate a boundary subtitle.' }
    if ($mergedText -notmatch '00:00:58,000 --> 00:01:00,000') { throw 'Timeline chunk overlap must clip the first boundary subtitle at 60 seconds.' }
} finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

foreach ($expected in @('if ($Clips.Count -gt 24)', 'Invoke-ChunkedSinglePassRender', '长音频分段渲染', '每块最多 24 个素材', 'Get-NonOverlappingClipStart', 'Get-RenderJobTimeoutSeconds', 'Stop-Job -Job $job')) {
    if (-not $source.Contains($expected)) { throw "Missing long-audio rendering protection: $expected" }
}
$config = [IO.File]::ReadAllText((Join-Path $root 'config.ps1'), [Text.Encoding]::UTF8)
foreach ($expected in @('ParaformerTimelineChunkSeconds = 60', 'ParaformerTimelineChunkOverlapSeconds = 1')) {
    if (-not $config.Contains($expected)) { throw "Missing Paraformer timeline configuration: $expected" }
}
foreach ($expected in @('Invoke-ChunkedParaformerSrt', 'Invoke-ParaformerBatch', 'Merge-ParaformerChunkSrt', 'timeline_chunks_v1')) {
    if (-not $source.Contains($expected)) { throw "Missing timeline-safe Paraformer protection: $expected" }
}
$worker = [IO.File]::ReadAllText((Join-Path $root 'tools\paraformer\paraformer_worker.py'), [Text.Encoding]::UTF8)
foreach ($expected in @('GPU_BATCH_SIZES = (60, 30, 15)', 'PARAFORMER_CUDA_OOM', 'GPU memory insufficient', '--batch-manifest', 'write_subtitles')) {
    if (-not $worker.Contains($expected)) { throw "Missing Paraformer GPU fallback protection: $expected" }
}

Write-Output 'PASS Test-LongAudio-Rendering'
