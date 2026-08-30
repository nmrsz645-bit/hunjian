param([Parameter(Mandatory = $true)][string]$RequestPath)

$ErrorActionPreference = 'Stop'
$request = Get-Content -LiteralPath $RequestPath -Raw -Encoding UTF8 | ConvertFrom-Json
Set-Location -LiteralPath $request.WorkDir

$arguments = @('-hide_banner', '-loglevel', 'error', '-y')
if (-not [string]::IsNullOrWhiteSpace([string]$request.VideoPath)) {
    $arguments += @('-ss', ([string]$request.Time), '-i', ([string]$request.VideoPath))
} else {
    $arguments += @('-f', 'lavfi', '-i', "color=c=0x805744:s=$($request.Width)x$($request.Height):d=1")
}
$arguments += @('-frames:v', '1', '-vf', ([string]$request.Filter), ([string]$request.OutputPath))

& ([string]$request.Ffmpeg) @arguments
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $request.OutputPath -PathType Leaf)) {
    throw "FFmpeg preview failed with exit code $LASTEXITCODE"
}
