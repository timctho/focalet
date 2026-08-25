[CmdletBinding()]
param(
    [string] $StateRoot,
    [string] $Channel
)

# PowerShell is the console-subsystem bridge between WSL's stdin/stdout and the
# packaged Windows hook executable. It keeps hook payloads in memory only.
try {
    $hookExecutable = Join-Path $PSScriptRoot 'Zommi.Hook.exe'
    if (-not (Test-Path -LiteralPath $hookExecutable)) {
        exit 0
    }

    $arguments = '--zommi-hook'
    if (-not [string]::IsNullOrWhiteSpace($StateRoot)) {
        $arguments += ' --state-root "' + $StateRoot.Replace('"', '\"') + '"'
    }
    if (-not [string]::IsNullOrWhiteSpace($Channel)) {
        $arguments += ' --channel "' + $Channel.Replace('"', '\"') + '"'
    }

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $hookExecutable
    $startInfo.Arguments = $arguments
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    if (-not $process.Start()) {
        exit 0
    }

    $eventJson = [Console]::In.ReadToEnd()
    $process.StandardInput.Write($eventJson)
    $process.StandardInput.Close()
    $output = $process.StandardOutput.ReadToEnd()
    [void] $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    if (-not [string]::IsNullOrEmpty($output)) {
        [Console]::Out.Write($output)
    }
} catch {
    # The adapter is fail-open: Codex must continue if the Windows bridge fails.
}

exit 0
