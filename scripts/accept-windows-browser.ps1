[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $PackageDirectory,
    [string] $BrowserExecutable = (Join-Path $env:ProgramFiles 'Google\Chrome\Application\chrome.exe'),
    [string] $ResultDirectory
)

$ErrorActionPreference = 'Stop'
$repository = Split-Path -Parent $PSScriptRoot
$capture = Join-Path $PackageDirectory 'native\Zommi.Capture.exe'
if (-not (Test-Path -LiteralPath $capture)) { throw 'The packaged Windows capture helper is missing.' }
if (-not (Test-Path -LiteralPath $BrowserExecutable)) { throw 'Provide a Chromium browser executable for the Windows DOM capture gate.' }
if ([string]::IsNullOrWhiteSpace($ResultDirectory)) {
    $ResultDirectory = Join-Path $repository 'artifacts\windows-browser-acceptance'
}
$previousHeadful = $env:ZOMMI_BROWSER_TEST_HEADFUL
$previousCapture = $env:ZOMMI_TEST_CAPTURE_HOST
try {
    $env:ZOMMI_BROWSER_TEST_HEADFUL = '1'
    $env:ZOMMI_TEST_CAPTURE_HOST = (Resolve-Path -LiteralPath $capture).ProviderPath
    & dotnet run --project (Join-Path $repository 'tests\Zommi.Browser.Tests') --configuration Release -- $BrowserExecutable $ResultDirectory
    if ($LASTEXITCODE -ne 0) { throw "Windows browser capture interactions failed: $LASTEXITCODE" }
    $identity = @{
        captureHostSha256 = (Get-FileHash -LiteralPath $capture -Algorithm SHA256).Hash.ToLowerInvariant()
        browserExecutable = $BrowserExecutable
        testedAtUtc = [DateTime]::UtcNow.ToString('o')
        scope = 'Native HWND and viewport binding plus real browser mouse/keyboard/DOM/compositor interactions; excludes Windows desktop input and GDI acceptance.'
    }
    $identity | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $ResultDirectory 'package-identity.json') -Encoding utf8
} finally {
    $env:ZOMMI_BROWSER_TEST_HEADFUL = $previousHeadful
    $env:ZOMMI_TEST_CAPTURE_HOST = $previousCapture
}
