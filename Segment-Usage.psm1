Set-StrictMode -Version Latest

function Test-SourceSegmentUnused([string]$SourcePath, [double]$Start, [double]$Duration, $PlannedClips) {
    $end = $Start + $Duration
    foreach ($clip in $PlannedClips) {
        if ($clip.Source.FullName -eq $SourcePath -and $Start -lt ([double]$clip.Start + [double]$clip.Duration) -and [double]$clip.Start -lt $end) {
            return $false
        }
    }
    return $true
}

Export-ModuleMember -Function Test-SourceSegmentUnused
