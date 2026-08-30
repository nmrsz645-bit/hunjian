$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Test-Helpers.ps1"

$root = Split-Path -Parent $PSScriptRoot
$desktop = [IO.File]::ReadAllText((Join-Path $root 'desktop-src\Program.cs'), [Text.Encoding]::UTF8)

Assert-True ($desktop -match 'private bool SaveConfig') 'Desktop save must report whether the config was written'
Assert-True ($desktop -match 'ValidatePathText\(_videoDir.Text') 'Saving must validate path text only'
Assert-True ($desktop -notmatch 'ValidatePath\(_videoDir.Text') 'Saving must not require video location to be online'
Assert-True ($desktop -match 'EnsureRuntimePathsAvailable') 'Task start must validate directory availability after saving'
Assert-True ($desktop -match 'ShowError\(') 'Unavailable path must be reported before task launch'
Assert-True ($desktop -match 'HUNJIAN_LAUNCHED_BY_STARTER') 'Direct EXE launch must route through the updater starter'
Assert-True ($desktop -match 'updater.*updater-config\.json') 'Direct EXE launch must check that updater configuration exists'
Assert-True ($desktop -match 'Process\.Start\(new ProcessStartInfo\(starter\)') 'Direct EXE launch must start the root update entrypoint'
Assert-True ($desktop -match 'ConcurrentQueue<string>') 'Desktop monitor output must be queued instead of flooding the UI thread'
Assert-True ($desktop -match 'RuntimeLogLineLimit = 500') 'Desktop runtime log must have a bounded visible history'
Assert-True ($desktop -match 'Task\.Run\(\(\) => ReadStatusSnapshot') 'Status file scans must run outside the UI thread'
Assert-True ($desktop -match 'SearchOption\.TopDirectoryOnly') 'Latest log lookup must not recurse through all job logs'
Assert-True ($desktop -match 'private int _shortTaskRunning') 'Short tasks must have a running-state guard'
Assert-True ($desktop -match 'Interlocked\.CompareExchange\(ref _shortTaskRunning, 1, 0\)') 'Repeated short-test clicks must not launch concurrent tasks'

Write-Output 'PASS Test-DesktopConfig'
