[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $PackageDirectory,
    [string] $BrowserExecutable = (Join-Path $env:ProgramFiles 'Google\Chrome\Application\chrome.exe'),
    [string] $ResultDirectory
)

$ErrorActionPreference = 'Stop'
$repository = Split-Path -Parent $PSScriptRoot
$capture = Join-Path $PackageDirectory 'native\Focalet.CaptureHost.exe'
if (-not (Test-Path -LiteralPath $capture)) { throw 'The packaged Windows capture helper is missing.' }
if (-not (Test-Path -LiteralPath $BrowserExecutable)) { throw 'Provide a Chromium browser executable for the Windows DOM capture gate.' }
if ([string]::IsNullOrWhiteSpace($ResultDirectory)) {
    $ResultDirectory = Join-Path $repository 'artifacts\windows-browser-acceptance'
}
$previousHeadful = $env:FOCALET_BROWSER_TEST_HEADFUL
$previousCapture = $env:FOCALET_TEST_CAPTURE_HOST
try {
    $env:FOCALET_BROWSER_TEST_HEADFUL = '1'
    $env:FOCALET_TEST_CAPTURE_HOST = (Resolve-Path -LiteralPath $capture).ProviderPath
    & dotnet run --project (Join-Path $repository 'tests\Focalet.Browser.Tests') --configuration Release -- $BrowserExecutable $ResultDirectory
    if ($LASTEXITCODE -ne 0) { throw "Windows browser capture interactions failed: $LASTEXITCODE" }
    $identity = @{
        captureHostSha256 = (Get-FileHash -LiteralPath $capture -Algorithm SHA256).Hash.ToLowerInvariant()
        browserExecutable = $BrowserExecutable
        testedAtUtc = [DateTime]::UtcNow.ToString('o')
        scope = 'Native HWND/viewport binding, shared-helper Ctrl batches driven by native pointer input, GDI crops and live browser DOM/CDP interactions. Packaged app gestures are covered by accept-windows-capture.ps1.'
    }
    $identity | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $ResultDirectory 'package-identity.json') -Encoding utf8
} finally {
    $env:FOCALET_BROWSER_TEST_HEADFUL = $previousHeadful
    $env:FOCALET_TEST_CAPTURE_HOST = $previousCapture
}
