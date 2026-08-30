$ErrorActionPreference = 'Stop'

function Assert-True($Condition, [string]$Message) {
    if (-not $Condition) {
        throw "TEST FAILED: $Message"
    }
}

function Assert-Equal($Expected, $Actual, [string]$Message) {
    if ($Expected -ne $Actual) {
        throw "TEST FAILED: $Message。期望=[$Expected]，实际=[$Actual]"
    }
}

