[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $ExecutablePath,

    [switch] $SkipBrowser,

    [switch] $SkipHoverPreview,

    [switch] $SkipSessionUi,

    [switch] $SkipPointerImmobility,

    [switch] $KeepTemporaryArtifacts,

    [switch] $UseCaptureTrigger,

    [int] $MaxContextLatencyMilliseconds = 1500,

    [int] $MaxFirstAgentOutputMilliseconds = 10000,

    [int] $MaxResponseMilliseconds = 30000
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$resolvedExecutable = [IO.Path]::GetFullPath($ExecutablePath)
$nativeHost = Join-Path (Split-Path -Parent $resolvedExecutable) 'resources/native/Zommi.exe'
if (-not (Test-Path -LiteralPath $nativeHost -PathType Leaf)) {
    throw 'The legacy standalone Windows relay was removed. Pass the packaged Electron Zommi.exe.'
}

& (Join-Path $PSScriptRoot 'test-windows-electron-runtime.ps1') @PSBoundParameters
