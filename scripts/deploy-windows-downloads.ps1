[CmdletBinding()]
param(
    [ValidateSet('win-x64', 'win-arm64')]
    [string] $Runtime = 'win-x64',

    [string] $DownloadsDirectory = (Join-Path $env:USERPROFILE 'Downloads'),

    [switch] $NoStart
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$architecture = if ($Runtime -eq 'win-arm64') { 'arm64' } else { 'x64' }
$packageName = "zommi-windows-$architecture"
$sourceDirectory = Join-Path $repositoryRoot "artifacts/$packageName"
$sourceArchive = "$sourceDirectory.zip"
$downloadsRoot = [IO.Path]::GetFullPath($DownloadsDirectory).TrimEnd('\')
$targetDirectory = Join-Path $downloadsRoot $packageName
$targetArchive = Join-Path $downloadsRoot "$packageName.zip"
$deploymentId = [Guid]::NewGuid().ToString('N')
$pendingDirectory = Join-Path $downloadsRoot "$packageName.pending-$deploymentId"
$pendingArchive = Join-Path $downloadsRoot "$packageName.pending-$deploymentId.zip"
$backupDirectory = Join-Path $downloadsRoot "$packageName.backup-$deploymentId"
$backupArchive = Join-Path $downloadsRoot "$packageName.backup-$deploymentId.zip"
$directoryReplaced = $false
$archiveReplaced = $false
$hadDirectoryBackup = $false
$hadArchiveBackup = $false
$stoppedProcessCount = 0

function Get-DirectoryHashes {
    param([string] $Root)

    $normalizedRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    $prefixLength = $normalizedRoot.Length + 1
    $hashes = @{}
    foreach ($file in Get-ChildItem -LiteralPath $normalizedRoot -Recurse -File) {
        $relativePath = $file.FullName.Substring($prefixLength)
        $hashes[$relativePath] = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
    }
    return $hashes
}

function Assert-DirectoryMatches {
    param(
        [string] $Expected,
        [string] $Actual
    )

    $expectedHashes = Get-DirectoryHashes $Expected
    $actualHashes = Get-DirectoryHashes $Actual
    if ($expectedHashes.Count -ne $actualHashes.Count) {
        throw "Directory file counts differ: expected $($expectedHashes.Count), actual $($actualHashes.Count)."
    }

    foreach ($relativePath in $expectedHashes.Keys) {
        if (-not $actualHashes.ContainsKey($relativePath) -or
            $actualHashes[$relativePath] -ne $expectedHashes[$relativePath]) {
            throw "Directory hash mismatch: $relativePath"
        }
    }

    return $actualHashes.Count
}

function Get-ExactTargetProcesses {
    param([string] $ExecutablePath)

    $normalizedExecutable = [IO.Path]::GetFullPath($ExecutablePath)
    return @(
        Get-CimInstance Win32_Process | Where-Object {
            $_.Name -eq 'Zommi.exe' -and
            $_.ExecutablePath -and
            [string]::Equals(
                [IO.Path]::GetFullPath($_.ExecutablePath),
                $normalizedExecutable,
                [StringComparison]::OrdinalIgnoreCase)
        }
    )
}

function Get-TargetDirectoryProcesses {
    param([string] $Directory)

    $normalizedDirectory = [IO.Path]::GetFullPath($Directory).TrimEnd('\')
    $directoryPrefix = $normalizedDirectory + '\'
    return @(
        Get-CimInstance Win32_Process | Where-Object {
            $_.ExecutablePath -and
            [IO.Path]::GetFullPath($_.ExecutablePath).StartsWith(
                $directoryPrefix,
                [StringComparison]::OrdinalIgnoreCase)
        }
    )
}

if (-not (Test-Path -LiteralPath $sourceDirectory -PathType Container) -or
    -not (Test-Path -LiteralPath $sourceArchive -PathType Leaf)) {
    throw "Build the package before deploying: $sourceDirectory"
}

if (-not (Test-Path -LiteralPath $downloadsRoot -PathType Container)) {
    New-Item -ItemType Directory -Path $downloadsRoot | Out-Null
}

$expectedPrefix = $downloadsRoot + '\'
if (-not $targetDirectory.StartsWith($expectedPrefix, [StringComparison]::OrdinalIgnoreCase) -or
    -not $targetArchive.StartsWith($expectedPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Refusing to deploy outside the resolved Downloads directory.'
}

try {
    Copy-Item -LiteralPath $sourceDirectory -Destination $pendingDirectory -Recurse
    Copy-Item -LiteralPath $sourceArchive -Destination $pendingArchive
    $null = Assert-DirectoryMatches $sourceDirectory $pendingDirectory

    $sourceArchiveHash = (Get-FileHash -LiteralPath $sourceArchive -Algorithm SHA256).Hash
    $pendingArchiveHash = (Get-FileHash -LiteralPath $pendingArchive -Algorithm SHA256).Hash
    if ($sourceArchiveHash -ne $pendingArchiveHash) {
        throw 'The staged portable archive does not match the source archive.'
    }

    $targetExecutable = Join-Path $targetDirectory 'Zommi.exe'
    # Stop the exact Flutter app, Rust core, and capture helper package tree so
    # no child retains a file lock during the atomic replacement.
    $targetProcesses = @(Get-TargetDirectoryProcesses $targetDirectory)
    $stoppedProcessCount = $targetProcesses.Count
    foreach ($process in $targetProcesses) {
        Stop-Process -Id $process.ProcessId -Force
    }
    Start-Sleep -Milliseconds 500
    if (@(Get-TargetDirectoryProcesses $targetDirectory).Count -ne 0) {
        throw 'A Zommi process inside the exact deployment directory remained running.'
    }

    if (Test-Path -LiteralPath $targetDirectory) {
        Move-Item -LiteralPath $targetDirectory -Destination $backupDirectory
        $hadDirectoryBackup = $true
    }
    Move-Item -LiteralPath $pendingDirectory -Destination $targetDirectory
    $directoryReplaced = $true

    if (Test-Path -LiteralPath $targetArchive) {
        Move-Item -LiteralPath $targetArchive -Destination $backupArchive
        $hadArchiveBackup = $true
    }
    Move-Item -LiteralPath $pendingArchive -Destination $targetArchive
    $archiveReplaced = $true

    $deployedFileCount = Assert-DirectoryMatches $sourceDirectory $targetDirectory
    $targetArchiveHash = (Get-FileHash -LiteralPath $targetArchive -Algorithm SHA256).Hash
    if ($targetArchiveHash -ne $sourceArchiveHash) {
        throw 'The deployed portable archive does not match the source archive.'
    }

    $startedProcessId = $null
    $flutterProcessCount = 0
    if (-not $NoStart) {
        $startedProcess = Start-Process `
            -FilePath (Join-Path $targetDirectory 'Zommi.exe') `
            -WorkingDirectory $targetDirectory `
            -PassThru
        Start-Sleep -Seconds 2
        $startedProcess.Refresh()
        if ($startedProcess.HasExited) {
            throw "The deployed Zommi process exited with code $($startedProcess.ExitCode)."
        }

        $runningTargets = @()
        $processDeadline = [DateTime]::UtcNow.AddSeconds(10)
        do {
            $startedProcess.Refresh()
            if ($startedProcess.HasExited) {
                throw "The deployed Zommi process exited with code $($startedProcess.ExitCode)."
            }
            $runningTargets = @(Get-ExactTargetProcesses (Join-Path $targetDirectory 'Zommi.exe'))
            if ($runningTargets.Count -ge 1 -and
                $runningTargets.ProcessId -contains $startedProcess.Id) {
                break
            }
            Start-Sleep -Milliseconds 250
        } while ([DateTime]::UtcNow -lt $processDeadline)

        if ($runningTargets.Count -lt 1 -or
            $runningTargets.ProcessId -notcontains $startedProcess.Id) {
            throw "Expected the Flutter desktop process; found $($runningTargets.Count) exact-path processes."
        }
        $startedProcessId = $startedProcess.Id
        $flutterProcessCount = $runningTargets.Count
    }

    if ($hadDirectoryBackup) {
        Remove-Item -LiteralPath $backupDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ($hadArchiveBackup) {
        Remove-Item -LiteralPath $backupArchive -Force -ErrorAction SilentlyContinue
    }

    [ordered]@{
        targetDirectory = $targetDirectory
        targetArchive = $targetArchive
        files = $deployedFileCount
        executableSha256 = (Get-FileHash -LiteralPath (Join-Path $targetDirectory 'Zommi.exe') -Algorithm SHA256).Hash.ToLowerInvariant()
        archiveSha256 = $targetArchiveHash.ToLowerInvariant()
        stoppedProcesses = $stoppedProcessCount
        startedProcessId = $startedProcessId
        flutterProcessCount = $flutterProcessCount
    } | ConvertTo-Json
}
catch {
    if ($directoryReplaced) {
        foreach ($process in (Get-TargetDirectoryProcesses $targetDirectory)) {
            Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
        }
        Remove-Item -LiteralPath $targetDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ($archiveReplaced) {
        Remove-Item -LiteralPath $targetArchive -Force -ErrorAction SilentlyContinue
    }
    if ($hadDirectoryBackup -and (Test-Path -LiteralPath $backupDirectory)) {
        Move-Item -LiteralPath $backupDirectory -Destination $targetDirectory
    }
    if ($hadArchiveBackup -and (Test-Path -LiteralPath $backupArchive)) {
        Move-Item -LiteralPath $backupArchive -Destination $targetArchive
    }
    if ($stoppedProcessCount -gt 0 -and
        (Test-Path -LiteralPath (Join-Path $targetDirectory 'Zommi.exe') -PathType Leaf)) {
        Start-Process `
            -FilePath (Join-Path $targetDirectory 'Zommi.exe') `
            -WorkingDirectory $targetDirectory | Out-Null
    }
    throw
}
finally {
    Remove-Item -LiteralPath $pendingDirectory -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $pendingArchive -Force -ErrorAction SilentlyContinue
}
