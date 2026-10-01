[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$DataDirectory)
$ErrorActionPreference='Stop'
$stage = 'reading Zommi connection records'
$script:wslFailure = ''

function Quote-NativeArgument([string]$Value) {
    # wsl.exe treats a quoted leading option as a command for the default shell.
    if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') { return $Value }
    $escaped = [regex]::Replace($Value, '(\\*)"', '$1$1\"')
    return '"' + [regex]::Replace($escaped, '(\\+)$', '$1$1') + '"'
}

function Invoke-Wsl([string[]]$Arguments, [string]$InputText='') {
    $executable = Join-Path $env:WINDIR 'System32\wsl.exe'
    if (-not [Environment]::Is64BitProcess -and [Environment]::Is64BitOperatingSystem) {
        $executable = Join-Path $env:WINDIR 'Sysnative\wsl.exe'
    }
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $executable
    $start.Arguments = ($Arguments | ForEach-Object { Quote-NativeArgument $_ }) -join ' '
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = New-Object Text.UTF8Encoding($false)
    $start.StandardErrorEncoding = New-Object Text.UTF8Encoding($false)
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $start
    $script:wslFailure = ''
    try {
        if (-not $process.Start()) { throw 'Could not start WSL cleanup.' }
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $process.StandardInput.Write($InputText)
        $process.StandardInput.Close()
        if (-not $process.WaitForExit(15000)) {
            $process.Kill()
            $script:wslFailure = ' WSL cleanup timed out after 15 seconds.'
            throw 'WSL cleanup timed out.'
        }
        if ($process.ExitCode -ne 0) {
            $script:wslFailure = ' WSL exit code: ' + $process.ExitCode + '.'
            throw 'Could not verify and stop the Zommi WSL connection.'
        }
        return $stdout.Result.Trim()
    } finally { $process.Dispose() }
}

try {
    if (-not (Test-Path -LiteralPath $DataDirectory)) { exit 0 }
    $script = ([IO.File]::ReadAllText((Join-Path $PSScriptRoot 'stop-zommi-relay.sh'))).Replace("`r`n", "`n")
    # Older preview/demo profiles may also be nested inside Zommi's data root.
    $endpoints = @(
        Get-ChildItem -LiteralPath $DataDirectory -Directory -Recurse -Filter 'endpoints' |
            Where-Object { $_.Parent.Parent.Name -eq 'wsl-relay' -and $_.Parent.Name -match '^v[0-9]+$' } |
            ForEach-Object { Get-ChildItem -LiteralPath $_.FullName -File -Filter '*.json' }
    )
    if (-not $endpoints.Count) { exit 0 }
    $snapshots = @{}
    foreach ($file in $endpoints) { $snapshots[$file.FullName] = [IO.File]::ReadAllText($file.FullName) }
    Start-Sleep -Milliseconds 1200
    foreach ($file in $endpoints) {
        $stage = 'reading Zommi connection records'
        $before = $snapshots[$file.FullName]
        if (-not (Test-Path -LiteralPath $file.FullName)) { continue }
        $current = [IO.File]::ReadAllText($file.FullName)
        # Inactive distributions need not be started just to delete stale data.
        # This also allows a corrupt, inactive cache record to be removed.
        if ($before -eq $current) { continue }
        $stage = 'validating an active connection record'
        $endpoint = $current | ConvertFrom-Json
        if ($endpoint.schemaVersion -ne 1 -or [long]$endpoint.pid -le 1 -or
            [string]::IsNullOrWhiteSpace($endpoint.distribution) -or
            $endpoint.distribution -match '[\x00-\x1f]') {
            throw 'The live Zommi WSL connection record is invalid.'
        }
        $distribution = [string]$endpoint.distribution
        $stage = 'resolving the connection path in WSL'
        $linuxPath = Invoke-Wsl -Arguments @('-d', $distribution, '-e', '/usr/bin/wslpath', '-u', $file.FullName)
        $stage = 'verifying and stopping the owned WSL relay'
        Invoke-Wsl -Arguments @('-d', $distribution, '-e', '/bin/sh', '-s', '--', [string]$endpoint.pid, $linuxPath) -InputText $script | Out-Null
        $stage = 'checking that the connection stopped writing data'
        $stopped = [IO.File]::ReadAllText($file.FullName) | ConvertFrom-Json
        Start-Sleep -Milliseconds 1200
        $after = [IO.File]::ReadAllText($file.FullName) | ConvertFrom-Json
        if ($stopped.heartbeatMs -ne $after.heartbeatMs) { throw 'The Zommi WSL connection is still writing data.' }
    }
    exit 0
} catch {
    # Only fixed stage labels and a numeric exit code are safe to display.
    # JSON errors, endpoint contents and raw WSL output can contain relay tokens.
    [Console]::Error.WriteLine("Could not stop a Zommi WSL connection while $stage.$script:wslFailure Close Zommi and retry uninstall. Your data was kept.")
    exit 4
}
