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

Export-ModuleMember -Function Move-PathWithRetry
