[CmdletBinding()]
param(
    [string]$InstallRoot
)

$ErrorActionPreference = 'Stop'
$interactive = [string]::IsNullOrWhiteSpace($InstallRoot)

function Show-RepairMessage([string]$Message, [string]$Title) {
    if ($interactive) {
        [void][System.Windows.Forms.MessageBox]::Show($Message, $Title)
    } else {
        Write-Host $Message
    }
}

try {
    if ($interactive) {
        Add-Type -AssemblyName System.Windows.Forms
        [System.Windows.Forms.Application]::EnableVisualStyles()
        $picker = New-Object System.Windows.Forms.FolderBrowserDialog
        $picker.Description = 'Select the hun-jian install folder that contains app'
        $picker.ShowNewFolderButton = $false
        if ($picker.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) {
            exit 0
        }
        $InstallRoot = $picker.SelectedPath
    }

    $InstallRoot = (Resolve-Path -LiteralPath $InstallRoot -ErrorAction Stop).Path
    $appRoot = Join-Path $InstallRoot 'app'
    $required = @(
        (Join-Path $appRoot 'AutoCut.ps1'),
        (Join-Path $appRoot 'tools\paraformer\paraformer_worker.py')
    )
    if (@($required | Where-Object { -not (Test-Path -LiteralPath $_ -PathType Leaf) }).Count -gt 0) {
        throw 'The selected folder is not a supported hun-jian install root. Select the folder that directly contains app.'
    }

    $repair = Join-Path $PSScriptRoot 'Apply-Paraformer-EmptySpeechRepair.ps1'
    if (-not (Test-Path -LiteralPath $repair -PathType Leaf)) {
        throw "Repair installer is missing: $repair"
    }
    & $repair -InstallRoot $InstallRoot
    if (-not $?) { throw 'Repair installer failed.' }
    Show-RepairMessage 'Repair completed. Run the 10-second test, then restart monitoring.' 'Hun-jian repair'
} catch {
    if ($interactive) {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
        [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Hun-jian repair failed')
    } else {
        Write-Error $_
    }
    exit 1
}
