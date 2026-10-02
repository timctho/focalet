[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$CaptureHost, [Parameter(Mandatory=$true)][string]$OutputDirectory, [switch]$HoverOnly)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'accept-windows-capture.ps1') -PackageDirectory (Split-Path $CaptureHost) -HelpersOnly
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$references = @([System.Windows.Forms.Form].Assembly.Location, [System.Drawing.Bitmap].Assembly.Location)
if ($PSVersionTable.PSEdition -eq 'Core') { $references += Get-ChildItem (Join-Path $PSHOME 'ref') -Filter '*.dll' | ForEach-Object FullName }
Add-Type -ReferencedAssemblies $references -Path (Join-Path $PSScriptRoot 'windows-context-fixture.cs')
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class ZommiAnnotationInput {
    [DllImport("user32.dll")] private static extern void keybd_event(byte key, byte scan, uint flags, UIntPtr extra);
    [DllImport("user32.dll")] private static extern short GetAsyncKeyState(int key);
    public static void Control(bool down) {
        keybd_event(0x11, 0, down ? 0u : 2u, UIntPtr.Zero);
        var watch = System.Diagnostics.Stopwatch.StartNew();
        while (((GetAsyncKeyState(0x11) & 0x8000) != 0) != down) {
            if (watch.ElapsedMilliseconds > 2000) throw new InvalidOperationException("Synthetic Ctrl state did not settle.");
            System.Threading.Thread.Sleep(10);
        }
    }
}
'@
Assert-DesktopCaptureSurface
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
function Click-Tool([IntPtr]$Window, [string]$Name) {
    if (-not [ZommiWindowsAcceptanceNative]::ClickNamedButton($Window,$Name)) { throw "Drawing tool unavailable: $Name" }
}
function Assert-ColoredPixels($Item, [string]$Color) {
    $bytes = [Convert]::FromBase64String($Item.dataUrl.Substring($Item.dataUrl.IndexOf(',')+1))
    $stream = [IO.MemoryStream]::new($bytes)
    $image = [Drawing.Bitmap]::new($stream)
    try {
        if ($image.Width -ne $Item.bounds.width -or $image.Height -ne $Item.bounds.height) { throw 'Annotations changed image dimensions.' }
        $count = 0
        for ($y=0; $y -lt $image.Height; $y++) {
            for ($x=0; $x -lt $image.Width; $x++) {
                $pixel = $image.GetPixel($x,$y)
                if (($Color -eq 'coral' -and $pixel.R -gt 220 -and $pixel.G -lt 180 -and $pixel.B -lt 180) -or
                    ($Color -eq 'blue' -and $pixel.B -gt 220 -and $pixel.R -lt 170 -and $pixel.G -gt 140)) { $count++ }
            }
        }
        if ($count -lt 30) { throw "Exported PNG is missing $Color drawing pixels ($count)." }
        return $count
    } finally { $image.Dispose(); $stream.Dispose() }
}
$results = @()
foreach ($case in $(if ($HoverOnly) { @('hover-source') } else { @('tools','multiple-regions','hover-source','changed-source','cancel','image-selector') })) {
    $fixture = [ZommiContextFixture]::new()
    try {
        $fixture.ExpandForAnnotations()
        if ($case -eq 'hover-source') {
            $fixture.EnableHoverText()
            [ZommiWindowsAcceptanceNative]::SetPhysicalCursorPos(120,120) | Out-Null
        }
        $fixture.Raise()
        Start-Sleep -Milliseconds 200
        $readyMs = 0
        $method = if ($case -eq 'image-selector') { 'selectImage' } else { 'selectContent' }
        $result = Invoke-CaptureRequest -Executable $CaptureHost -Method $method -Parameters @{browserPageDetails=$false} -Interact {
            param($process)
            $title = if ($case -eq 'image-selector') { 'Zommi image selection' } else { 'Zommi content selection' }
            $selector = Wait-ForWindow -ProcessId $process.Id -Title $title
            # HWND/title creation precedes the borderless selector's final layout.
            # Starting then offsets the first point by the temporary caption/frame.
            $shown = [Diagnostics.Stopwatch]::StartNew()
            $stableBounds = $null
            while ($true) {
                $windowBounds = [ZommiWindowsAcceptanceNative]::PhysicalBounds($selector) -join ','
                $clientBounds = [ZommiWindowsAcceptanceNative]::PhysicalClientBounds($selector) -join ','
                $ready = [ZommiWindowsAcceptanceNative]::Visible($selector) -and
                    [ZommiWindowsAcceptanceNative]::Foreground($selector) -and
                    [ZommiWindowsAcceptanceNative]::TopMost($selector) -and
                    [ZommiWindowsAcceptanceNative]::NamedButtonEnabled($selector,'Cancel') -and
                    $windowBounds -eq $clientBounds
                if ($ready -and $stableBounds -eq $clientBounds) { break }
                if ($shown.ElapsedMilliseconds -gt 5000) { throw 'The borderless capture selector did not finish showing.' }
                $stableBounds = if ($ready) { $clientBounds } else { $null }
                Start-Sleep -Milliseconds 50
            }
            if ($case -eq 'multiple-regions') {
                [ZommiAnnotationInput]::Control($true)
                try {
                    [ZommiWindowsAcceptanceNative]::DragPhysicalSelection($selector,175,195,535,245)
                    [ZommiWindowsAcceptanceNative]::DragPhysicalSelection($selector,175,270,535,315)
                } finally { [ZommiAnnotationInput]::Control($false) }
            } else {
                [ZommiWindowsAcceptanceNative]::DragPhysicalSelection($selector,175,195,535,315)
            }
            $watch = [Diagnostics.Stopwatch]::StartNew()
            while (-not [ZommiWindowsAcceptanceNative]::NamedButtonEnabled($selector,'Attach') -and $watch.ElapsedMilliseconds -lt 1000) { Start-Sleep -Milliseconds 10 }
            $script:annotationReadyMs = $watch.ElapsedMilliseconds
            if (-not [ZommiWindowsAcceptanceNative]::NamedButtonEnabled($selector,'Attach')) { throw 'Selection did not stay open with its drawing toolbar.' }
            Click-Tool $selector 'Pen'
            Click-Tool $selector 'Coral'
            [ZommiWindowsAcceptanceNative]::DragPhysicalSelection($selector,190,210,310,234)
            $strokeReady = [Diagnostics.Stopwatch]::StartNew()
            while (-not [ZommiWindowsAcceptanceNative]::NamedButtonEnabled($selector,'Undo') -and $strokeReady.ElapsedMilliseconds -lt 1000) { Start-Sleep -Milliseconds 10 }
            if (-not [ZommiWindowsAcceptanceNative]::NamedButtonEnabled($selector,'Undo')) { throw "The first annotation stroke was not recorded: $case" }
            if ($case -eq 'tools') {
                Click-Tool $selector 'Arrow'
                [ZommiWindowsAcceptanceNative]::DragPhysicalSelection($selector,320,210,425,250)
                Click-Tool $selector 'Rectangle'
                [ZommiWindowsAcceptanceNative]::DragPhysicalSelection($selector,210,254,360,286)
                Click-Tool $selector 'Ellipse'
                [ZommiWindowsAcceptanceNative]::DragPhysicalSelection($selector,370,258,505,302)
                Click-Tool $selector 'Highlighter'
                Click-Tool $selector 'Amber'
                [ZommiWindowsAcceptanceNative]::DragPhysicalSelection($selector,190,300,460,303)
                Click-Tool $selector 'Undo'
                Click-Tool $selector 'Redo'
            }
            if ($case -eq 'multiple-regions') {
                Click-Tool $selector 'Arrow'
                Click-Tool $selector 'Blue'
                [ZommiWindowsAcceptanceNative]::DragPhysicalSelection($selector,190,280,445,302)
                Click-Tool $selector 'Undo'
                Click-Tool $selector 'Redo'
            }
            if ($case -eq 'changed-source') { $fixture.ChangeVisibleText() }
            if ($case -eq 'tools') {
                Start-Sleep -Milliseconds 150
                $bitmap = [Drawing.Bitmap]::new(900,600)
                $graphics = [Drawing.Graphics]::FromImage($bitmap)
                try {
                    $graphics.CopyFromScreen(140,140,0,0,$bitmap.Size)
                    $bitmap.Save((Join-Path $OutputDirectory 'toolbar-native.png'),[Drawing.Imaging.ImageFormat]::Png)
                } finally { $graphics.Dispose(); $bitmap.Dispose() }
            }
            if ($case -eq 'hover-source') {
                [ZommiWindowsAcceptanceNative]::SetPhysicalCursorPos(210,215) | Out-Null
                [ZommiWindowsAcceptanceNative]::ConfirmSelection($selector)
            }
            elseif ($case -eq 'cancel') { [ZommiWindowsAcceptanceNative]::CancelSelection($selector) | Out-Null }
            else { Click-Tool $selector 'Attach' }
        }
        if ($case -eq 'cancel') {
            if (-not $result.cancelled -or $result.dataUrl -or $result.selections) { throw 'Cancel leaked annotated attachments.' }
        } else {
            if ($result.cancelled) { throw "Annotation capture cancelled: $($result.errorMessage)" }
            $items = if ($case -eq 'multiple-regions') { @($result.selections) } else { @($result) }
            $expectedItems = if ($case -eq 'multiple-regions') { 2 } else { 1 }
            if ($items.Count -ne $expectedItems) { throw 'Annotation region association changed.' }
            for ($i=0; $i -lt $items.Count; $i++) {
                $item = $items[$i]
                $expected = if ($case -eq 'tools') { 5 } else { 1 }
                if ($item.snapshot.imageAnnotations.strokeCount -ne $expected -or $item.snapshot.imageAnnotations.source -ne 'user' -or -not $item.snapshot.imageAnnotations.bakedIntoImage) { throw "Missing or wrong annotation provenance: $case; expected=$expected; actual=$($item.snapshot.imageAnnotations | ConvertTo-Json -Compress)" }
                $color = if ($i -eq 0) { 'coral' } else { 'blue' }
                $pixels = Assert-ColoredPixels $item $color
                $bytes = [Convert]::FromBase64String($item.dataUrl.Substring($item.dataUrl.IndexOf(',')+1))
                [IO.File]::WriteAllBytes((Join-Path $OutputDirectory "$case-$i.png"),$bytes)
                if ($case -eq 'changed-source') {
                    if ($item.alignment.status -ne 'image-only' -or $item.snapshot.regionContext -or $item.snapshot.source) { throw 'Newer context was paired with a frozen image.' }
                } elseif ($item.snapshot.source.nativeWindowId -ne $fixture.Window.ToString() -or -not $item.snapshot.regionContext.elements) {
                    throw "Annotations lost original context: $case $($item.snapshot | ConvertTo-Json -Depth 20 -Compress)"
                }
                $results += @{case=$case;region=$i;strokes=$expected;coloredPixels=$pixels;toolbarReadyMilliseconds=$script:annotationReadyMs;alignment=$item.alignment.status}
            }
        }
        Write-Host "annotations-${case}: ok"
    } finally { $fixture.Dispose() }
}
$evidence = @{captureHelper=$CaptureHost;sha256=(Get-FileHash $CaptureHost -Algorithm SHA256).Hash.ToLowerInvariant();implementationSha256=(Get-FileHash ([IO.Path]::ChangeExtension($CaptureHost,'.dll')) -Algorithm SHA256).Hash.ToLowerInvariant();cases=$results;cancelVerified=(-not $HoverOnly)}
[IO.File]::WriteAllText((Join-Path $OutputDirectory 'result.json'),($evidence | ConvertTo-Json -Depth 12))
$evidence | ConvertTo-Json -Depth 12
