$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'windows-deployment-helpers.psm1') -Force

$acceptanceSource = Get-Content -Raw (Join-Path $PSScriptRoot 'accept-windows-capture.ps1')
$acceptanceSyntax = [Management.Automation.Language.Parser]::ParseInput($acceptanceSource, [ref]$null, [ref]$null)
$suspendFunction = $acceptanceSyntax.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Suspend-ConflictingZommiApplications' }, $true).Extent.Text
foreach ($stillRunning in @($false, $true)) {
    & {
        param([bool] $StillRunning, [string] $Definition)
        Invoke-Expression $Definition
        $script:cleanupQueries = 0
        function Get-CimInstance {
            param([string] $ClassName)
            $script:cleanupQueries++
            if ($script:cleanupQueries -le 2) {
                [pscustomobject]@{ Name = 'Zommi.exe'; ProcessId = 100001; ExecutablePath = 'C:\zommi-cleanup-fixture\Zommi.exe' }
            }
        }
        function Stop-Process {
            param([int] $Id, [switch] $Force, [string] $ErrorAction)
            throw 'Simulated stop failure'
        }
        function Get-Process {
            param([int] $Id, [string] $ErrorAction)
            if ($StillRunning) { [pscustomobject]@{ Id = $Id } }
        }
        $failure = $null
        try { $paths = @(Suspend-ConflictingZommiApplications -EntryPoint 'C:\zommi-probe\Zommi.exe') }
        catch { $failure = $_.Exception.Message }
        if ($StillRunning -and $failure -ne 'Simulated stop failure') { throw 'A live process failure was suppressed.' }
        if (-not $StillRunning -and ($failure -or $paths.Count -ne 1)) { throw 'An already exited process blocked acceptance cleanup.' }
    } $stillRunning $suspendFunction
}

$processes = @(
    [pscustomobject]@{ ProcessId = 50; ParentProcessId = 1; Name = 'runner' }
    [pscustomobject]@{ ProcessId = 100; ParentProcessId = 50; Name = 'Zommi' }
    [pscustomobject]@{ ProcessId = 101; ParentProcessId = 100; Name = 'core' }
    [pscustomobject]@{ ProcessId = 102; ParentProcessId = 100; Name = 'capture' }
    [pscustomobject]@{ ProcessId = 103; ParentProcessId = 101; Name = 'wsl' }
    [pscustomobject]@{ ProcessId = 104; ParentProcessId = 103; Name = 'wslhost' }
    [pscustomobject]@{ ProcessId = 200; ParentProcessId = 50; Name = 'unrelated' }
)
$tree = @(
    Get-DescendantProcessIds `
        -Processes $processes `
        -RootProcessIds @(100, 101, 102)
)
if (($tree | Sort-Object) -join ',' -ne '100,101,102,103,104') {
    throw "The process tree included the wrong processes: $($tree -join ',')."
}

$runtimeRoots = @(
    Get-ZommiRuntimeRootProcessIds -Processes @(
        [pscustomobject]@{
            ProcessId = 301
            Name = 'wsl.exe'
            CommandLine = 'wsl.exe -e env ZOMMI_RUNTIME_CHILD=1 codex app-server'
        }
        [pscustomobject]@{
            ProcessId = 302
            Name = 'wsl.exe'
            CommandLine = 'wsl.exe -e env HERMES_DASHBOARD_SESSION_TOKEN=fixture hermes serve'
        }
        [pscustomobject]@{
            ProcessId = 303
            Name = 'wsl.exe'
            CommandLine = 'wsl.exe -e bash'
        }
        [pscustomobject]@{
            ProcessId = 304
            Name = 'pwsh.exe'
            CommandLine = 'ZOMMI_RUNTIME_CHILD=1'
        }
    )
)
if (($runtimeRoots | Sort-Object) -join ',' -ne '301,302') {
    throw "The runtime marker matched the wrong processes: $($runtimeRoots -join ',')."
}
foreach ($edge in @(@(104, 103), @(103, 101), @(101, 100), @(102, 100))) {
    if ([Array]::IndexOf($tree, [uint32] $edge[0]) -ge
        [Array]::IndexOf($tree, [uint32] $edge[1])) {
        throw "The process tree is not child-first: $($tree -join ',')."
    }
}

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
        processTree = $true
        runtimeMarker = $true
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
