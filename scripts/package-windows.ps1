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
$dotnetArtifactsDirectory = Join-Path `
    ([IO.Path]::GetTempPath()) `
    "zommi-dotnet-publish-$([Guid]::NewGuid().ToString('N'))"

if (-not $SkipPublish) {
    try {
        if (Test-Path -LiteralPath $nativeOutputDirectory) {
            Remove-Item -LiteralPath $nativeOutputDirectory -Recurse -Force
        }
        dotnet publish (Join-Path $repositoryRoot 'src/Zommi.Windows/Zommi.Windows.csproj') `
            --configuration Release `
            --runtime $Runtime `
            --self-contained true `
            -p:PublishSingleFile=true `
            -p:IncludeNativeLibrariesForSelfExtract=true `
            --artifacts-path $dotnetArtifactsDirectory `
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
            --artifacts-path $dotnetArtifactsDirectory `
            --output $nativeOutputDirectory
        if ($LASTEXITCODE -ne 0) {
            throw "Zommi Hook publish failed with exit code $LASTEXITCODE."
        }
    }
    finally {
        Remove-Item -LiteralPath $dotnetArtifactsDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }

    $wslPrefix = if ($repositoryRoot.StartsWith('\\wsl.localhost\', [StringComparison]::OrdinalIgnoreCase)) {
        '\\wsl.localhost\'
    }
    elseif ($repositoryRoot.StartsWith('\\wsl$\', [StringComparison]::OrdinalIgnoreCase)) {
        '\\wsl$\'
    }
    else {
        $null
    }
    if ($null -ne $wslPrefix) {
        $wslRelativeRoot = $repositoryRoot.Substring($wslPrefix.Length)
        $distroSeparator = $wslRelativeRoot.IndexOf('\')
        if ($distroSeparator -le 0) {
            throw "Could not resolve the WSL distribution from $repositoryRoot."
        }
        $wslDistro = $wslRelativeRoot.Substring(0, $distroSeparator)
        $linuxRepositoryRoot = $wslRelativeRoot.Substring($distroSeparator).Replace('\', '/')
        $linuxElectronDirectory = "$linuxRepositoryRoot/src/Zommi.Electron"
        $linuxPackager = "$linuxElectronDirectory/scripts/package-electron.mjs"
        $linuxOutputDirectory = "$linuxRepositoryRoot/artifacts/zommi-$Runtime"
        $linuxNativeDirectory = "$linuxRepositoryRoot/artifacts/zommi-native-$Runtime"
        $packageCommand = 'cd "$1" && npm ci && node "$2" --platform "$3" --arch "$4" --output "$5" --native-dir "$6"'
        $architecture = if ($Runtime -eq 'win-arm64') { 'arm64' } else { 'x64' }
        & wsl.exe -d $wslDistro -e sh -lc $packageCommand `
            zommi-package `
            $linuxElectronDirectory `
            $linuxPackager `
            win32 `
            $architecture `
            $linuxOutputDirectory `
            $linuxNativeDirectory
        if ($LASTEXITCODE -ne 0) {
            throw "Electron Windows packaging in WSL failed with exit code $LASTEXITCODE."
        }
    }
    else {
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
}

Copy-Item (Join-Path $repositoryRoot 'docs/windows-prototype.md') $outputDirectory
Copy-Item (Join-Path $repositoryRoot 'docs/windows-acceptance.md') $outputDirectory
Copy-Item (Join-Path $repositoryRoot 'docs/acceptance-report.md') $outputDirectory
Copy-Item (Join-Path $repositoryRoot 'scripts/Zommi.WslHook.ps1') $outputDirectory

$executablePath = Join-Path $outputDirectory 'Zommi.exe'
$nativeHostPath = Join-Path $outputDirectory 'resources/native/Zommi.exe'
$hookExecutablePath = Join-Path $outputDirectory 'resources/native/Zommi.Hook.exe'
$codexBridgePath = Join-Path $outputDirectory 'resources/app/codex-bridge.mjs'
$electronMainPath = Join-Path $outputDirectory 'resources/app/main.mjs'
$rendererPath = Join-Path $outputDirectory 'resources/app/renderer/renderer.mjs'
$wslHookPath = Join-Path $outputDirectory 'Zommi.WslHook.ps1'
$hashPath = Join-Path $outputDirectory 'SHA256SUMS.txt'
if (-not (Test-Path -LiteralPath $executablePath) -or
    -not (Test-Path -LiteralPath $nativeHostPath) -or
    -not (Test-Path -LiteralPath $hookExecutablePath) -or
    -not (Test-Path -LiteralPath $codexBridgePath) -or
    -not (Test-Path -LiteralPath $electronMainPath) -or
    -not (Test-Path -LiteralPath $rendererPath) -or
    -not (Test-Path -LiteralPath $wslHookPath)) {
    throw "The package is incomplete; required runtime files are missing from $outputDirectory."
}
$hash = (Get-FileHash -Algorithm SHA256 $executablePath).Hash.ToLowerInvariant()
$nativeHostHash = (Get-FileHash -Algorithm SHA256 $nativeHostPath).Hash.ToLowerInvariant()
$hookHash = (Get-FileHash -Algorithm SHA256 $hookExecutablePath).Hash.ToLowerInvariant()
$codexBridgeHash = (Get-FileHash -Algorithm SHA256 $codexBridgePath).Hash.ToLowerInvariant()
$electronMainHash = (Get-FileHash -Algorithm SHA256 $electronMainPath).Hash.ToLowerInvariant()
$rendererHash = (Get-FileHash -Algorithm SHA256 $rendererPath).Hash.ToLowerInvariant()
$wslHookHash = (Get-FileHash -Algorithm SHA256 $wslHookPath).Hash.ToLowerInvariant()
Set-Content -Path $hashPath -Encoding ascii -Value `
    "$hash  Zommi.exe", `
    "$nativeHostHash  resources/native/Zommi.exe", `
    "$hookHash  resources/native/Zommi.Hook.exe", `
    "$codexBridgeHash  resources/app/codex-bridge.mjs", `
    "$electronMainHash  resources/app/main.mjs", `
    "$rendererHash  resources/app/renderer/renderer.mjs", `
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
