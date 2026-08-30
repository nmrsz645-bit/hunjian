$ErrorActionPreference = 'Stop'

& "$PSScriptRoot\Test-Subtitle-Core.ps1"
& "$PSScriptRoot\Test-Subtitle-Aliyun.ps1"
& "$PSScriptRoot\Test-Integration.ps1"
& "$PSScriptRoot\Test-Subtitle-UI.ps1"
& "$PSScriptRoot\Test-Paraformer-SharedRead.ps1"
& "$PSScriptRoot\Test-Paraformer-Offline.ps1"
& "$PSScriptRoot\Test-Paraformer-Invocation.ps1"
& "$PSScriptRoot\Test-Paraformer-SingleLoad.ps1"
& "$PSScriptRoot\Test-LongAudio-Rendering.ps1"
& "$PSScriptRoot\Test-Monitor-Retry.ps1"
& "$PSScriptRoot\Test-DesktopConfig.ps1"
& "$PSScriptRoot\Test-Handover.ps1"
& "$PSScriptRoot\Test-Log-Retention.ps1"
& "$PSScriptRoot\Test-MediaInfoUnicode.ps1"
& "$PSScriptRoot\Test-Maintenance.ps1"
& "$PSScriptRoot\Test-SelfCheck.ps1"
& "$PSScriptRoot\Test-AutoStart.ps1"
& "$PSScriptRoot\Test-Image-Materials.ps1"
& "$PSScriptRoot\Test-Segment-Usage.ps1"

Write-Host 'ALL TESTS PASSED' -ForegroundColor Green
