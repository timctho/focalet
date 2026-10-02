[CmdletBinding()]
param([ValidateSet('win-x64', 'win-arm64')][string]$Runtime = 'win-x64')

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$commit = (git -C $root rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0) { throw 'Could not read the source revision.' }
if (git -C $root status --porcelain --untracked-files=normal) { throw 'Commit the source changes before packaging.' }
$output = Join-Path $root "artifacts/zommi-capture-tool-$Runtime"
if (Test-Path -LiteralPath $output) { Remove-Item -LiteralPath $output -Recurse -Force }
$nuget = @('--configfile', (Join-Path $root 'NuGet.config'))
if ($env:ZOMMI_NUGET_SOURCE) { $nuget += @('--source', $env:ZOMMI_NUGET_SOURCE) }
dotnet publish (Join-Path $root 'src/Zommi.CaptureTool/Zommi.CaptureTool.csproj') @nuget `
    --configuration Release --runtime $Runtime --self-contained true `
    -p:PublishSingleFile=true -p:DebugType=None --output $output
if ($LASTEXITCODE -ne 0) { throw 'Capture tool build failed.' }
foreach ($name in @('LICENSE', 'THIRD_PARTY_NOTICES.md')) { Copy-Item (Join-Path $root $name) $output }
Copy-Item (Join-Path $root 'docs/capture-tool.md') (Join-Path $output 'README.md')
$manifest = @{
    product = 'Zommi Capture'; channel = 'prototype'; gitCommit = $commit; runtime = $Runtime
    entryPoint = 'Zommi.CaptureTool.exe'; signing = 'unsigned'
}
$manifest | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $output 'capture-tool-manifest.json') -Encoding utf8
$files = Get-ChildItem -LiteralPath $output -File -Recurse | Sort-Object FullName
$hashes = foreach ($file in $files) {
    $relative = [IO.Path]::GetRelativePath($output, $file.FullName).Replace('\', '/')
    "$( (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant() )  $relative"
}
$hashes | Set-Content -LiteralPath (Join-Path $output 'SHA256SUMS.txt') -Encoding ascii
$archive = "$output.zip"
Compress-Archive -LiteralPath $output -DestinationPath $archive -Force
Write-Host "Capture tool: $archive"
