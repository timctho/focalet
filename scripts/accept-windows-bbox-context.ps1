[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$CaptureHost, [string]$ResultPath)
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
Assert-DesktopCaptureSurface
$cases = @('drag', 'partial', 'empty', 'click-then-drag', 'thin-then-drag', 'reverse', 'busy', 'overlap-front', 'overlap-back', 'controls')
$results = @()
$timings = @{}
foreach ($case in $cases) {
    $fixture = [ZommiContextFixture]::new()
    try {
        $fixture.Raise()
        $deadline = [DateTime]::UtcNow.AddSeconds(3)
        while (-not [ZommiWindowsAcceptanceNative]::IsOwnedWindowAtPoint($fixture.Window, 220, 220) -and [DateTime]::UtcNow -lt $deadline) {
            $fixture.Raise()
            Start-Sleep -Milliseconds 50
        }
        if (-not [ZommiWindowsAcceptanceNative]::IsOwnedWindowAtPoint($fixture.Window, 220, 220)) { throw "The fixture is covered before capture: $([ZommiWindowsAcceptanceNative]::DescribeWindowAtPoint(220,220))" }
        Start-Sleep -Milliseconds 200
        if ($case -eq 'controls') { $fixture.ShowControls() }
        if ($case -eq 'overlap-back') { $fixture.BringBackToFront() }
        # Pin contrasting probe colors; responsiveness must not depend on the default theme.
        $result = Invoke-CaptureRequest -Executable $CaptureHost -Method 'selectContent' -Parameters @{browserPageDetails=$false;theme=@{accent=0xffc5ecd4L;outline=0xff8eb09dL;surface=0xff191f1eL}} -Interact {
            param($process)
            $selector = Wait-ForWindow -ProcessId $process.Id -Title 'Zommi content selection'
            $deadline = [DateTime]::UtcNow.AddSeconds(5)
            while (-not [ZommiWindowsAcceptanceNative]::NamedButtonEnabled($selector, 'Cancel') -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 25 }
            if (-not [ZommiWindowsAcceptanceNative]::NamedButtonEnabled($selector, 'Cancel')) { throw 'Rectangle selector did not become ready.' }
            if ([ZommiWindowsAcceptanceNative]::NamedButtonEnabled($selector, 'Larger') -or
                [ZommiWindowsAcceptanceNative]::NamedButtonEnabled($selector, 'Whole window')) { throw 'Element scope controls remain in the user selector.' }
            # Use the same physical-coordinate message path as the drag cases,
            # keeping press/release at one point for the zero-area selection.
            if ($case -eq 'click-then-drag') { [ZommiWindowsAcceptanceNative]::DragPhysicalSelection($selector, 220, 220, 220, 220) }
            if ($case -eq 'thin-then-drag') { [ZommiWindowsAcceptanceNative]::DragPhysicalSelection($selector, 220, 220, 300, 222) }
            if ($case -in @('click-then-drag', 'thin-then-drag')) {
                Start-Sleep -Milliseconds 100
                if (-not [ZommiWindowsAcceptanceNative]::NamedButtonEnabled($selector, 'Cancel')) { throw 'Click or thin drag selected an element.' }
            }
            if ($case -eq 'empty') { [ZommiWindowsAcceptanceNative]::DragPhysicalSelection($selector, 555, 430, 615, 470) }
            elseif ($case -eq 'controls') { [ZommiWindowsAcceptanceNative]::DragPhysicalSelection($selector, 170, 170, 520, 310) }
            elseif ($case -like 'overlap-*') { [ZommiWindowsAcceptanceNative]::DragPhysicalSelection($selector, 195, 445, 285, 470) }
            elseif ($case -eq 'busy') {
                $fixture.PauseProvider(1200)
                $latency = [ZommiWindowsAcceptanceNative]::BeginSelectionDrag($selector, 175, 195, 535, 315)
                $timings.busyProviderDragInputMilliseconds = $latency
                if ($latency -gt 200) { throw "Drag input waited ${latency}ms for UIA." }
                $deadline = [DateTime]::UtcNow.AddMilliseconds(250)
                while (-not [ZommiWindowsAcceptanceNative]::HasSelectionEdge(535, 300) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 10 }
                if (-not [ZommiWindowsAcceptanceNative]::HasSelectionEdge(535, 300)) { throw 'Busy provider blocked rectangle painting.' }
                $fixture.WaitForProvider()
                [ZommiWindowsAcceptanceNative]::EndSelectionDrag($selector, 535, 315)
            } elseif ($case -eq 'reverse') { [ZommiWindowsAcceptanceNative]::DragPhysicalSelection($selector, 535, 315, 175, 195) }
            else {
                $top = if ($case -eq 'partial') { 210 } else { 195 }
                [ZommiWindowsAcceptanceNative]::DragPhysicalSelection($selector, 175, $top, 535, 315)
            }
            [ZommiWindowsAcceptanceNative]::ConfirmSelection($selector)
        }
        if ($result.cancelled -or $result.dataUrl -notlike 'data:image/png;base64,*') { throw "$case did not attach the selected image." }
        if ($result.snapshot.source.nativeWindowId -ne $fixture.Window.ToString() -or
            $result.snapshot.source.platform -ne 'windows' -or -not $result.snapshot.source.hostName -or
            $result.alignment.mapping.imageBounds.width -ne $result.bounds.width) { throw "$case lost source identity or image mapping (expected HWND=$($fixture.Window)): $($result.snapshot | ConvertTo-Json -Depth 30 -Compress)" }
        $elements = @($result.snapshot.regionContext.elements)
        $serialized = $result.snapshot | ConvertTo-Json -Depth 30
        if ($case -eq 'empty') {
            if ($result.alignment.status -ne 'image-only' -or $result.snapshot.regionContext) { throw 'Empty crop was falsely aligned by the window title.' }
        } else {
            if ($result.alignment.status -ne 'aligned' -or $result.snapshot.regionContext.coordinateSpace -ne 'image-pixels') { throw "$case lost region context: $serialized" }
            foreach ($element in $elements) {
                if ($element.parentId -and $element.parentId -notin $elements.id) { throw 'Dangling capture-local parent reference.' }
                if ($element.visibleBounds.x -lt 0 -or $element.visibleBounds.y -lt 0 -or
                    $element.visibleBounds.x + $element.visibleBounds.width -gt $result.bounds.width -or
                    $element.visibleBounds.y + $element.visibleBounds.height -gt $result.bounds.height) { throw 'Intersection extends beyond the image.' }
            }
            if ($case -eq 'partial') {
                $line = $elements | Where-Object name -eq 'Selected native line'
                if (-not $line -or $line.relation -ne 'intersects' -or $line.bounds.y -ge 0 -or $line.visibleBounds.y -ne 0) { throw 'Partially selected text lost its full bounds or explicit intersection.' }
            } elseif ($case -like 'overlap-*') {
                $expected = if ($case -eq 'overlap-front') { 'Front overlap item' } else { 'Back overlap item' }
                $excluded = if ($case -eq 'overlap-front') { 'Back overlap item' } else { 'Front overlap item' }
                if ($serialized -notmatch $expected -or $serialized -match $excluded) { throw "$case included a covered control: $serialized" }
            } elseif ($case -eq 'controls') {
                $editor = $elements | Where-Object { $_.nativeIds.uiaAutomationId -eq 'comment-editor' }
                $button = $elements | Where-Object { $_.nativeIds.uiaAutomationId -eq 'publish-button' }
                $toggle = $elements | Where-Object { $_.nativeIds.uiaAutomationId -eq 'notify-toggle' }
                if ($editor.value -ne 'Read only draft' -or $editor.state.editable -ne $false -or
                    $button.state.enabled -ne $false -or $toggle.state.toggle -ne 'off' -or
                    $serialized -match 'DO_NOT_CAPTURE_PASSWORD') { throw "Control state, identity or password exclusion failed: $serialized" }
            } elseif ($serialized -notmatch 'Selected native line' -or $serialized -notmatch 'Parent includes this second line') { throw "$case lost text under the rectangle." }
        }
        $results += @{case=$case; bounds=$result.bounds; snapshot=$result.snapshot}
        Write-Host "bbox-${case}: ok"
    } finally { $fixture.Dispose() }
}
$implementation = Join-Path (Split-Path $CaptureHost) 'Zommi.Capture.dll'
if (-not (Test-Path -LiteralPath $implementation)) { $implementation = $CaptureHost }
$evidence = @{captureHelper=$CaptureHost; cases=$cases; timings=$timings; captures=$results
    implementationSha256=(Get-FileHash $implementation -Algorithm SHA256).Hash.ToLowerInvariant()}
if ($ResultPath) { $evidence | ConvertTo-Json -Depth 35 | Set-Content -LiteralPath $ResultPath -Encoding utf8 }
$evidence
