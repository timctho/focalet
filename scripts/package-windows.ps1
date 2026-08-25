[CmdletBinding()]
param(
    [ValidateSet('win-x64', 'win-arm64')]
    [string] $Runtime = 'win-x64',

    [switch] $SkipPublish,

    [switch] $DeployToDownloads
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$outputDirectory = Join-Path $repositoryRoot "artifacts/zommi-$Runtime"
$nativeOutputDirectory = Join-Path $repositoryRoot "artifacts/zommi-native-$Runtime"
$electronDirectory = Join-Path $repositoryRoot 'src/Zommi.Electron'

if (-not $SkipPublish) {
    if (Test-Path -LiteralPath $nativeOutputDirectory) {
        Remove-Item -LiteralPath $nativeOutputDirectory -Recurse -Force
    }
    dotnet publish (Join-Path $repositoryRoot 'src/Zommi.Windows/Zommi.Windows.csproj') `
        --configuration Release `
        --runtime $Runtime `
        --self-contained true `
        -p:PublishSingleFile=true `
        -p:IncludeNativeLibrariesForSelfExtract=true `
        --output $nativeOutputDirectory
    if ($LASTEXITCODE -ne 0) {
        throw "Zommi Windows publish failed with exit code $LASTEXITCODE."
    }

    dotnet publish (Join-Path $repositoryRoot 'src/Zommi.Hook/Zommi.Hook.csproj') `
        --configuration Release `
        --runtime $Runtime `
        --self-contained true `
        -p:PublishSingleFile=true `
        -p:IncludeNativeLibrariesForSelfExtract=true `
        --output $nativeOutputDirectory
    if ($LASTEXITCODE -ne 0) {
        throw "Zommi Hook publish failed with exit code $LASTEXITCODE."
    }

    Push-Location $electronDirectory
    try {
        npm ci
        if ($LASTEXITCODE -ne 0) {
            throw "Electron dependency restore failed with exit code $LASTEXITCODE."
        }
        $architecture = if ($Runtime -eq 'win-arm64') { 'arm64' } else { 'x64' }
        node (Join-Path $electronDirectory 'scripts/package-electron.mjs') `
            --platform win32 `
            --arch $architecture `
            --output $outputDirectory `
            --native-dir $nativeOutputDirectory
        if ($LASTEXITCODE -ne 0) {
            throw "Electron Windows packaging failed with exit code $LASTEXITCODE."
        }
    }
    finally {
        Pop-Location
    }
}

Copy-Item (Join-Path $repositoryRoot 'docs/windows-prototype.md') $outputDirectory
Copy-Item (Join-Path $repositoryRoot 'docs/windows-acceptance.md') $outputDirectory
Copy-Item (Join-Path $repositoryRoot 'docs/acceptance-report.md') $outputDirectory
Copy-Item (Join-Path $repositoryRoot 'scripts/Zommi.WslHook.ps1') $outputDirectory

$executablePath = Join-Path $outputDirectory 'Zommi.exe'
$nativeHostPath = Join-Path $outputDirectory 'resources/native/Zommi.exe'
$hookExecutablePath = Join-Path $outputDirectory 'resources/native/Zommi.Hook.exe'
$wslHookPath = Join-Path $outputDirectory 'Zommi.WslHook.ps1'
$hashPath = Join-Path $outputDirectory 'SHA256SUMS.txt'
if (-not (Test-Path -LiteralPath $executablePath) -or
    -not (Test-Path -LiteralPath $nativeHostPath) -or
    -not (Test-Path -LiteralPath $hookExecutablePath) -or
    -not (Test-Path -LiteralPath $wslHookPath)) {
    throw "The package is incomplete; required runtime files are missing from $outputDirectory."
}
$hash = (Get-FileHash -Algorithm SHA256 $executablePath).Hash.ToLowerInvariant()
$nativeHostHash = (Get-FileHash -Algorithm SHA256 $nativeHostPath).Hash.ToLowerInvariant()
$hookHash = (Get-FileHash -Algorithm SHA256 $hookExecutablePath).Hash.ToLowerInvariant()
$wslHookHash = (Get-FileHash -Algorithm SHA256 $wslHookPath).Hash.ToLowerInvariant()
Set-Content -Path $hashPath -Encoding ascii -Value `
    "$hash  Zommi.exe", `
    "$nativeHostHash  resources/native/Zommi.exe", `
    "$hookHash  resources/native/Zommi.Hook.exe", `
    "$wslHookHash  Zommi.WslHook.ps1"

$archivePath = "$outputDirectory.zip"
$pendingArchivePath = "$outputDirectory.pending.zip"
if (Test-Path $pendingArchivePath) {
    Remove-Item -Force $pendingArchivePath
}

Compress-Archive -Path (Join-Path $outputDirectory '*') -DestinationPath $pendingArchivePath
Move-Item -LiteralPath $pendingArchivePath -Destination $archivePath -Force
Write-Host "Windows prototype published to $outputDirectory"
Write-Host "Portable archive: $archivePath"

if ($DeployToDownloads) {
    & (Join-Path $PSScriptRoot 'deploy-windows-downloads.ps1') -Runtime $Runtime
}
