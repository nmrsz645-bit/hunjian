$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Test-Helpers.ps1"

$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'Segment-Usage.psm1') -Force
$source = [pscustomobject]@{ FullName = 'C:\素材\video.mp4' }
$clips = @([pscustomobject]@{ Source = $source; Start = 10.0; Duration = 5.0 })

Assert-True (-not (Test-SourceSegmentUnused $source.FullName 12 3 $clips)) 'Same source with overlapping seconds must be rejected'
Assert-True (Test-SourceSegmentUnused $source.FullName 15 3 $clips) 'Adjacent seconds must be allowed'
Assert-True (Test-SourceSegmentUnused $source.FullName 20 3 $clips) 'Different seconds must be allowed'
Assert-True (Test-SourceSegmentUnused 'C:\素材\other.mp4' 12 3 $clips) 'Different source must be allowed'

Write-Host 'PASS Test-Segment-Usage' -ForegroundColor Green
