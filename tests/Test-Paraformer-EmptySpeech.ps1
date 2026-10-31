$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$python = (Get-Command python.exe -ErrorAction Stop).Source
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('paraformer-empty-speech-' + [guid]::NewGuid().ToString('N'))

try {
    [IO.Directory]::CreateDirectory($tempRoot) | Out-Null
    $testPath = Join-Path $tempRoot 'test_worker_empty_speech.py'
    $workerPath = Join-Path $root 'tools\paraformer\paraformer_worker.py'
    $testSource = @'
import importlib.util
import json
import sys
import tempfile
import types
from pathlib import Path

worker_path = Path(sys.argv[1])
torch = types.ModuleType("torch")
torch.cuda = types.SimpleNamespace(is_available=lambda: False, empty_cache=lambda: None)
sys.modules["torch"] = torch
funasr = types.ModuleType("funasr")
funasr.AutoModel = object
sys.modules["funasr"] = funasr

spec = importlib.util.spec_from_file_location("paraformer_worker_under_test", worker_path)
worker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(worker)

with tempfile.TemporaryDirectory() as temp_dir:
    temp = Path(temp_dir)
    empty_srt = temp / "empty_sentence_info.srt"
    empty_json = temp / "empty_sentence_info.json"
    worker.write_subtitles([{"sentence_info": []}], "empty.wav", empty_srt, empty_json)
    assert empty_srt.exists(), "No-speech output must create an empty SRT."
    assert empty_srt.read_text(encoding="utf-8") == "", "No-speech SRT must remain empty."
    assert json.loads(empty_json.read_text(encoding="utf-8"))["sentence_info"] == []

    blank_srt = temp / "blank_text.srt"
    blank_json = temp / "blank_text.json"
    worker.write_subtitles([{"sentence_info": [{"text": "", "start": 0, "end": 100}]}], "blank.wav", blank_srt, blank_json)
    assert blank_srt.exists(), "Blank recognized text must create an empty SRT."
    assert blank_srt.read_text(encoding="utf-8") == "", "Blank-text SRT must remain empty."
    assert json.loads(blank_json.read_text(encoding="utf-8"))["sentence_info"][0]["text"] == ""

    spoken_srt = temp / "spoken.srt"
    spoken_json = temp / "spoken.json"
    worker.write_subtitles([{"sentence_info": [{"text": "测试字幕", "start": 0, "end": 1000}]}], "spoken.wav", spoken_srt, spoken_json)
    assert "测试字幕" in spoken_srt.read_text(encoding="utf-8"), "Recognized speech must remain in SRT output."

print("PASS Test-Paraformer-EmptySpeech")
'@
    [IO.File]::WriteAllText($testPath, $testSource, [Text.UTF8Encoding]::new($false))
    & $python $testPath $workerPath
    if ($LASTEXITCODE -ne 0) { throw "Empty-speech worker regression test failed with exit code $LASTEXITCODE." }
} finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$sourcePath = Join-Path $root 'AutoCut.ps1'
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseInput([IO.File]::ReadAllText($sourcePath, [Text.Encoding]::UTF8), [ref]$tokens, [ref]$errors)
if ($errors.Count -gt 0) { throw "AutoCut.ps1 parse failed: $($errors[0].Message)" }
$mergeFunction = $ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Merge-ParaformerChunkSrt' }, $true) | Select-Object -First 1
if (-not $mergeFunction) { throw 'Missing Merge-ParaformerChunkSrt.' }
Import-Module (Join-Path $root 'Subtitle-Core.psm1') -Force -DisableNameChecking
Invoke-Expression $mergeFunction.Extent.Text

$mergeRoot = Join-Path ([IO.Path]::GetTempPath()) ('paraformer-all-silent-' + [guid]::NewGuid().ToString('N'))
try {
    [IO.Directory]::CreateDirectory($mergeRoot) | Out-Null
    $silentChunk = Join-Path $mergeRoot 'silent.srt'
    $mergedSrt = Join-Path $mergeRoot 'merged.srt'
    [IO.File]::WriteAllText($silentChunk, '', [Text.UTF8Encoding]::new($false))
    $mergeResult = @(Merge-ParaformerChunkSrt @([pscustomobject]@{ Srt = $silentChunk; Start = 0; KeepStart = 0; KeepEnd = 1 }) $mergedSrt)
    if ($mergeResult.Count -ne 1 -or $mergeResult[0] -ne $false) { throw 'All-silent chunks must return false rather than fail.' }
    if (-not (Test-Path -LiteralPath $mergedSrt -PathType Leaf)) { throw 'All-silent chunks must create an empty merged SRT.' }
    if ([IO.File]::ReadAllText($mergedSrt, [Text.Encoding]::UTF8) -ne '') { throw 'All-silent merged SRT must remain empty.' }
} finally {
    Remove-Item -LiteralPath $mergeRoot -Recurse -Force -ErrorAction SilentlyContinue
}
