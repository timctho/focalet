[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $PackageDirectory,

    [Parameter(Mandatory = $true)]
    [string] $ExpectedCommit,

    [string] $ResultPath,

    [ValidateSet('DesktopDuplication', 'Gdi')]
    [string] $CaptureBackend = 'DesktopDuplication'
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'accept-windows-capture.ps1') -PackageDirectory $PackageDirectory -ResultPath $ResultPath -HelpersOnly
Add-Type -AssemblyName Accessibility
Add-Type -AssemblyName System.Drawing
$desktopCaptureSource = if ($CaptureBackend -eq 'Gdi') { 'windows-desktop-frame-gdi.cs' } else { 'windows-desktop-frame.cs' }
Add-Type -ReferencedAssemblies @([Accessibility.IAccessible].Assembly.Location, [Drawing.Bitmap].Assembly.Location) -TypeDefinition (@'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;
using Accessibility;

public static class ZommiWindowSizeAccess {
    [StructLayout(LayoutKind.Sequential)] private struct Rectangle { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] private struct Point { public int Left, Top; }
    [StructLayout(LayoutKind.Sequential)] private struct Animation { public uint Size; public int Enabled; }
    [DllImport("user32.dll", SetLastError = true)] private static extern bool SystemParametersInfo(uint action, uint parameter, ref Animation value, uint flags);
    [DllImport("user32.dll")] private static extern bool GetWindowRect(IntPtr window, out Rectangle rectangle);
    [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr window);
    [DllImport("user32.dll")] private static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
    [DllImport("user32.dll")] private static extern bool SetPhysicalCursorPos(int left, int top);
    [DllImport("user32.dll")] private static extern bool GetPhysicalCursorPos(out Point point);
    [DllImport("user32.dll")] private static extern void mouse_event(uint flags, uint left, uint top, uint data, UIntPtr extra);
    [DllImport("user32.dll", SetLastError = true)] private static extern bool PostMessage(IntPtr window, uint message, IntPtr word, IntPtr data);
    [DllImport("user32.dll")] public static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string className, string title);
    [DllImport("oleacc.dll")] private static extern int AccessibleObjectFromWindow(IntPtr window, uint objectId, ref Guid interfaceId, [MarshalAs(UnmanagedType.Interface)] out IAccessible accessible);
    [DllImport("oleacc.dll")] private static extern int AccessibleChildren(IAccessible accessible, int start, int count, [Out, MarshalAs(UnmanagedType.LPArray, SizeParamIndex = 2)] object[] children, out int obtained);

    public sealed class Frame { public long elapsedMs; public long presentedMs; public long captureStartedMs; public long captureCompletedMs; public long processedMs; public int[] bounds; public int[] marker; public int[][] markers; public int[] background; }
    public sealed class Entry { public string Name; public int[] Bounds; }
    private static Stopwatch interactionClock;
    private static long interactionStarted;
    public static long InputTimestamp { get { return interactionStarted; } }

    public static bool NativeAnimationsEnabled() {
        var animation = new Animation { Size = 8 };
        if (!SystemParametersInfo(0x48, 8, ref animation, 0)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        return animation.Enabled != 0;
    }

    public static Frame[] Sample(IntPtr window, int duration) {
        var previous = SetThreadDpiAwarenessContext(new IntPtr(-4));
        var frames = new List<Frame>();
        var pending = new List<ZommiDesktopFrameCapture.DeferredFrame>();
        var clock = duration >= 1000 && interactionClock != null ? interactionClock : Stopwatch.StartNew();
        try {
            do {
                Rectangle rectangle;
                if (!GetWindowRect(window, out rectangle)) throw new InvalidOperationException("No window bounds");
                var captureStarted = Stopwatch.GetTimestamp();
                var captured = duration >= 1000 ? ZommiRenderedSizeProbe.CaptureDeferred() : null;
                var captureCompleted = Stopwatch.GetTimestamp();
                if (captured != null) pending.Add(captured);
                frames.Add(new Frame { elapsedMs = clock.ElapsedMilliseconds, presentedMs = captured != null && captured.PresentationTimestamp > 0 ? 1000 * (captured.PresentationTimestamp - interactionStarted) / Stopwatch.Frequency : 0, captureStartedMs = 1000 * (captureStarted - interactionStarted) / Stopwatch.Frequency, captureCompletedMs = 1000 * (captureCompleted - interactionStarted) / Stopwatch.Frequency, bounds = new [] { rectangle.Left, rectangle.Top, rectangle.Right - rectangle.Left, rectangle.Bottom - rectangle.Top } });
                Thread.Sleep(15);
            } while (clock.ElapsedMilliseconds < duration);
            for (var index = 0; index < pending.Count; index++) {
                frames[index].marker = ZommiRenderedSizeProbe.AnalyzeDeferred(pending[index], frames[index].elapsedMs);
                frames[index].markers = ZommiRenderedSizeProbe.LastMarkers;
                frames[index].background = ZommiRenderedSizeProbe.LastBackground;
                frames[index].processedMs = clock.ElapsedMilliseconds;
            }
            return frames.ToArray();
        } finally { foreach (var captured in pending) captured.Dispose(); SetThreadDpiAwarenessContext(previous); if (duration >= 1000) ZommiRenderedSizeProbe.Save(); }
    }

    public static void Click(int left, int top) {
        var previous = SetThreadDpiAwarenessContext(new IntPtr(-4));
        try {
            if (!SetPhysicalCursorPos(left, top)) throw new InvalidOperationException("Pointer placement failed");
            Point actual;
            if (!GetPhysicalCursorPos(out actual) || actual.Left != left || actual.Top != top) throw new InvalidOperationException("Pointer did not reach the requested control");
            Thread.Sleep(200);
            mouse_event(2, 0, 0, 0, UIntPtr.Zero);
            Thread.Sleep(50);
            interactionStarted = Stopwatch.GetTimestamp();
            interactionClock = Stopwatch.StartNew();
            mouse_event(4, 0, 0, 0, UIntPtr.Zero);
        } finally { SetThreadDpiAwarenessContext(previous); }
    }

    public static void Restore(IntPtr window) {
        interactionStarted = Stopwatch.GetTimestamp();
        interactionClock = Stopwatch.StartNew();
        if (!PostMessage(window, 0x0112, new IntPtr(0xF120), IntPtr.Zero)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
    }

    public static Entry[] Read(IntPtr window) {
        var identity = new Guid("618736E0-3C3D-11CF-810C-00AA00389B71");
        IAccessible root;
        Marshal.ThrowExceptionForHR(AccessibleObjectFromWindow(window, unchecked((uint)-4), ref identity, out root));
        var entries = new List<Entry>();
        Visit(root, 0, entries, 0);
        return entries.ToArray();
    }

    private static void Visit(IAccessible parent, object child, List<Entry> entries, int depth) {
        if (depth > 35 || entries.Count > 1500) return;
        try {
            int left, top, width, height;
            parent.accLocation(out left, out top, out width, out height, child);
            entries.Add(new Entry { Name = parent.get_accName(child), Bounds = new [] { left, top, width, height } });
        } catch (COMException) { }
        try {
            if (!(child is int) || (int)child != 0) return;
            var count = parent.accChildCount;
            if (count == 0) return;
            var children = new object[count];
            int obtained;
            if (AccessibleChildren(parent, 0, count, children, out obtained) < 0) return;
            for (var index = 0; index < obtained; index++) {
                var accessible = children[index] as IAccessible;
                if (accessible != null) Visit(accessible, 0, entries, depth + 1);
                else if (children[index] is int) Visit(parent, children[index], entries, depth + 1);
            }
        } catch (COMException) { }
    }
}
'@ + (Get-Content -Raw (Join-Path $PSScriptRoot 'windows-size-visual-probe.cs')) + (Get-Content -Raw (Join-Path $PSScriptRoot $desktopCaptureSource)) + (Get-Content -Raw (Join-Path $PSScriptRoot 'windows-size-background.cs')))

foreach ($markerCount in 1..2) {
    $bitmap = [Drawing.Bitmap]::new(240, 100)
    try {
        $graphics = [Drawing.Graphics]::FromImage($bitmap)
        $brush = [Drawing.SolidBrush]::new([Drawing.Color]::FromArgb(95, 78, 159))
        try {
            $graphics.Clear([Drawing.Color]::White)
            foreach ($index in 0..($markerCount - 1)) { $graphics.FillEllipse($brush, (10 + 110 * $index), 10, 60, 60) }
        } finally { $brush.Dispose(); $graphics.Dispose() }
        [ZommiRenderedSizeProbe]::Area = @(0, 0, 240, 100)
        $markers = @([ZommiRenderedSizeProbe]::FindMarkers($bitmap))
        if ($markers.Count -ne $markerCount) { throw 'Rendered marker detector failed its duplicate-frame fixture.' }
    } finally { $bitmap.Dispose() }
}

$PackageDirectory = [IO.Path]::GetFullPath($PackageDirectory)
$manifest = Get-Content -Raw (Join-Path $PackageDirectory 'release-manifest.json') | ConvertFrom-Json
if ($manifest.gitCommit -ne $ExpectedCommit) { throw 'Native size probe package commit mismatch.' }
Assert-DesktopCaptureSurface
$probeRoot = Join-Path $env:TEMP ('zommi-window-size-' + [Guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $probeRoot
if (-not $ResultPath) { $ResultPath = Join-Path $probeRoot 'result.json' }
[ZommiRenderedSizeProbe]::EvidenceDirectory = Join-Path ([IO.Path]::GetDirectoryName($ResultPath)) 'rendered-size-frames'
$log = Join-Path $probeRoot 'events.jsonl'
$settings = Join-Path $probeRoot 'Zommi\settings.json'
$null = [IO.Directory]::CreateDirectory((Split-Path -Parent $settings))
# Window controls are tested after the welcome flow has completed.
[IO.File]::WriteAllText($settings, '{"runtimeSetupCompleted":true}')
$entrypoint = Join-Path $PackageDirectory 'Zommi.exe'
$result = @{ gitCommit = $ExpectedCommit; package = $PackageDirectory; captureApi = 'dxgi-desktop-duplication'; latencyClock = 'dxgi-present-qpc-from-input-release'; nativeAnimationsEnabled = [ZommiWindowSizeAccess]::NativeAnimationsEnabled(); transitions = @() }
$result.resizePolicy = 'retained-frame-without-animation'
if ($CaptureBackend -eq 'Gdi') {
    $result.captureApi = 'gdi-desktop-region'
    $result.latencyClock = 'gdi-copy-completion-qpc-from-input-release'
}

function Wait-SizeCondition {
    param([scriptblock] $Condition, [string] $Description)
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    do {
        if (& $Condition) { return }
        Start-Sleep -Milliseconds 30
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Timed out: $Description"
}

function Get-SizeControl {
    param([string] $Name)
    $script:sizeControl = $null
    Wait-SizeCondition -Description "control $Name" -Condition {
        $script:sizeControl = @([ZommiWindowSizeAccess]::Read($view) | Where-Object { $_.Name -eq $Name -and $_.Bounds[2] -gt 0 } | Select-Object -First 1)
        $script:sizeControl.Count -eq 1
    }
    return $script:sizeControl[0]
}

function Click-SizeControl {
    param([string] $Name)
    $bounds = (Get-SizeControl $Name).Bounds
    $left = [int]($bounds[0] + $bounds[2] / 2)
    $top = [int]($bounds[1] + $bounds[3] / 2)
    if (-not [ZommiWindowsAcceptanceNative]::IsOwnedWindowAtPoint($window, $left, $top)) { throw "Obscured control: $Name" }
    [ZommiWindowSizeAccess]::Click($left, $top)
}

function Measure-SizeTransition {
    param([string] $Name, [string] $Mode, [switch] $NativeRestore)
    $before = [ZommiWindowsAcceptanceNative]::PhysicalBounds($window)
    $workArea = [ZommiWindowsAcceptanceNative]::WorkArea($window)
    [ZommiRenderedSizeProbe]::Area = $workArea
    $markerBefore = [ZommiRenderedSizeProbe]::Capture(0, $false)
    $backgroundBefore = [ZommiRenderedSizeProbe]::LastBackground
    if ($null -eq $markerBefore) { throw 'Rendered send control was not visible before resize.' }
    if ($CaptureBackend -eq 'Gdi') {
        $scale = [ZommiWindowSizeAccess]::GetDpiForWindow($window) / 96.0
        $clientBefore = [ZommiWindowsAcceptanceNative]::PhysicalClientBounds($window)
        $targetWidth = if ($Mode -eq 'wide') { 1100 * $scale } else { 900 * $scale }
        $targetRight = $workArea[0] + $workArea[2] / 2 + [Math]::Min($targetWidth, $workArea[2]) / 2
        $targetBottom = $workArea[1] + $workArea[3] - 18 * $scale
        if ($Mode -eq 'maximized') { $targetRight = $workArea[0] + $workArea[2]; $targetBottom = $workArea[1] + $workArea[3] }
        $targetMarkerLeft = $targetRight - ($clientBefore[0] + $clientBefore[2] - $markerBefore[0])
        $targetMarkerTop = $targetBottom - ($clientBefore[1] + $clientBefore[3] - $markerBefore[1])
        $captureLeft = [Math]::Max($workArea[0], [Math]::Min($markerBefore[0], $targetMarkerLeft) - $markerBefore[2])
        $captureTop = [Math]::Max($workArea[1], [Math]::Min($markerBefore[1], $targetMarkerTop) - $markerBefore[3])
        $captureRight = [Math]::Min($workArea[0] + $workArea[2], [Math]::Max($markerBefore[0], $targetMarkerLeft) + 3 * $markerBefore[2])
        $captureBottom = [Math]::Min($workArea[1] + $workArea[3], [Math]::Max($markerBefore[1], $targetMarkerTop) + 2 * $markerBefore[3])
        [ZommiRenderedSizeProbe]::Area = @($captureLeft, $captureTop, ($captureRight - $captureLeft), ($captureBottom - $captureTop))
        $null = [ZommiRenderedSizeProbe]::Capture(0, $false)
    }
    if ($NativeRestore) { [ZommiWindowSizeAccess]::Restore($window) }
    else { Click-SizeControl $Name }
    $frames = @([ZommiWindowSizeAccess]::Sample($window, 3000))
    $after = [ZommiWindowsAcceptanceNative]::PhysicalBounds($window)
    $distinct = @($frames | ForEach-Object { $_.bounds -join ',' } | Select-Object -Unique)
    $result.lastMeasurement = @{ name = $Name; before = $before; after = $after; frames = $frames; captureArea = [ZommiRenderedSizeProbe]::Area; distinctBounds = $distinct.Count; inputQpc = [ZommiWindowSizeAccess]::InputTimestamp; qpcFrequency = [Diagnostics.Stopwatch]::Frequency }
    if (-not $NativeRestore) {
        Wait-SizeCondition -Description "persisted $Mode" -Condition { (Test-Path $settings) -and (Get-Content -Raw $settings | ConvertFrom-Json).windowSize -eq $Mode }
    }
    $markerAfter = [ZommiRenderedSizeProbe]::Capture(0, $false)
    if ($null -eq $markerAfter) { throw 'Rendered send control was not visible after resize.' }
    $visualDistinct = @($frames | ForEach-Object { $_.marker -join ',' } | Select-Object -Unique)
    $result.lastMeasurement.markerBefore = $markerBefore
    $result.lastMeasurement.markerAfter = $markerAfter
    $result.lastMeasurement.backgroundBefore = $backgroundBefore
    $maximumBackgroundChange = 0
    $firstMotionMs = $null
    $firstObservedMotionMs = $null
    $settledMs = $null
    foreach ($frame in $frames) {
        if ($null -eq $frame.marker -or $null -eq $frame.background) { throw "Rendered control disappeared during $Name." }
        foreach ($channel in 0..2) {
            $maximumBackgroundChange = [Math]::Max($maximumBackgroundChange, [Math]::Abs($frame.background[$channel] - $backgroundBefore[$channel]))
        }
        if ($null -eq $firstMotionMs -and ([Math]::Abs($frame.marker[0] - $markerBefore[0]) -gt 3 -or [Math]::Abs($frame.marker[1] - $markerBefore[1]) -gt 3)) {
            $firstMotionMs = $frame.presentedMs
            if ($CaptureBackend -eq 'Gdi') { $firstMotionMs = $frame.captureCompletedMs }
            $firstObservedMotionMs = $frame.elapsedMs
        }
        $atEndpoint = $true
        foreach ($axis in 0..3) {
            if ([Math]::Abs($frame.marker[$axis] - $markerAfter[$axis]) -gt 3 -or [Math]::Abs($frame.bounds[$axis] - $after[$axis]) -gt 3) { $atEndpoint = $false }
        }
        if (-not $atEndpoint) { $settledMs = $null }
        elseif ($null -eq $settledMs) { $settledMs = $frame.elapsedMs }
    }
    $result.lastMeasurement.maximumBackgroundChange = $maximumBackgroundChange
    $result.lastMeasurement.firstMotionMs = $firstMotionMs
    $result.lastMeasurement.firstObservedMotionMs = $firstObservedMotionMs
    $result.lastMeasurement.settledMs = $settledMs
    if ($maximumBackgroundChange -gt 3) { throw "Panel background flashed during $Name (RGB change $maximumBackgroundChange)." }
    if ($null -eq $firstMotionMs -or $firstMotionMs -lt 0 -or $firstMotionMs -gt 250) { throw "Resize $Name did not visibly respond within 250 ms ($firstMotionMs ms)." }
    if ($null -eq $settledMs -or $settledMs -gt 800) { throw "Resize $Name did not finish within 800 ms ($settledMs ms)." }
    $result.lastMeasurement.renderedPositions = $visualDistinct.Count
    $previousMarker = $markerBefore
    foreach ($frame in $frames) {
        if ($null -eq $frame.marker) { throw "Rendered control disappeared during $Name." }
        $visibleMarkers = @($frame.markers | Where-Object {
            $_[0] -lt [Math]::Max($markerBefore[0] + $markerBefore[2], $markerAfter[0] + $markerAfter[2]) + 3 -and
            $_[0] + $_[2] -gt [Math]::Min($markerBefore[0], $markerAfter[0]) - 3 -and
            $_[1] -lt [Math]::Max($markerBefore[1] + $markerBefore[3], $markerAfter[1] + $markerAfter[3]) + 3 -and
            $_[1] + $_[3] -gt [Math]::Min($markerBefore[1], $markerAfter[1]) - 3
        })
        if ($visibleMarkers.Count -gt 1) { throw "Rendered control duplicated during $Name." }
        $atOldFrame = $true
        $atNewFrame = $true
        foreach ($axis in 0..3) {
            if ($frame.marker[$axis] -lt [Math]::Min($markerBefore[$axis], $markerAfter[$axis]) - 3 -or $frame.marker[$axis] -gt [Math]::Max($markerBefore[$axis], $markerAfter[$axis]) + 3) { throw "Rendered control jumped outside its endpoints during $Name." }
            $direction = [Math]::Sign($markerAfter[$axis] - $markerBefore[$axis])
            if (($frame.marker[$axis] - $previousMarker[$axis]) * $direction -lt -3) { throw "Rendered control reversed direction during $Name." }
            if ([Math]::Abs($frame.marker[$axis] - $markerBefore[$axis]) -gt 3) { $atOldFrame = $false }
            if ([Math]::Abs($frame.marker[$axis] - $markerAfter[$axis]) -gt 3) { $atNewFrame = $false }
        }
        if (-not $atOldFrame -and -not $atNewFrame) { throw "Partial resized frame appeared during $Name." }
        $previousMarker = $frame.marker
    }
    foreach ($axis in 0..3) {
        if ([Math]::Abs($frames[-1].bounds[$axis] - $after[$axis]) -gt 3) { throw "Resize $Name did not settle within the sampled interval." }
    }
    $previous = $before
    foreach ($frame in $frames) {
        foreach ($axis in 0..3) {
            if ($frame.bounds[$axis] -lt [Math]::Min($before[$axis], $after[$axis]) - 3 -or $frame.bounds[$axis] -gt [Math]::Max($before[$axis], $after[$axis]) + 3) { throw "Resize $Name jumped outside its endpoints." }
            $direction = [Math]::Sign($after[$axis] - $before[$axis])
            if (($frame.bounds[$axis] - $previous[$axis]) * $direction -lt -3) { throw "Resize $Name reversed direction." }
        }
        $previous = $frame.bounds
    }
    if ($Mode -eq 'maximized') {
        if (-not [ZommiWindowsAcceptanceNative]::IsZoomed($window)) { throw 'Max did not retain native maximized state.' }
        $workArea = [ZommiWindowsAcceptanceNative]::WorkArea($window)
        $clientBounds = [ZommiWindowsAcceptanceNative]::PhysicalClientBounds($window)
        foreach ($axis in 0..3) {
            if ([Math]::Abs($clientBounds[$axis] - $workArea[$axis]) -gt 3) { throw 'Max escaped the monitor work area.' }
        }
    } elseif ([ZommiWindowsAcceptanceNative]::IsZoomed($window)) { throw 'Normal size retained native maximized state.' }
    if (-not [ZommiWindowsAcceptanceNative]::Foreground($window)) { throw "Resize $Name lost foreground ownership." }
    $result.transitions += @{ mode = $Mode; before = $before; after = $after; distinctBounds = $distinct.Count; renderedPositions = $visualDistinct.Count; markerBefore = $markerBefore; markerAfter = $markerAfter; backgroundBefore = $backgroundBefore; maximumBackgroundChange = $maximumBackgroundChange; firstMotionMs = $firstMotionMs; firstObservedMotionMs = $firstObservedMotionMs; settledMs = $settledMs; frames = $frames }
    Write-Host "Rendered $Name transition: $($visualDistinct.Count) positions, RGB change $maximumBackgroundChange, response $firstMotionMs ms, settled $settledMs ms"
}

$application = $null
$background = $null
$suspended = @(Suspend-ConflictingZommiApplications -EntryPoint (Join-Path $probeRoot 'not-running.exe'))
try {
    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = $entrypoint
    $startInfo.WorkingDirectory = $PackageDirectory
    $startInfo.UseShellExecute = $false
    $startInfo.EnvironmentVariables['APPDATA'] = $probeRoot
    $startInfo.EnvironmentVariables['ZOMMI_ACCEPTANCE_LOG'] = $log
    $application = [Diagnostics.Process]::Start($startInfo)
    $window = Wait-ForVisibleProcessWindow -ProcessId $application.Id
    $null = Wait-ForAcceptanceEvent -Path $log -Name 'desktop.ready'
    Start-Sleep -Seconds 5
    $null = [ZommiWindowSizeAccess]::Sample($window, 1)
    [ZommiWindowsAcceptanceNative]::Restore($window)
    $view = [ZommiWindowSizeAccess]::FindWindowEx($window, [IntPtr]::Zero, [NullString]::Value, [NullString]::Value)
    # Alt+A opens the content picker. Cancel it before measuring size controls,
    # leaving the composer empty and using the real return-to-chat focus path.
    [ZommiWindowsAcceptanceNative]::SendAltA($false)
    $selector = Wait-ForPackagedSelector -CaptureExecutable (Join-Path $PackageDirectory 'native/Zommi.Capture.exe')
    if (-not [ZommiWindowsAcceptanceNative]::CancelSelection($selector)) {
        throw 'Could not cancel content selection before the size-control gate.'
    }
    $selection = Wait-ForAcceptanceEvent -Path $log -Name 'selection.content'
    if ($selection.Event.count -ne 0) { throw 'Size-control setup unexpectedly attached content.' }
    Wait-SizeCondition -Description 'foreground' -Condition { [ZommiWindowsAcceptanceNative]::Foreground($window) }
    $background = [ZommiSizeBackground]::new($window, [ZommiWindowsAcceptanceNative]::WorkArea($window))
    Click-SizeControl 'App settings'
    if (@([ZommiWindowSizeAccess]::Read($view) | Where-Object Name -eq 'Window size').Count) { throw 'Window size remains in Settings.' }
    Click-SizeControl 'App settings'
    $null = Get-SizeControl 'Maximize Zommi'
    $normal = [ZommiWindowsAcceptanceNative]::PhysicalBounds($window)
    $normalMarker = [ZommiRenderedSizeProbe]::Capture(0, $false)
    Measure-SizeTransition 'Maximize Zommi' 'maximized'
    Measure-SizeTransition 'Restore' 'standard' -NativeRestore
    Wait-SizeCondition -Description 'native Restore retains pre-Max placement' -Condition { ([ZommiWindowsAcceptanceNative]::PhysicalBounds($window) -join ',') -eq ($normal -join ',') }
    Wait-SizeCondition -Description 'native Restore redraws the previous panel' -Condition {
        $marker = [ZommiRenderedSizeProbe]::Capture(0, $false)
        if ($null -eq $marker -or $null -eq $normalMarker) { return $false }
        foreach ($axis in 0..3) { if ([Math]::Abs($marker[$axis] - $normalMarker[$axis]) -gt 3) { return $false } }
        return $true
    }
    $result.restorePlacementVerified = $true
    Measure-SizeTransition 'Maximize Zommi' 'maximized'
    Measure-SizeTransition 'Restore Zommi' 'standard'
    Measure-SizeTransition 'Maximize Zommi' 'maximized'
    Measure-SizeTransition 'Restore Zommi' 'standard'
    $result.passed = $true
} catch {
    $result.passed = $false
    $result.error = $_.Exception.Message
    if ($view) {
        try { $result.surfaceStatus = @([ZommiWindowSizeAccess]::Read($view) | Where-Object { $_.Name -like 'Agent status:*' } | ForEach-Object Name) } catch { }
    }
    throw
} finally {
    try {
        $result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $ResultPath
        Write-Host "Native size evidence: $ResultPath"
    } finally {
        [ZommiRenderedSizeProbe]::Dispose()
        if ($background) { $background.Dispose() }
        if ($application) {
            Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($PackageDirectory + '\', [StringComparison]::OrdinalIgnoreCase) } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        }
        Restore-SuspendedZommiApplications -ExecutablePaths $suspended
    }
}
