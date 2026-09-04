$ErrorActionPreference = 'Stop'

function Move-PathWithRetry {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Source,

        [Parameter(Mandatory = $true)]
        [string] $Destination,

        [int] $TimeoutSeconds = 15
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        try {
            if ([IO.Directory]::Exists($Source)) {
                [IO.Directory]::Move($Source, $Destination)
            }
            elseif ([IO.File]::Exists($Source)) {
                [IO.File]::Move($Source, $Destination)
            }
            else {
                throw [IO.FileNotFoundException]::new(
                    "Deployment move source does not exist: $Source",
                    $Source
                )
            }
            return
        }
        catch {
            # TerminateProcess can disappear from the process table before the
            # loader and antivirus release their final directory handles. Only
            # retry while the source still exists and the destination has not
            # been created. Callers must validate their deployment roots before
            # passing paths into this helper.
            if (-not (Test-Path -LiteralPath $Source) -or
                (Test-Path -LiteralPath $Destination) -or
                [DateTime]::UtcNow -ge $deadline) {
                throw
            }
            Start-Sleep -Milliseconds 250
        }
    } while ($true)
}

function Get-DescendantProcessIds {
    param(
        [Parameter(Mandatory = $true)]
        [object[]] $Processes,

        [Parameter(Mandatory = $true)]
        [uint32[]] $RootProcessIds
    )

    $depthById = @{}
    foreach ($processId in $RootProcessIds) {
        $depthById[[uint32] $processId] = 0
    }

    # Roots can include both the Flutter process and its package-local child
    # helpers. Repeated relaxation preserves their real parent depth and also
    # discovers descendants whose executables live outside the package, such
    # as conhost.exe, wsl.exe, and wslhost.exe.
    foreach ($iteration in 1..([Math]::Max(1, $Processes.Count))) {
        $changed = $false
        foreach ($process in $Processes) {
            $processId = [uint32] $process.ProcessId
            $parentId = [uint32] $process.ParentProcessId
            if (-not $depthById.ContainsKey($parentId)) {
                continue
            }
            $candidateDepth = [int] $depthById[$parentId] + 1
            if (-not $depthById.ContainsKey($processId) -or
                [int] $depthById[$processId] -lt $candidateDepth) {
                $depthById[$processId] = $candidateDepth
                $changed = $true
            }
        }
        if (-not $changed) {
            break
        }
    }

    return @(
        $depthById.GetEnumerator() |
            Sort-Object -Property `
                @{ Expression = { [int] $_.Value }; Descending = $true }, `
                @{ Expression = { [uint32] $_.Key }; Descending = $true } |
            ForEach-Object { [uint32] $_.Key }
    )
}

function Get-ZommiRuntimeRootProcessIds {
    param(
        [Parameter(Mandatory = $true)]
        [object[]] $Processes
    )

    return @(
        $Processes |
            Where-Object {
                $_.Name -ieq 'wsl.exe' -and
                -not [string]::IsNullOrWhiteSpace($_.CommandLine) -and
                ($_.CommandLine.Contains('ZOMMI_RUNTIME_CHILD=1') -or
                    # Compatibility with Hermes processes launched before the
                    # general Zommi runtime marker was introduced.
                    $_.CommandLine.Contains('HERMES_DASHBOARD_SESSION_TOKEN='))
            } |
            ForEach-Object { [uint32] $_.ProcessId }
    )
}

function Redirect-ExplorerWindowsFromPath {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Source,

        [Parameter(Mandatory = $true)]
        [string] $Destination
    )

    $normalizedSource = [IO.Path]::GetFullPath($Source)
    $shell = New-Object -ComObject Shell.Application
    $redirected = [Collections.Generic.List[long]]::new()
    foreach ($window in @($shell.Windows())) {
        try {
            $path = [IO.Path]::GetFullPath($window.Document.Folder.Self.Path)
            if ([string]::Equals(
                $path,
                $normalizedSource,
                [StringComparison]::OrdinalIgnoreCase
            )) {
                $redirected.Add([long] $window.HWND)
                $null = $window.Navigate2($Destination)
            }
        }
        catch {
            # Shell windows such as Control Panel do not expose Folder.Self.
        }
    }

    if ($redirected.Count -eq 0) {
        return @()
    }
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    do {
        $remaining = @(
            $shell.Windows() | Where-Object {
                try {
                    [string]::Equals(
                        [IO.Path]::GetFullPath($_.Document.Folder.Self.Path),
                        $normalizedSource,
                        [StringComparison]::OrdinalIgnoreCase
                    )
                }
                catch {
                    $false
                }
            }
        )
        if ($remaining.Count -eq 0) {
            return @($redirected)
        }
        Start-Sleep -Milliseconds 200
    } while ([DateTime]::UtcNow -lt $deadline)

    throw "Explorer did not release the deployment directory: $Source"
}

function Restore-ExplorerWindowsToPath {
    param(
        [long[]] $WindowHandles = @(),

        [Parameter(Mandatory = $true)]
        [string] $Destination
    )

    if ($WindowHandles.Count -eq 0) {
        return
    }
    $shell = New-Object -ComObject Shell.Application
    foreach ($windowHandle in $WindowHandles) {
        foreach ($window in @($shell.Windows())) {
            try {
                if ([long] $window.HWND -eq $windowHandle) {
                    $null = $window.Navigate2($Destination)
                    break
                }
            }
            catch {
                # The original Explorer window may have closed during deploy.
            }
        }
    }
}

Export-ModuleMember -Function `
    Move-PathWithRetry, `
    Get-DescendantProcessIds, `
    Get-ZommiRuntimeRootProcessIds, `
    Redirect-ExplorerWindowsFromPath, `
    Restore-ExplorerWindowsToPath
