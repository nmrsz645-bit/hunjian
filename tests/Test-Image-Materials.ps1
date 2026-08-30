$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Test-Helpers.ps1"

$root = Split-Path -Parent $PSScriptRoot
$autoCut = [IO.File]::ReadAllText((Join-Path $root 'AutoCut.ps1'), [Text.Encoding]::UTF8)
$manager = [IO.File]::ReadAllText((Join-Path $root 'AutoCut-Manager.ps1'), [Text.Encoding]::UTF8)
$config = [IO.File]::ReadAllText((Join-Path $root 'config.ps1'), [Text.Encoding]::UTF8)

Assert-True ($autoCut -match '\$ImageExts') 'Image extensions missing'
Assert-True ($autoCut -match 'ImageDurationSeconds') 'Image duration setting missing'
Assert-True ($autoCut -match 'IsImage') 'Image clip marker missing'
Assert-True ($autoCut -match 'Motion') 'Image motion marker missing'
Assert-True ($autoCut -match 'Next\(0, 2\)') 'Two continuous image zoom modes required'
Assert-True ($autoCut -match '\$ClipMode -eq "short"') 'Short-video whole-source mode missing'
Assert-True ($config -match '\$MinimumShortClipSeconds\s*=\s*3') 'Short-video minimum duration setting missing'
Assert-True ($autoCut -match 'perspective=x0=') 'Image effects must use per-frame floating-point keyframe transforms'
Assert-True ($autoCut -match 'interpolation=cubic:eval=frame') 'Image transforms must use cubic interpolation for every frame'
Assert-True ($autoCut -match '\$motionAmount\s*=\s*\[Math\]::Min\(0\.16') 'Image motion must use the bounded smooth keyframe range'
Assert-True ($autoCut -match 'motionAmount.*on/\$imageFrames') 'Image motion must be calculated across every planned output frame'
Assert-True ($autoCut -notmatch '\$centerX\s*=') 'Image keyframes must stay center-anchored to avoid long-still jitter'
Assert-True ($autoCut -match 'trim=duration=') 'Image clips must be trimmed to their planned duration'
Assert-True ($autoCut -match '"-t", \$outputDuration') 'Final output must be limited to the planned duration'
Assert-True ($autoCut -match 'ImageDurationSeconds.*remaining|remaining.*ImageDurationSeconds') 'Final image trim missing'
Assert-True ($autoCut -match 'usedSources\.ContainsKey\(\$source\.FullName\)') 'Duplicate image guard missing'
Assert-True ($autoCut -match '"-loop", "1"') 'Looped image input missing'
Assert-True ($autoCut -match '\$progress\s*=\s*"min\(1,t/') 'Timed image motion missing'
Assert-True ($config -match '\$ImageDurationSeconds\s*=\s*6') 'Default image duration missing'
Assert-True ($manager -match 'ImageDurationSeconds') 'Manager image duration missing'
Assert-True ($config -match '\$EnableImageEffects\s*=\s*\$true') 'Default image effects setting missing'
Assert-True ($manager -match 'EnableImageEffects') 'Manager image effects toggle missing'
Assert-True ($autoCut -match '-not \$EnableImageEffects') 'Image effect switch must disable motion in renderer'
Assert-True (-not ($config -match 'EnableDedupEffects')) 'Old dedup setting must be removed'
Assert-True (-not ($manager -match 'EnableDedupEffects')) 'Old dedup toggle must be removed'
Assert-True (-not ($autoCut -match 'eq=brightness=')) 'Old dedup color variation must be removed'
Assert-True ($config -match '\$EnableAtmosphereEffects\s*=\s*\$true') 'Atmosphere effects must default to on'
Assert-True ($manager -match 'AtmosphereEffectMode') 'Manager atmosphere mode selector missing'
Assert-True ($autoCut -match 'Select-AtmosphereEffect') 'Atmosphere effect selector missing'
Assert-True ($autoCut -match "'snow'.*'rain'.*'petals'.*'fireworks'") 'Atmosphere library categories missing'
Assert-True ($autoCut.Contains('fontcolor=$($settings.Color)') -and $autoCut.Contains('mod($x+t*$xSpeed,$Width)')) 'Atmosphere particles must use the configured color and animated coordinates'
Assert-True ($config -match '\$ClipMode\s*=\s*"random"') 'Default clip mode missing'
Assert-True ($autoCut -match '\$ClipMode\s*-eq\s*"whole"') 'Whole-source rendering mode missing'
Assert-True ($manager -match 'chkWholeSource') 'Manager whole-source toggle missing'
Assert-True ($manager -match 'ClipMode\s*=\s*if \(\$chkWholeSource\.Checked\)') 'Manager whole-source toggle is not saved'
Assert-True ($autoCut -match 'filter_complex_script') 'Long render filters must use a script file'

Write-Host 'PASS Test-Image-Materials' -ForegroundColor Green
