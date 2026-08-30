param(
    [ValidateSet('Describe', 'Status', 'Enable', 'Disable')]
    [string]$Action = 'Status',
    [string]$Root = $PSScriptRoot
)

$ErrorActionPreference = 'Stop'
$TaskName = 'AutoCut-Monitor'
$DelaySeconds = 60
$MonitorScript = Join-Path $Root 'Auto-Monitor.ps1'
$PowerShellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

function Get-AutoStartDescription {
    if (-not (Test-Path -LiteralPath $MonitorScript -PathType Leaf)) { throw "Monitor script not found: $MonitorScript" }
    $arguments = '-NoLogo -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f $MonitorScript
    return [pscustomobject]@{
        TaskName = $TaskName
        DelaySeconds = $DelaySeconds
        MonitorScript = $MonitorScript
        PowerShellExe = $PowerShellExe
        Arguments = $arguments
    }
}

function Test-AutoStartTask {
    & schtasks.exe /Query /TN $TaskName /FO LIST 2>$null | Out-Null
    return ($LASTEXITCODE -eq 0)
}

switch ($Action) {
    'Describe' { Get-AutoStartDescription | ConvertTo-Json -Compress; exit 0 }
    'Status' {
        if (Test-AutoStartTask) { Write-Output 'Enabled: monitor starts 60 seconds after user logon.'; exit 0 }
        Write-Output 'Disabled.'; exit 0
    }
    'Enable' {
        $description = Get-AutoStartDescription
        $taskCommand = '"{0}" {1}' -f $description.PowerShellExe, $description.Arguments
        & schtasks.exe /Create /TN $description.TaskName /TR $taskCommand /SC ONLOGON /DELAY '0001:00' /RL LIMITED /F | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Unable to create the AutoCut startup task.' }
        Write-Output 'Enabled: monitor starts 60 seconds after user logon.'; exit 0
    }
    'Disable' {
        if (Test-AutoStartTask) {
            & schtasks.exe /Delete /TN $TaskName /F | Out-Null
            if ($LASTEXITCODE -ne 0) { throw 'Unable to remove the AutoCut startup task.' }
        }
        Write-Output 'Disabled.'; exit 0
    }
}
