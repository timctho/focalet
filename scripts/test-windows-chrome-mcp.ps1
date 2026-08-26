[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $ExecutablePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
}

function Send-NativeRequest {
    param(
        [System.Diagnostics.Process] $Process,
        [string] $Id,
        [string] $Method,
        [hashtable] $Params = @{}
    )

    $json = [ordered]@{
        id = $Id
        method = $Method
        params = $Params
    } | ConvertTo-Json -Compress -Depth 20
    $Process.StandardInput.WriteLine($json)
    $Process.StandardInput.Flush()
}

function Read-NativeEnvelope {
    param(
        [System.Diagnostics.Process] $Process,
        [DateTime] $Deadline
    )

    $remaining = [int] [Math]::Max(1, ($Deadline - [DateTime]::UtcNow).TotalMilliseconds)
    $readTask = $Process.StandardOutput.ReadLineAsync()
    if (-not $readTask.Wait($remaining)) {
        throw 'Timed out waiting for the Zommi native host protocol.'
    }
    $line = $readTask.Result
    if ($null -eq $line) {
        $stderr = $Process.StandardError.ReadToEnd()
        throw "Zommi native host closed its protocol stream. $stderr"
    }
    try {
        return $line | ConvertFrom-Json
    }
    catch {
        throw "Zommi native host emitted invalid JSON: $line"
    }
}

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw 'Chrome MCP acceptance requires Windows.'
}

$resolvedExecutable = [IO.Path]::GetFullPath($ExecutablePath)
$packageDirectory = Split-Path -Parent $resolvedExecutable
$nativeHost = Join-Path $packageDirectory 'resources\native\Zommi.exe'
Assert-True (Test-Path -LiteralPath $resolvedExecutable -PathType Leaf) 'The packaged Electron executable is missing.'
Assert-True (Test-Path -LiteralPath $nativeHost -PathType Leaf) 'The packaged native host is missing.'

$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ('zommi-chrome-mcp-acceptance-' + [Guid]::NewGuid().ToString('N'))
$secretMarker = 'ZOMMI_CHROME_TOOL_' + [Guid]::NewGuid().ToString('N')
$secretPath = Join-Path $temporaryRoot 'secret.html'
$process = $null
$transcriptTail = New-Object System.Collections.Generic.List[string]
$profilesBefore = @(Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Directory -Filter 'zommi-chrome-tool-*' -ErrorAction SilentlyContinue | ForEach-Object FullName)

try {
    New-Item -ItemType Directory -Path $temporaryRoot | Out-Null
    [IO.File]::WriteAllText(
        $secretPath,
        "<!doctype html><title>Zommi Chrome MCP acceptance</title><main><p id='secret'>$secretMarker</p></main>")
    $secretUri = ([Uri] $secretPath).AbsoluteUri

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $nativeHost
    $startInfo.Arguments = '--electron-host'
    $startInfo.WorkingDirectory = Split-Path -Parent $nativeHost
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    Assert-True ($process.Start()) 'Windows could not start the packaged Zommi native host.'

    Send-NativeRequest $process 'start' 'startCodex'
    $deadline = [DateTime]::UtcNow.AddSeconds(90)
    $started = $false
    while (-not $started -and [DateTime]::UtcNow -lt $deadline) {
        $envelope = Read-NativeEnvelope $process $deadline
        $transcriptTail.Add(($envelope | ConvertTo-Json -Compress -Depth 8))
        if ($envelope.type -eq 'response' -and $envelope.id -eq 'start') {
            if (-not $envelope.ok) { throw "Codex startup failed: $($envelope.error)" }
            $started = $true
        }
    }
    Assert-True $started 'The native host did not complete Codex startup.'

    $prompt = "Use the zommiChrome Chrome DevTools MCP tools to navigate the isolated tool browser to $secretUri, read the exact token beginning ZOMMI_CHROME_TOOL_, and reply with that token only."
    Send-NativeRequest $process 'turn' 'startTurn' @{
        message = $prompt
        snapshots = @()
        images = @()
    }

    $deadline = [DateTime]::UtcNow.AddSeconds(180)
    $turnAccepted = $false
    $turnCompleted = $false
    $sawMcpLifecycle = $false
    $assistantText = ''
    while ((-not $turnCompleted -or $assistantText -notlike "*$secretMarker*") -and
        [DateTime]::UtcNow -lt $deadline) {
        $envelope = Read-NativeEnvelope $process $deadline
        $serialized = $envelope | ConvertTo-Json -Compress -Depth 8
        $transcriptTail.Add($serialized)
        while ($transcriptTail.Count -gt 80) { $transcriptTail.RemoveAt(0) }

        if ($envelope.type -eq 'response' -and $envelope.id -eq 'turn') {
            if (-not $envelope.ok) { throw "Codex rejected the Chrome MCP turn: $($envelope.error)" }
            $turnAccepted = $true
        }
        elseif ($envelope.type -eq 'event' -and $envelope.event -eq 'streamUpdate') {
            if ($envelope.data.title -eq 'MCP tool' -and $envelope.data.text -like '*zommiChrome*') {
                $sawMcpLifecycle = $true
            }
            if ($envelope.data.kind -eq 'assistant') {
                $assistantText += [string] $envelope.data.text
            }
        }
        elseif ($envelope.type -eq 'event' -and $envelope.event -eq 'turnCompleted') {
            $turnCompleted = $true
        }
    }

    Assert-True $turnAccepted 'The native host did not accept the Chrome MCP turn.'
    Assert-True $sawMcpLifecycle 'The transcript did not expose a zommiChrome MCP tool lifecycle.'
    Assert-True $turnCompleted 'The Chrome MCP turn did not complete.'
    Assert-True ($assistantText -like "*$secretMarker*") "Codex did not return the secret read by Chrome MCP. Transcript: $([string]::Join([Environment]::NewLine, $transcriptTail))"

    Send-NativeRequest $process 'stop' 'shutdown'
    $shutdownDeadline = [DateTime]::UtcNow.AddSeconds(15)
    $shutdownAcknowledged = $false
    while (-not $shutdownAcknowledged -and [DateTime]::UtcNow -lt $shutdownDeadline) {
        $envelope = Read-NativeEnvelope $process $shutdownDeadline
        if ($envelope.type -eq 'response' -and $envelope.id -eq 'stop') {
            if (-not $envelope.ok) { throw "Native host shutdown failed: $($envelope.error)" }
            $shutdownAcknowledged = $true
        }
    }
    Assert-True $shutdownAcknowledged 'The native host did not acknowledge shutdown.'
    Assert-True $process.WaitForExit(15000) 'The native host did not exit after shutdown.'

    $profileDeadline = [DateTime]::UtcNow.AddSeconds(5)
    do {
        $profilesAfter = @(Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Directory -Filter 'zommi-chrome-tool-*' -ErrorAction SilentlyContinue | ForEach-Object FullName)
        $createdProfiles = @($profilesAfter | Where-Object { $profilesBefore -notcontains $_ })
        if ($createdProfiles.Count -eq 0) { break }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $profileDeadline)
    Assert-True ($createdProfiles.Count -eq 0) "Chrome tool profiles remained after shutdown: $($createdProfiles -join ', ')"

    [ordered]@{
        executablePath = $resolvedExecutable
        executableSha256 = (Get-FileHash -LiteralPath $resolvedExecutable -Algorithm SHA256).Hash.ToLowerInvariant()
        nativeHostSha256 = (Get-FileHash -LiteralPath $nativeHost -Algorithm SHA256).Hash.ToLowerInvariant()
        chromeMcp = 'passed'
        chromeMcpLifecycle = 'MCP tool · zommiChrome'
        responseToken = $secretMarker
        isolatedProfileCleanup = 'passed'
    } | ConvertTo-Json
}
finally {
    if ($null -ne $process -and -not $process.HasExited) {
        try {
            & "$env:SystemRoot\System32\taskkill.exe" /PID $process.Id /T /F *> $null
        }
        catch {
            # Cleanup must not hide the protocol assertion that triggered it.
        }
    }
    if (Test-Path -LiteralPath $temporaryRoot) {
        Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
