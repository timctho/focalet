$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'windows-deployment-helpers.psm1') -Force

$testRoot = Join-Path $env:TEMP "zommi-deployment-test-$([Guid]::NewGuid().ToString('N'))"
$source = Join-Path $testRoot 'source'
$destination = Join-Path $testRoot 'destination'
$heldFile = Join-Path $source 'held.txt'
$readyFile = Join-Path $testRoot 'holder-ready'
$holder = $null

try {
    New-Item -ItemType Directory -Path $source -Force | Out-Null
    Set-Content -LiteralPath $heldFile -Value 'held'
    $holder = Start-Job -ScriptBlock {
        param(
            [string] $Path,
            [string] $ReadyPath
        )

        $stream = [IO.File]::Open(
            $Path,
            [IO.FileMode]::Open,
            [IO.FileAccess]::Read,
            [IO.FileShare]::None
        )
        try {
            Set-Content -LiteralPath $ReadyPath -Value 'ready'
            Start-Sleep -Seconds 2
        }
        finally {
            $stream.Dispose()
        }
    } -ArgumentList $heldFile, $readyFile
    $readyDeadline = [DateTime]::UtcNow.AddSeconds(5)
    while (-not (Test-Path -LiteralPath $readyFile -PathType Leaf)) {
        if ([DateTime]::UtcNow -ge $readyDeadline) {
            throw 'The file-lock holder did not become ready.'
        }
        Start-Sleep -Milliseconds 50
    }

    $clock = [Diagnostics.Stopwatch]::StartNew()
    Move-PathWithRetry `
        -Source $source `
        -Destination $destination `
        -TimeoutSeconds 6
    $clock.Stop()

    if (-not (Test-Path -LiteralPath $destination -PathType Container)) {
        throw 'The retry helper did not move the locked directory.'
    }
    if ($clock.ElapsedMilliseconds -lt 900) {
        throw "The retry helper did not exercise the lock path: $($clock.ElapsedMilliseconds)ms."
    }
    if (-not (Test-Path -LiteralPath (Join-Path $destination 'held.txt') -PathType Leaf)) {
        throw 'The retry helper lost the held file.'
    }

    [ordered]@{
        lockRetry = $true
        elapsedMilliseconds = $clock.ElapsedMilliseconds
    } | ConvertTo-Json
}
finally {
    if ($null -ne $holder) {
        Wait-Job $holder -Timeout 5 | Out-Null
        Remove-Job $holder -Force -ErrorAction SilentlyContinue
    }
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
