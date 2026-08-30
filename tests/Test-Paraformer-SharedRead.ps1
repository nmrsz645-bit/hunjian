$ErrorActionPreference = 'Stop'
$path = Join-Path $env:TEMP ('paraformer-shared-read-' + [guid]::NewGuid().ToString('N') + '.log')

function Read-SharedText([string]$Path) {
    try {
        $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        try {
            $reader = New-Object IO.StreamReader($stream, [Text.UTF8Encoding]::new($false), $true)
            try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
        } finally { $stream.Dispose() }
    } catch [IO.IOException] {
        return ''
    }
}

try {
    $writer = [IO.File]::Open($path, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes('10 MB/100 MB 1 MB/s')
        $writer.Write($bytes, 0, $bytes.Length)
        $writer.Flush()
        if ((Read-SharedText $path) -notmatch '10 MB/100 MB') { throw 'Shared progress output was not readable.' }
    } finally { $writer.Dispose() }

    $locked = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        if (Read-SharedText $path) { throw 'Exclusive temporary output must be skipped, not read.' }
    } finally { $locked.Dispose() }

    Write-Output 'PASS Test-Paraformer-SharedRead'
} finally {
    Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
}
