[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$CaptureHost, [string]$ResultPath, [switch]$IndependentWorkerOnly)
$ErrorActionPreference = 'Stop'
if (-not ('ZommiWindowsAcceptanceNative' -as [type])) {
    . (Join-Path $PSScriptRoot 'accept-windows-capture.ps1') -PackageDirectory (Split-Path $CaptureHost) -HelpersOnly -ResultPath $ResultPath
}
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
if (-not ('ZommiContextFixture' -as [type])) {
    $references = @([System.Windows.Forms.Form].Assembly.Location, [System.Drawing.Bitmap].Assembly.Location)
    if ($PSVersionTable.PSEdition -eq 'Core') { $references += Get-ChildItem (Join-Path $PSHOME 'ref') -Filter '*.dll' | ForEach-Object FullName }
    Add-Type -ReferencedAssemblies $references -Path (Join-Path $PSScriptRoot 'windows-context-fixture.cs')
}
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class ZommiMultiInput {
    [DllImport("user32.dll")] private static extern void keybd_event(byte key, byte scan, uint flags, UIntPtr extra);
    [DllImport("user32.dll")] private static extern bool PostMessage(IntPtr window, uint message, IntPtr key, IntPtr data);
    public static void Control(bool down) { keybd_event(0x11, 0, down ? 0u : 2u, UIntPtr.Zero); System.Threading.Thread.Sleep(40); }
    public static void Enter(IntPtr window) { PostMessage(window, 0x100, new IntPtr(13), IntPtr.Zero); PostMessage(window, 0x101, new IntPtr(13), IntPtr.Zero); }
}
'@
function Wait-MultiOutline([int]$X, [int]$Y) {
    $deadline = [DateTime]::UtcNow.AddSeconds(4)
    do {
        if ([ZommiWindowsAcceptanceNative]::HasSelectionEdge($X,$Y,$true)) { return }
        Start-Sleep -Milliseconds 25
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Queued mint outline missing at ${X},${Y}."
}
Assert-DesktopCaptureSurface
# A single helper must show its modal selector while its MTA is blocked in UIA.
if ($IndependentWorkerOnly) {
    $fixture = [ZommiContextFixture]::new()
    $shared = $null
    try {
        $fixture.Raise()
        $start = [System.Diagnostics.ProcessStartInfo]::new($CaptureHost)
        $start.ArgumentList.Add('--capture-host')
        $start.UseShellExecute = $false
        $start.CreateNoWindow = $true
        $start.RedirectStandardInput = $true
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        $shared = [System.Diagnostics.Process]::Start($start)
        $errors = $shared.StandardError.ReadToEndAsync()
        # Measure contention in an initialized host, not cold .NET/UNC startup.
        $shared.StandardInput.WriteLine('{"id":"ready","method":"ping"}')
        $shared.StandardInput.Flush()
        $ready = $shared.StandardOutput.ReadLineAsync().WaitAsync([TimeSpan]::FromSeconds(10)).GetAwaiter().GetResult() | ConvertFrom-Json
        if ($ready.id -ne 'ready' -or $ready.ok -ne $true) { throw 'The shared host did not initialize.' }
        $fixture.PauseProvider(1800)
        $shared.StandardInput.WriteLine('{"id":"slow","method":"capture","params":{"browserPageDetails":false,"point":{"x":220,"y":220}}}')
        $shared.StandardInput.Flush()
        Start-Sleep -Milliseconds 150
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $shared.StandardInput.WriteLine('{"id":"select","method":"selectContent","params":{"browserPageDetails":false}}')
        $shared.StandardInput.Flush()
        $selector = Wait-ForWindow -ProcessId $shared.Id -Title 'Zommi content selection'
        if ($watch.ElapsedMilliseconds -gt 1200) { throw "The shared-host selector took $($watch.ElapsedMilliseconds) ms while the UIA worker was busy (limit 1200 ms)." }
        [ZommiWindowsAcceptanceNative]::CancelSelection($selector) | Out-Null
        $responses = @{}
        while (-not $responses.ContainsKey('select')) {
            $remaining = 1200 - $watch.ElapsedMilliseconds
            if ($remaining -le 0) { throw 'Slow capture blocked the independent selector response.' }
            $response = $shared.StandardOutput.ReadLineAsync().WaitAsync([TimeSpan]::FromMilliseconds($remaining)).GetAwaiter().GetResult() | ConvertFrom-Json
            $responses[$response.id] = $response
        }
        if ($responses.select.ok -ne $true -or $responses.select.result.cancelled -ne $true) { throw 'The independent selector did not cancel.' }
        # A provider timeout can finish before selection. Correlate replies by ID;
        # the measured selector deadline, not reply order, proves responsiveness.
        if (-not $responses.ContainsKey('slow')) {
            $response = $shared.StandardOutput.ReadLineAsync().WaitAsync([TimeSpan]::FromSeconds(8)).GetAwaiter().GetResult() | ConvertFrom-Json
            $responses[$response.id] = $response
        }
        $slow = $responses.slow
        if (-not $slow -or ($slow.ok -ne $true -and [string]::IsNullOrWhiteSpace($slow.error))) { throw 'The shared host lost the slow capture response.' }
        # A deliberately frozen provider may time out. After it recovers, the same
        # helper must still complete a fresh capture without restarting Chrome.
        $fixture.WaitForProvider()
        $shared.StandardInput.WriteLine('{"id":"recovered","method":"capture","params":{"browserPageDetails":false,"point":{"x":220,"y":220}}}')
        $shared.StandardInput.Flush()
        $recovered = $shared.StandardOutput.ReadLineAsync().WaitAsync([TimeSpan]::FromSeconds(8)).GetAwaiter().GetResult() | ConvertFrom-Json
        if ($recovered.id -ne 'recovered' -or $recovered.ok -ne $true) { throw "The text worker did not recover after the provider timeout: $($recovered.error)" }
        Write-Host 'shared-host-independent-workers: ok'
    } finally {
        if ($shared -and -not $shared.HasExited) { $shared.Kill($true); $shared.WaitForExit() }
        $fixture.Dispose()
    }
    return
}
$cases = @('duplicates', 'rectangles', 'rapid', 'rapid-release', 'cancel', 'changed')
$results = @()
foreach ($case in $cases) {
    $fixture = [ZommiContextFixture]::new()
    try {
        $fixture.Raise()
        Start-Sleep -Milliseconds 200
        $result = Invoke-CaptureRequest -Executable $CaptureHost -Method 'selectContent' -Parameters @{browserPageDetails=$false} -Interact {
            param($process)
            $selector = Wait-ForWindow -ProcessId $process.Id -Title 'Zommi content selection'
            [ZommiWindowsAcceptanceNative]::SetPhysicalCursorPos(220,220) | Out-Null
            $deadline = [DateTime]::UtcNow.AddSeconds(5)
            while (-not [ZommiWindowsAcceptanceNative]::NamedButtonEnabled($selector,'Cancel') -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 25 }
            if (-not [ZommiWindowsAcceptanceNative]::NamedButtonEnabled($selector,'Cancel')) { throw 'Rectangle selector unavailable.' }
            [ZommiMultiInput]::Control($true)
            try {
                if ($case -in @('rapid','rapid-release')) {
                    $fixture.PauseProvider(600)
                    # Rapid rectangles must retain order without UIA lookups while dragging.
                    [ZommiWindowsAcceptanceNative]::BeginSelectionDrag($selector,510,355,528,373) | Out-Null
                    [ZommiWindowsAcceptanceNative]::EndSelectionDrag($selector,528,373)
                    if ($case -eq 'rapid-release') { [ZommiMultiInput]::Control($false) }
                    [ZommiWindowsAcceptanceNative]::BeginSelectionDrag($selector,534,355,552,373) | Out-Null
                    [ZommiWindowsAcceptanceNative]::EndSelectionDrag($selector,552,373)
                } elseif ($case -eq 'rectangles') {
                    [ZommiWindowsAcceptanceNative]::DragPhysicalSelection($selector,180,200,530,240)
                    [ZommiWindowsAcceptanceNative]::DragPhysicalSelection($selector,180,270,530,310)
                } else {
                    [ZommiWindowsAcceptanceNative]::DragPhysicalSelection($selector,180,200,530,240)
                    # Moving over a queued rectangle must not erase its mint outline.
                    Start-Sleep -Milliseconds 800
                    Wait-MultiOutline 530 225
                    [ZommiWindowsAcceptanceNative]::DragPhysicalSelection($selector,180,270,530,310)
                    # Duplicate region must not produce another attachment.
                    [ZommiWindowsAcceptanceNative]::DragPhysicalSelection($selector,180,270,530,310)
                }
            } finally { [ZommiMultiInput]::Control($false) }
            if ($case -eq 'rapid-release') {
                [ZommiWindowsAcceptanceNative]::SetPhysicalCursorPos(620,490) | Out-Null
                Wait-MultiOutline 528 364
                Wait-MultiOutline 552 364
                if ($process.HasExited) { throw 'A queued rectangle after Ctrl release submitted the batch.' }
            } elseif ($case -ne 'rapid') {
                [ZommiWindowsAcceptanceNative]::SetPhysicalCursorPos(620,490) | Out-Null
                Wait-MultiOutline 530 225
                Wait-MultiOutline 530 295
                Start-Sleep -Milliseconds 150
                if ($process.HasExited -or -not [ZommiWindowsAcceptanceNative]::IsOwnedWindowAtPoint($selector,220,220)) { throw 'Releasing Ctrl submitted the batch.' }
            }
            if ($case -eq 'changed') { $fixture.ChangeTitle() }
            if ($case -eq 'cancel') { [ZommiWindowsAcceptanceNative]::CancelSelection($selector) | Out-Null }
            else { [ZommiMultiInput]::Enter($selector) }
        }
        if ($case -in @('cancel','changed')) {
            if ($result.cancelled -ne $true -or $result.selections -or $result.dataUrl) { throw "$case leaked a partial batch." }
            if ($case -eq 'changed' -and $result.errorMessage -notmatch 'changed') { throw 'Source mutation was not detected.' }
        } else {
            if ($result.cancelled -or @($result.selections).Count -ne 2) { throw "$case did not return two ordered selections: $($result.errorMessage)" }
            $items = @($result.selections)
            foreach ($item in $items) {
                if ($item.dataUrl -notlike 'data:image/png;base64,*' -or $item.snapshot.source.nativeWindowId -ne $fixture.Window.ToString() -or
                    $item.alignment.mapping.screenBounds.x -ne $item.bounds.x -or $item.alignment.mapping.imageBounds.width -ne $item.bounds.width) { throw "$case lost image/source mapping." }
            }
            if ($case -in @('rapid','rapid-release')) {
                if ($items[0].bounds.x -ne 510 -or $items[1].bounds.x -ne 534 -or $items[0].bounds.width -ne 18 -or $items[1].bounds.width -ne 18) { throw 'Rapid rectangles changed order or bounds.' }
            } elseif ($items[0].bounds.y -ne 200 -or $items[1].bounds.y -ne 270 -or
                ($items[0].snapshot | ConvertTo-Json -Depth 30) -notmatch 'Selected native line' -or
                ($items[1].snapshot | ConvertTo-Json -Depth 30) -notmatch 'Parent includes this second line') { throw "$case attached incorrect regions or text." }
        }
        $results += $case
        Write-Host "multi-${case}: ok"
    } finally { $fixture.Dispose() }
}
$fixture = [ZommiContextFixture]::new()
try {
    $fixture.Raise()
    $fixture.ShowGrid()
    foreach ($row in @(0,2)) {
        $bounds = $fixture.GridCellBounds($row,0)
        $result = Invoke-CaptureRequest -Executable $CaptureHost -Method 'selectContent' -Parameters @{browserPageDetails=$false} -Interact {
            param($process)
            $selector = Wait-ForWindow -ProcessId $process.Id -Title 'Zommi content selection'
            [ZommiWindowsAcceptanceNative]::DragPhysicalSelection($selector,($bounds[0]+15),($bounds[1]+8),($bounds[0]+110),($bounds[1]+25))
            [ZommiWindowsAcceptanceNative]::ConfirmSelection($selector)
        }
        $cells = @($result.snapshot.spatialContext.cells)
        if ($result.cancelled -or $cells.Count -ne 1 -or $cells[0].dataRowNumber -ne ($row+1) -or
            $cells[0].columnHeaders -notcontains 'Database Alias' -or $result.snapshot.source.nativeWindowId -ne $fixture.Window.ToString()) {
            throw "Partial grid cell lost verified row/column context: $($result | ConvertTo-Json -Depth 12 -Compress)"
        }
        $results += "grid-row-$($row+1)"
        Write-Host "grid-row-$($row+1): ok"
    }
} finally { $fixture.Dispose() }
# A deliberately stalled UIA provider can leave process-local accessibility
# state behind. Give that fault-injection fixture its own driver process.
& (Get-Process -Id $PID).Path -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -CaptureHost $CaptureHost -IndependentWorkerOnly | ForEach-Object { Write-Host $_ }
if ($LASTEXITCODE -ne 0) { throw 'Shared-host independent-worker acceptance failed.' }
$evidence = @{captureHelper=$CaptureHost; cases=$results; independentSelector=$true}
if ($ResultPath) { $evidence | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $ResultPath -Encoding utf8 }
$evidence
