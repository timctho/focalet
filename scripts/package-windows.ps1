[CmdletBinding()]
param(
    [ValidateSet('win-x64', 'win-arm64')]
    [string] $Runtime = 'win-x64',

    [switch] $SkipBuild,

    [switch] $DeployToDownloads,

    [string] $SigningThumbprint = $env:ZOMMI_WINDOWS_SIGNING_THUMBPRINT
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$flutterDirectory = Join-Path $repositoryRoot 'src/Zommi.Flutter'
$architecture = if ($Runtime -eq 'win-arm64') { 'arm64' } else { 'x64' }
$rustTarget = if ($Runtime -eq 'win-arm64') { 'aarch64-pc-windows-msvc' } else { 'x86_64-pc-windows-msvc' }
$flutterOutput = Join-Path $flutterDirectory "build/windows/$architecture/runner/Release"
$cargoTargetRoot = if ([string]::IsNullOrWhiteSpace($env:CARGO_TARGET_DIR)) {
    Join-Path $repositoryRoot 'target'
}
else {
    [IO.Path]::GetFullPath($env:CARGO_TARGET_DIR)
}
$rustCore = Join-Path $cargoTargetRoot "$rustTarget/release/zommi-core-host.exe"
$captureOutput = Join-Path $repositoryRoot "artifacts/zommi-capture-$Runtime"
$packageDirectory = Join-Path $repositoryRoot "artifacts/zommi-windows-$architecture"
$gitCommit = (git -C $repositoryRoot rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $gitCommit -notmatch '^[0-9a-f]{40}$') {
    throw 'Could not resolve the exact source revision for the release manifest.'
}

if ($DeployToDownloads) {
    git -C $repositoryRoot fetch --quiet --no-tags origin main
    if ($LASTEXITCODE -ne 0) {
        throw 'Could not refresh origin/main before Downloads deployment.'
    }
    $baseline = (git -C $repositoryRoot rev-parse --verify refs/remotes/origin/main).Trim()
    git -C $repositoryRoot merge-base --is-ancestor $baseline $gitCommit
    if ($LASTEXITCODE -ne 0) {
        throw "Refusing deployment from stale source $gitCommit; latest origin/main is $baseline."
    }
}

if (-not $SkipBuild) {
    Push-Location $flutterDirectory
    try {
        flutter pub get
        if ($LASTEXITCODE -ne 0) {
            throw "Flutter dependency restore failed with exit code $LASTEXITCODE."
        }
        $flutterArguments = @('build', 'windows', '--release', '--no-pub', "--dart-define=ZOMMI_BUILD_REVISION=$gitCommit")
        if ($Runtime -eq 'win-arm64') {
            $flutterArguments += '--target-platform=windows-arm64'
        }

        if (-not [string]::IsNullOrWhiteSpace($env:CMAKE_GENERATOR_INSTANCE)) {
            $generatorInstance = [IO.Path]::GetFullPath($env:CMAKE_GENERATOR_INSTANCE)
            $cmake = Join-Path $generatorInstance 'Common7/IDE/CommonExtensions/Microsoft/CMake/CMake/bin/cmake.exe'
            if (-not (Test-Path -LiteralPath $cmake -PathType Leaf)) {
                throw "CMake was not found in the requested Visual Studio instance: $generatorInstance"
            }

            # Flutter generates its ephemeral CMake inputs only through its own
            # build command. Configure once, replace the auto-selected instance,
            # and leave that authoritative cache for the real build below.
            & flutter @flutterArguments --config-only
            if ($LASTEXITCODE -ne 0) {
                throw "Flutter Windows configuration failed with exit code $LASTEXITCODE."
            }

            $windowsBuild = Join-Path $flutterDirectory "build/windows/$architecture"
            if (Test-Path -LiteralPath $windowsBuild) {
                Remove-Item -LiteralPath $windowsBuild -Recurse -Force
            }
            $generator = if ([string]::IsNullOrWhiteSpace($env:CMAKE_GENERATOR)) {
                'Visual Studio 17 2022'
            }
            else {
                $env:CMAKE_GENERATOR
            }
            $cmakeArchitecture = if ($Runtime -eq 'win-arm64') { 'ARM64' } else { 'x64' }
            $flutterTarget = if ($Runtime -eq 'win-arm64') { 'windows-arm64' } else { 'windows-x64' }
            & $cmake `
                -S (Join-Path $flutterDirectory 'windows') `
                -B $windowsBuild `
                -G $generator `
                -A $cmakeArchitecture `
                "-DCMAKE_GENERATOR_INSTANCE=$generatorInstance" `
                "-DFLUTTER_TARGET_PLATFORM=$flutterTarget"
            if ($LASTEXITCODE -ne 0) {
                throw "Visual Studio CMake configuration failed with exit code $LASTEXITCODE."
            }

            $cache = Join-Path $windowsBuild 'CMakeCache.txt'
            $cacheEntry = Get-Content -LiteralPath $cache |
                Where-Object { $_ -match '^CMAKE_GENERATOR_INSTANCE:[^=]+=' } |
                Select-Object -First 1
            if ([string]::IsNullOrWhiteSpace($cacheEntry)) {
                throw 'CMake did not record the requested Visual Studio instance.'
            }
            $actualInstance = ($cacheEntry -replace '^CMAKE_GENERATOR_INSTANCE:[^=]+=', '').Replace('\', '/')
            $expectedInstance = $generatorInstance.Replace('\', '/')
            if (-not [string]::Equals($actualInstance, $expectedInstance, [StringComparison]::OrdinalIgnoreCase)) {
                throw "CMake selected '$actualInstance' instead of '$expectedInstance'."
            }
        }

        & flutter @flutterArguments
        if ($LASTEXITCODE -ne 0) {
            throw "Flutter Windows build failed with exit code $LASTEXITCODE."
        }
    }
    finally {
        Pop-Location
    }

    cargo build `
        --manifest-path (Join-Path $repositoryRoot 'Cargo.toml') `
        --release `
        --bin zommi-core-host `
        --target $rustTarget
    if ($LASTEXITCODE -ne 0) {
        throw "Rust core build failed with exit code $LASTEXITCODE."
    }

    if (Test-Path -LiteralPath $captureOutput) {
        Remove-Item -LiteralPath $captureOutput -Recurse -Force
    }
    # Keep runner-level disabled sources from silently removing the repository
    # feed, while allowing managed hosts to select their approved feed proxy.
    $nuGetArguments = @('--configfile', (Join-Path $repositoryRoot 'NuGet.config'))
    if (-not [string]::IsNullOrWhiteSpace($env:ZOMMI_NUGET_SOURCE)) {
        $nuGetArguments += @('--source', $env:ZOMMI_NUGET_SOURCE)
    }
    dotnet publish (Join-Path $repositoryRoot 'src/Zommi.Windows/Zommi.Windows.csproj') `
        @nuGetArguments `
        --configuration Release `
        --runtime $Runtime `
        --self-contained true `
        -p:PublishSingleFile=true `
        -p:DebugType=None `
        --output $captureOutput
    if ($LASTEXITCODE -ne 0) {
        throw "Windows capture helper publish failed with exit code $LASTEXITCODE."
    }
}

$captureExecutable = Join-Path $captureOutput 'Zommi.Capture.exe'
foreach ($required in @($flutterOutput, $rustCore, $captureExecutable)) {
    if (-not (Test-Path -LiteralPath $required)) {
        throw "Release input is missing: $required"
    }
}

$signingStatus = 'unsigned'
$signingMechanism = 'none'
if (-not [string]::IsNullOrWhiteSpace($SigningThumbprint)) {
    $signTool = (Get-Command signtool.exe -ErrorAction Stop).Source
    $signingInputs = @(
        Get-ChildItem -LiteralPath $flutterOutput -Recurse -File |
            Where-Object { $_.Extension -in @('.exe', '.dll') }
        Get-Item -LiteralPath $rustCore
        Get-ChildItem -LiteralPath $captureOutput -Recurse -File |
            Where-Object { $_.Extension -in @('.exe', '.dll') }
    )
    foreach ($inputFile in $signingInputs) {
        & $signTool sign /sha1 $SigningThumbprint /fd SHA256 /tr http://timestamp.digicert.com /td SHA256 $inputFile.FullName
        if ($LASTEXITCODE -ne 0) {
            throw "Authenticode signing failed for $($inputFile.FullName)."
        }
    }
    $signingStatus = 'distribution-signed'
    $signingMechanism = 'authenticode'
}

$python = (Get-Command python.exe -ErrorAction SilentlyContinue).Source
if ([string]::IsNullOrWhiteSpace($python)) {
    $python = (Get-Command python -ErrorAction Stop).Source
}
$assemblerArguments = @(
    (Join-Path $repositoryRoot 'scripts/assemble_release.py'),
    '--platform', 'windows',
    '--architecture', $architecture,
    '--flutter-output', $flutterOutput,
    '--core-host', $rustCore,
    '--capture-host', $captureOutput,
    '--output-root', (Join-Path $repositoryRoot 'artifacts'),
    '--git-commit', $gitCommit,
    '--document', (Join-Path $repositoryRoot 'README.md'),
    '--document', (Join-Path $repositoryRoot 'docs/install.md'),
    '--signing-status', $signingStatus,
    '--signing-mechanism', $signingMechanism
)
& $python @assemblerArguments
if ($LASTEXITCODE -ne 0) {
    throw "Windows release assembly failed with exit code $LASTEXITCODE."
}

& $python `
    (Join-Path $repositoryRoot 'scripts/verify_release.py') `
    $packageDirectory `
    --expected-platform windows `
    --expected-commit $gitCommit
if ($LASTEXITCODE -ne 0) {
    throw "Windows release verification failed with exit code $LASTEXITCODE."
}

if ($signingStatus -eq 'distribution-signed') {
    foreach ($relative in @('Zommi.exe', 'zommi-core-host.exe', 'native/Zommi.Capture.exe')) {
        $signature = Get-AuthenticodeSignature (Join-Path $packageDirectory $relative)
        if ($signature.Status -ne [System.Management.Automation.SignatureStatus]::Valid) {
            throw "Authenticode verification failed for ${relative}: $($signature.Status)."
        }
    }
}

Write-Host "Flutter + Rust Windows release published to $packageDirectory"

if ($DeployToDownloads) {
    & (Join-Path $PSScriptRoot 'deploy-windows-downloads.ps1') -Runtime $Runtime
}
