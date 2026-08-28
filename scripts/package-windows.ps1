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
            --artifacts-path $dotnetArtifactsDirectory `
            --output $nativeOutputDirectory
        if ($LASTEXITCODE -ne 0) {
            throw "Zommi Windows publish failed with exit code $LASTEXITCODE."
        }

        dotnet publish (Join-Path $repositoryRoot 'src/Zommi.Hook/Zommi.Hook.csproj') `
            --configuration Release `
            --runtime $Runtime `
            --self-contained true `
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
$runtimeCatalogPath = Join-Path $outputDirectory 'resources/app/runtime-catalog.mjs'
$runtimeDiscoveryPath = Join-Path $outputDirectory 'resources/app/runtime-discovery.mjs'
$runtimeSettingsPath = Join-Path $outputDirectory 'resources/app/runtime-settings.mjs'
$runtimeBrokerPath = Join-Path $outputDirectory 'resources/app/runtime-broker.mjs'
$brokerProtocolPath = Join-Path $outputDirectory 'resources/app/broker-protocol.mjs'
$contextHandoffPath = Join-Path $outputDirectory 'resources/app/context-handoff.mjs'
$protocolFramingPath = Join-Path $outputDirectory 'resources/app/protocol-framing.mjs'
$adapterDiagnosticsPath = Join-Path $outputDirectory 'resources/app/adapter-diagnostics.mjs'
$transportMetricsPath = Join-Path $outputDirectory 'resources/app/transport-metrics.mjs'
$hermesGatewayAdapterPath = Join-Path $outputDirectory 'resources/app/hermes-gateway-adapter.mjs'
$openClawGatewayAdapterPath = Join-Path $outputDirectory 'resources/app/openclaw-gateway-adapter.mjs'
$ptyCompatibilityAdapterPath = Join-Path $outputDirectory 'resources/app/pty-compatibility-adapter.mjs'
$ptyProfilesPath = Join-Path $outputDirectory 'resources/app/pty-profiles.mjs'
$acpAdapterPath = Join-Path $outputDirectory 'resources/app/acp-adapter.mjs'
$piRpcAdapterPath = Join-Path $outputDirectory 'resources/app/pi-rpc-adapter.mjs'
$electronMainPath = Join-Path $outputDirectory 'resources/app/main.mjs'
$preloadPath = Join-Path $outputDirectory 'resources/app/preload.cjs'
$windowLayoutPath = Join-Path $outputDirectory 'resources/app/window-layout.mjs'
$rendererHtmlPath = Join-Path $outputDirectory 'resources/app/renderer/index.html'
$rendererPath = Join-Path $outputDirectory 'resources/app/renderer/renderer.mjs'
$rendererStylesPath = Join-Path $outputDirectory 'resources/app/renderer/styles.css'
$wslHookPath = Join-Path $outputDirectory 'Zommi.WslHook.ps1'
$hashPath = Join-Path $outputDirectory 'SHA256SUMS.txt'
if (-not (Test-Path -LiteralPath $executablePath) -or
    -not (Test-Path -LiteralPath $nativeHostPath) -or
    -not (Test-Path -LiteralPath $hookExecutablePath) -or
    -not (Test-Path -LiteralPath $codexBridgePath) -or
    -not (Test-Path -LiteralPath $runtimeCatalogPath) -or
    -not (Test-Path -LiteralPath $runtimeDiscoveryPath) -or
    -not (Test-Path -LiteralPath $runtimeSettingsPath) -or
    -not (Test-Path -LiteralPath $runtimeBrokerPath) -or
    -not (Test-Path -LiteralPath $brokerProtocolPath) -or
    -not (Test-Path -LiteralPath $contextHandoffPath) -or
    -not (Test-Path -LiteralPath $protocolFramingPath) -or
    -not (Test-Path -LiteralPath $adapterDiagnosticsPath) -or
    -not (Test-Path -LiteralPath $transportMetricsPath) -or
    -not (Test-Path -LiteralPath $hermesGatewayAdapterPath) -or
    -not (Test-Path -LiteralPath $openClawGatewayAdapterPath) -or
    -not (Test-Path -LiteralPath $ptyCompatibilityAdapterPath) -or
    -not (Test-Path -LiteralPath $ptyProfilesPath) -or
    -not (Test-Path -LiteralPath $acpAdapterPath) -or
    -not (Test-Path -LiteralPath $piRpcAdapterPath) -or
    -not (Test-Path -LiteralPath $electronMainPath) -or
    -not (Test-Path -LiteralPath $preloadPath) -or
    -not (Test-Path -LiteralPath $windowLayoutPath) -or
    -not (Test-Path -LiteralPath $rendererHtmlPath) -or
    -not (Test-Path -LiteralPath $rendererPath) -or
    -not (Test-Path -LiteralPath $rendererStylesPath) -or
    -not (Test-Path -LiteralPath $wslHookPath)) {
    throw "The package is incomplete; required runtime files are missing from $outputDirectory."
}
$hash = (Get-FileHash -Algorithm SHA256 $executablePath).Hash.ToLowerInvariant()
$nativeHostHash = (Get-FileHash -Algorithm SHA256 $nativeHostPath).Hash.ToLowerInvariant()
$hookHash = (Get-FileHash -Algorithm SHA256 $hookExecutablePath).Hash.ToLowerInvariant()
$codexBridgeHash = (Get-FileHash -Algorithm SHA256 $codexBridgePath).Hash.ToLowerInvariant()
$runtimeCatalogHash = (Get-FileHash -Algorithm SHA256 $runtimeCatalogPath).Hash.ToLowerInvariant()
$runtimeDiscoveryHash = (Get-FileHash -Algorithm SHA256 $runtimeDiscoveryPath).Hash.ToLowerInvariant()
$runtimeSettingsHash = (Get-FileHash -Algorithm SHA256 $runtimeSettingsPath).Hash.ToLowerInvariant()
$runtimeBrokerHash = (Get-FileHash -Algorithm SHA256 $runtimeBrokerPath).Hash.ToLowerInvariant()
$brokerProtocolHash = (Get-FileHash -Algorithm SHA256 $brokerProtocolPath).Hash.ToLowerInvariant()
$contextHandoffHash = (Get-FileHash -Algorithm SHA256 $contextHandoffPath).Hash.ToLowerInvariant()
$protocolFramingHash = (Get-FileHash -Algorithm SHA256 $protocolFramingPath).Hash.ToLowerInvariant()
$adapterDiagnosticsHash = (Get-FileHash -Algorithm SHA256 $adapterDiagnosticsPath).Hash.ToLowerInvariant()
$transportMetricsHash = (Get-FileHash -Algorithm SHA256 $transportMetricsPath).Hash.ToLowerInvariant()
$hermesGatewayAdapterHash = (Get-FileHash -Algorithm SHA256 $hermesGatewayAdapterPath).Hash.ToLowerInvariant()
$openClawGatewayAdapterHash = (Get-FileHash -Algorithm SHA256 $openClawGatewayAdapterPath).Hash.ToLowerInvariant()
$ptyCompatibilityAdapterHash = (Get-FileHash -Algorithm SHA256 $ptyCompatibilityAdapterPath).Hash.ToLowerInvariant()
$ptyProfilesHash = (Get-FileHash -Algorithm SHA256 $ptyProfilesPath).Hash.ToLowerInvariant()
$acpAdapterHash = (Get-FileHash -Algorithm SHA256 $acpAdapterPath).Hash.ToLowerInvariant()
$piRpcAdapterHash = (Get-FileHash -Algorithm SHA256 $piRpcAdapterPath).Hash.ToLowerInvariant()
$electronMainHash = (Get-FileHash -Algorithm SHA256 $electronMainPath).Hash.ToLowerInvariant()
$preloadHash = (Get-FileHash -Algorithm SHA256 $preloadPath).Hash.ToLowerInvariant()
$windowLayoutHash = (Get-FileHash -Algorithm SHA256 $windowLayoutPath).Hash.ToLowerInvariant()
$rendererHtmlHash = (Get-FileHash -Algorithm SHA256 $rendererHtmlPath).Hash.ToLowerInvariant()
$rendererHash = (Get-FileHash -Algorithm SHA256 $rendererPath).Hash.ToLowerInvariant()
$rendererStylesHash = (Get-FileHash -Algorithm SHA256 $rendererStylesPath).Hash.ToLowerInvariant()
$wslHookHash = (Get-FileHash -Algorithm SHA256 $wslHookPath).Hash.ToLowerInvariant()
Set-Content -Path $hashPath -Encoding ascii -Value `
    "$hash  Zommi.exe", `
    "$nativeHostHash  resources/native/Zommi.exe", `
    "$hookHash  resources/native/Zommi.Hook.exe", `
    "$codexBridgeHash  resources/app/codex-bridge.mjs", `
    "$runtimeCatalogHash  resources/app/runtime-catalog.mjs", `
    "$runtimeDiscoveryHash  resources/app/runtime-discovery.mjs", `
    "$runtimeSettingsHash  resources/app/runtime-settings.mjs", `
    "$runtimeBrokerHash  resources/app/runtime-broker.mjs", `
    "$brokerProtocolHash  resources/app/broker-protocol.mjs", `
    "$contextHandoffHash  resources/app/context-handoff.mjs", `
    "$protocolFramingHash  resources/app/protocol-framing.mjs", `
    "$adapterDiagnosticsHash  resources/app/adapter-diagnostics.mjs", `
    "$transportMetricsHash  resources/app/transport-metrics.mjs", `
    "$hermesGatewayAdapterHash  resources/app/hermes-gateway-adapter.mjs", `
    "$openClawGatewayAdapterHash  resources/app/openclaw-gateway-adapter.mjs", `
    "$ptyCompatibilityAdapterHash  resources/app/pty-compatibility-adapter.mjs", `
    "$ptyProfilesHash  resources/app/pty-profiles.mjs", `
    "$acpAdapterHash  resources/app/acp-adapter.mjs", `
    "$piRpcAdapterHash  resources/app/pi-rpc-adapter.mjs", `
    "$electronMainHash  resources/app/main.mjs", `
    "$preloadHash  resources/app/preload.cjs", `
    "$windowLayoutHash  resources/app/window-layout.mjs", `
    "$rendererHtmlHash  resources/app/renderer/index.html", `
    "$rendererHash  resources/app/renderer/renderer.mjs", `
    "$rendererStylesHash  resources/app/renderer/styles.css", `
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
