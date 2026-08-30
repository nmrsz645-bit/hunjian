$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Test-Helpers.ps1"

$root = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $root 'AutoStart.ps1'
Assert-True (Test-Path -LiteralPath $scriptPath -PathType Leaf) 'AutoStart.ps1 must exist'

$description = & $scriptPath -Action Describe -Root $root | ConvertFrom-Json
Assert-Equal 'AutoCut-Monitor' $description.TaskName 'Only the AutoCut task may be managed'
Assert-Equal (Join-Path $root 'Auto-Monitor.ps1') $description.MonitorScript 'Task must target the current monitor script'
Assert-True ($description.Arguments -match '-WindowStyle Hidden') 'Startup must run hidden'
Assert-True ($description.Arguments -match '-ExecutionPolicy Bypass') 'Startup must bypass restrictive execution policy'
Assert-True ($description.DelaySeconds -eq 60) 'Startup delay must be 60 seconds'
Assert-True (-not ($description.Arguments -match 'aliyun-key|API Key|Bearer')) 'Task arguments must not contain API secrets'

$managerText = [IO.File]::ReadAllText((Join-Path $root 'AutoCut-Manager.ps1'), [Text.Encoding]::UTF8)
Assert-True ($managerText.Contains('Enable-AutoStart')) 'Manager must expose the enable action'
Assert-True ($managerText.Contains('Disable-AutoStart')) 'Manager must expose the disable action'
$monitorText = [IO.File]::ReadAllText((Join-Path $root 'Auto-Monitor.ps1'), [Text.Encoding]::UTF8)
Assert-True ($monitorText.Contains('Local\AutoCut-Monitor')) 'Monitor must use a cross-launch singleton lock'
Assert-True ($monitorText -match '\$videos\.Count\s*-lt\s*\$expectedCount') 'Audio success must accept a completed set that reaches the configured count'
Assert-True ($monitorText.Contains('Assert-CompletedOutputSet $audioToFinalize')) 'Monitor must recheck final output after a render error'
Assert-True ($monitorText.Contains('$finalOutputReady')) 'Monitor must track final output readiness before moving audio'
Assert-True ($monitorText.Contains('$sourceText = Get-SidecarTextPath $AudioPath')) 'Monitor must resolve the sidecar text before moving the audio'
Assert-True ($monitorText -match 'function\s+Move-SidecarText\(\$SourceTextPath') 'Sidecar text move must accept the captured text path'
Assert-True ($monitorText -match '(?s)try\s*\{\s*Copy-Item\s+-LiteralPath\s+\$sourceText.*?\}\s*catch\s*\{\s*Remove-Item\s+-LiteralPath\s+\$destText.*?Write-MonitorLog') 'Sidecar text sync failure must not fail the audio job'
foreach ($required in @('Get-RetryQueueAudioFiles', 'Save-RetryState', 'Test-RetryableFailure', '$RetryDelaysMinutes = @(5, 20, 60)', 'NextRetryAt')) {
    Assert-True ($monitorText.Contains($required)) "Monitor must keep retry state: $required"
}
foreach ($required in @('$files = @()', '$files += @(Get-RetryQueueAudioFiles)', '$files += @(Get-PendingAudioFiles)', 'Where-Object { $null -ne $_ }')) {
    Assert-True ($monitorText.Contains($required)) "Monitor must discard empty queue items: $required"
}
Assert-True (-not ($monitorText -match 'EnableFullDedup')) 'Monitor must not retain old full-dedup rules'

$autoCutText = [IO.File]::ReadAllText((Join-Path $root 'AutoCut.ps1'), [Text.Encoding]::UTF8)
Assert-True ($autoCutText.Contains('Test-SourceSegmentUnused')) 'Clip planning must prevent reused source seconds within one output'
Assert-True (-not ($autoCutText -match 'Dedup-Core|Get-DedupCandidate|DedupMinSourceGapSeconds')) 'Clip planning must not retain old dedup rules'
$dedupCompat = [IO.File]::ReadAllText((Join-Path $root 'Dedup-Core.psm1'), [Text.Encoding]::UTF8)
Assert-True ($dedupCompat -notmatch 'function|Export-ModuleMember|Import-Module') 'Dedup compatibility file must remain inert'

$launcherText = [IO.File]::ReadAllText((Join-Path $root 'Start-AutoCut.ps1'), [Text.Encoding]::UTF8)
<#
Assert-True ($launcherText.Contains('用户目录将保持不变')) 'Portable config repair must preserve user paths'
Assert-True (-not ($launcherText -match 'Set-PortableConfigValue \$text "VideoDir"')) 'Startup repair must not overwrite the video path'
Assert-True (-not ($launcherText -match 'Set-PortableConfigValue \$text "AudioDir"')) 'Startup repair must not overwrite the audio path'
Assert-True (-not ($launcherText -match 'Set-PortableConfigValue \$text "OutputDir"')) 'Startup repair must not overwrite the output path'
#>
Assert-True ($launcherText -match 'Repair-PortableConfig') 'Launcher must provide portable config repair'
$repairFunction = [regex]::Match($launcherText, '(?s)function\s+Repair-PortableConfig\s*\([^)]*\)\s*\{.*?\n\}').Value
Assert-True (-not ($repairFunction -match 'Set-PortableConfigValue\s+\$text\s+"VideoDir"')) 'Portable repair must not overwrite the video path'
Assert-True (-not ($repairFunction -match 'Set-PortableConfigValue\s+\$text\s+"AudioDir"')) 'Portable repair must not overwrite the audio path'
Assert-True (-not ($repairFunction -match 'Set-PortableConfigValue\s+\$text\s+"OutputDir"')) 'Portable repair must not overwrite the output path'

Write-Host 'PASS Test-AutoStart' -ForegroundColor Green
