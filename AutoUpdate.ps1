# Runtime automatic updates are intentionally disabled.  Updates are checked
# only when the user starts the root Start.cmd after the program has exited.
$notice = -join @(
    [char]0x4E0D,[char]0x81EA,[char]0x52A8,[char]0x66F4,[char]0x65B0,[char]0xFF1A,
    [char]0x7A0B,[char]0x5E8F,[char]0x6216,[char]0x76D1,[char]0x63A7,[char]0x8FD0,[char]0x884C,[char]0x671F,[char]0x95F4,
    [char]0x4E0D,[char]0x4F1A,[char]0x68C0,[char]0x67E5,[char]0x3001,[char]0x4E0B,[char]0x8F7D,[char]0x3001,
    [char]0x66FF,[char]0x6362,[char]0x6216,[char]0x91CD,[char]0x542F,[char]0x3002
)
Write-Output $notice
exit 0
