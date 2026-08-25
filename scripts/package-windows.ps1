[CmdletBinding()]
param(
    [ValidateSet('win-x64', 'win-arm64')]
    [string] $Runtime = 'win-x64',

    [switch] $SkipPublish
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$outputDirectory = Join-Path $repositoryRoot "artifacts/zommi-$Runtime"

if (-not $SkipPublish) {
    dotnet publish (Join-Path $repositoryRoot 'src/Zommi.Windows/Zommi.Windows.csproj') `
        --configuration Release `
        --runtime $Runtime `
        --self-contained true `
        -p:PublishSingleFile=true `
        -p:IncludeNativeLibrariesForSelfExtract=true `
        --output $outputDirectory

    dotnet publish (Join-Path $repositoryRoot 'src/Zommi.Hook/Zommi.Hook.csproj') `
        --configuration Release `
        --runtime $Runtime `
        --self-contained true `
        -p:PublishSingleFile=true `
        -p:IncludeNativeLibrariesForSelfExtract=true `
        --output $outputDirectory
}

Copy-Item (Join-Path $repositoryRoot 'docs/windows-prototype.md') $outputDirectory
Copy-Item (Join-Path $repositoryRoot 'docs/windows-acceptance.md') $outputDirectory
Copy-Item (Join-Path $repositoryRoot 'docs/acceptance-report.md') $outputDirectory
Copy-Item (Join-Path $repositoryRoot 'scripts/Zommi.WslHook.ps1') $outputDirectory

$executablePath = Join-Path $outputDirectory 'Zommi.exe'
$hookExecutablePath = Join-Path $outputDirectory 'Zommi.Hook.exe'
$wslHookPath = Join-Path $outputDirectory 'Zommi.WslHook.ps1'
$hashPath = Join-Path $outputDirectory 'SHA256SUMS.txt'
$hash = (Get-FileHash -Algorithm SHA256 $executablePath).Hash.ToLowerInvariant()
$hookHash = (Get-FileHash -Algorithm SHA256 $hookExecutablePath).Hash.ToLowerInvariant()
$wslHookHash = (Get-FileHash -Algorithm SHA256 $wslHookPath).Hash.ToLowerInvariant()
Set-Content -Path $hashPath -Encoding ascii -Value "$hash  Zommi.exe", "$hookHash  Zommi.Hook.exe", "$wslHookHash  Zommi.WslHook.ps1"

$archivePath = "$outputDirectory.zip"
if (Test-Path $archivePath) {
    Remove-Item -Force $archivePath
}

Compress-Archive -Path (Join-Path $outputDirectory '*') -DestinationPath $archivePath
Write-Host "Windows prototype published to $outputDirectory"
Write-Host "Portable archive: $archivePath"
