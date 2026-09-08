[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$CaptureHost, [string]$ResultPath)
$ErrorActionPreference = 'Stop'
if (-not ('ZommiWindowsAcceptanceNative' -as [type])) {
    . (Join-Path $PSScriptRoot 'accept-windows-capture.ps1') -PackageDirectory (Split-Path $CaptureHost) -HelpersOnly
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
    throw "Queued blue outline missing at ${X},${Y}."
}
Assert-DesktopCaptureSurface
$cases = @('mixed', 'rectangles', 'rapid', 'rapid-release', 'cancel', 'changed')
$results = @()
foreach ($case in $cases) {
    $fixture = [ZommiContextFixture]::new()
    try {
        [ZommiWindowsAcceptanceNative]::Restore($fixture.Window)
        Start-Sleep -Milliseconds 200
        $result = Invoke-CaptureRequest -Executable $CaptureHost -Method 'selectContent' -Parameters @{browserPageDetails=$false} -Interact {
            param($process)
            $selector = Wait-ForWindow -ProcessId $process.Id -Title 'Zommi content selection'
            [ZommiWindowsAcceptanceNative]::SetPhysicalCursorPos(220,220) | Out-Null
            $deadline = [DateTime]::UtcNow.AddSeconds(5)
            while (-not [ZommiWindowsAcceptanceNative]::NamedButtonEnabled($selector,'Larger') -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 25 }
            if (-not [ZommiWindowsAcceptanceNative]::NamedButtonEnabled($selector,'Larger')) { throw 'Initial outline unavailable.' }
            [ZommiMultiInput]::Control($true)
            try {
                if ($case -in @('rapid','rapid-release')) {
                    $fixture.PauseProvider(600)
                    # Neither click may overwrite an unresolved earlier press.
                    [ZommiWindowsAcceptanceNative]::BeginSelectionDrag($selector,519,364,519,364) | Out-Null
                    [ZommiWindowsAcceptanceNative]::EndSelectionDrag($selector,519,364)
                    if ($case -eq 'rapid-release') { [ZommiMultiInput]::Control($false) }
                    [ZommiWindowsAcceptanceNative]::BeginSelectionDrag($selector,543,364,543,364) | Out-Null
                    [ZommiWindowsAcceptanceNative]::EndSelectionDrag($selector,543,364)
                } elseif ($case -eq 'rectangles') {
                    [ZommiWindowsAcceptanceNative]::DragPhysicalSelection($selector,180,200,530,240)
                    [ZommiWindowsAcceptanceNative]::DragPhysicalSelection($selector,180,270,530,310)
                } else {
                    [ZommiWindowsAcceptanceNative]::ClickSelection($selector,220,220) | Out-Null
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
                if ($process.HasExited) { throw 'A queued click after Ctrl release submitted the batch.' }
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
                if ($items[0].bounds.x -ne 510 -or $items[1].bounds.x -ne 534 -or $items[0].bounds.width -ne 18 -or $items[1].bounds.width -ne 18) { throw 'Rapid clicks changed order or reused an outline.' }
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
    $fixture.ShowGrid()
    foreach ($row in @(0,2)) {
        $bounds = $fixture.GridCellBounds($row,0)
        $result = Invoke-CaptureRequest -Executable $CaptureHost -Method 'selectContent' -Parameters @{browserPageDetails=$false} -Interact {
            param($process)
            $selector = Wait-ForWindow -ProcessId $process.Id -Title 'Zommi content selection'
            [ZommiWindowsAcceptanceNative]::DragPhysicalSelection($selector,($bounds[0]+15),($bounds[1]+8),($bounds[0]+110),($bounds[1]+25))
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
$evidence = @{captureHelper=$CaptureHost; cases=$results}
if ($ResultPath) { $evidence | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $ResultPath -Encoding utf8 }
$evidence
