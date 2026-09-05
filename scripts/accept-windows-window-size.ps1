[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $PackageDirectory,

    [Parameter(Mandatory = $true)]
    [string] $ExpectedCommit,

    [string] $ResultPath
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'accept-windows-capture.ps1') -PackageDirectory $PackageDirectory -ResultPath $ResultPath -HelpersOnly
Add-Type -AssemblyName Accessibility
Add-Type -ReferencedAssemblies ([Accessibility.IAccessible].Assembly.Location) @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;
using Accessibility;

public static class ZommiWindowSizeAccess {
    [StructLayout(LayoutKind.Sequential)] private struct Rectangle { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] private struct Point { public int Left, Top; }
    [DllImport("user32.dll")] private static extern bool GetWindowRect(IntPtr window, out Rectangle rectangle);
    [DllImport("user32.dll")] private static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
    [DllImport("user32.dll")] private static extern bool SetPhysicalCursorPos(int left, int top);
    [DllImport("user32.dll")] private static extern bool GetPhysicalCursorPos(out Point point);
    [DllImport("user32.dll")] private static extern void mouse_event(uint flags, uint left, uint top, uint data, UIntPtr extra);
    [DllImport("user32.dll")] public static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string className, string title);
    [DllImport("oleacc.dll")] private static extern int AccessibleObjectFromWindow(IntPtr window, uint objectId, ref Guid interfaceId, [MarshalAs(UnmanagedType.Interface)] out IAccessible accessible);
    [DllImport("oleacc.dll")] private static extern int AccessibleChildren(IAccessible accessible, int start, int count, [Out, MarshalAs(UnmanagedType.LPArray, SizeParamIndex = 2)] object[] children, out int obtained);

    public sealed class Frame { public long elapsedMs; public int[] bounds; }
    public sealed class Entry { public string Name; public int[] Bounds; }

    public static Frame[] Sample(IntPtr window, int duration) {
        var previous = SetThreadDpiAwarenessContext(new IntPtr(-4));
        var frames = new List<Frame>();
        var clock = Stopwatch.StartNew();
        try {
            do {
                Rectangle rectangle;
                if (!GetWindowRect(window, out rectangle)) throw new InvalidOperationException("No window bounds");
                frames.Add(new Frame { elapsedMs = clock.ElapsedMilliseconds, bounds = new [] { rectangle.Left, rectangle.Top, rectangle.Right - rectangle.Left, rectangle.Bottom - rectangle.Top } });
                Thread.Sleep(5);
            } while (clock.ElapsedMilliseconds < duration);
            return frames.ToArray();
        } finally { SetThreadDpiAwarenessContext(previous); }
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
            mouse_event(4, 0, 0, 0, UIntPtr.Zero);
        } finally { SetThreadDpiAwarenessContext(previous); }
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
'@

$PackageDirectory = [IO.Path]::GetFullPath($PackageDirectory)
$manifest = Get-Content -Raw (Join-Path $PackageDirectory 'release-manifest.json') | ConvertFrom-Json
if ($manifest.gitCommit -ne $ExpectedCommit) { throw 'Native size probe package commit mismatch.' }
Assert-DesktopCaptureSurface
$probeRoot = Join-Path $env:TEMP ('zommi-window-size-' + [Guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $probeRoot
if (-not $ResultPath) { $ResultPath = Join-Path $probeRoot 'result.json' }
$log = Join-Path $probeRoot 'events.jsonl'
$settings = Join-Path $probeRoot 'Zommi\settings.json'
$entrypoint = Join-Path $PackageDirectory 'Zommi.exe'
$result = @{ gitCommit = $ExpectedCommit; package = $PackageDirectory; transitions = @() }

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
    param([string] $Name, [string] $Mode)
    $before = [ZommiWindowsAcceptanceNative]::PhysicalBounds($window)
    Click-SizeControl $Name
    $frames = @([ZommiWindowSizeAccess]::Sample($window, 1500))
    Wait-SizeCondition -Description "persisted $Mode" -Condition { (Test-Path $settings) -and (Get-Content -Raw $settings | ConvertFrom-Json).windowSize -eq $Mode }
    $after = [ZommiWindowsAcceptanceNative]::PhysicalBounds($window)
    $distinct = @($frames | ForEach-Object { $_.bounds -join ',' } | Select-Object -Unique)
    $result.lastMeasurement = @{ name = $Name; before = $before; after = $after; frames = $frames; distinctBounds = $distinct.Count }
    if ($distinct.Count -lt 5) { throw "No smooth native resize for $Name ($($distinct.Count) bounds)." }
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
        foreach ($axis in 0..3) {
            if ([Math]::Abs($after[$axis] - $workArea[$axis]) -gt 3) { throw 'Max escaped the monitor work area.' }
        }
    } elseif ([ZommiWindowsAcceptanceNative]::IsZoomed($window)) { throw 'Normal size retained native maximized state.' }
    $result.transitions += @{ mode = $Mode; before = $before; after = $after; distinctBounds = $distinct.Count; frames = $frames }
    Write-Host "Native $Name transition: $($distinct.Count) distinct bounds"
}

$application = $null
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
    Wait-SizeCondition -Description 'foreground' -Condition { [ZommiWindowsAcceptanceNative]::Foreground($window) }
    Click-SizeControl 'App settings'
    Measure-SizeTransition 'Wide' 'wide'
    Measure-SizeTransition 'Standard' 'standard'
    $null = Get-SizeControl 'Max'
    if (@([ZommiWindowSizeAccess]::Read($view) | Where-Object Name -eq 'Maximize').Count) { throw 'Old Maximize label remains.' }
    $normal = [ZommiWindowsAcceptanceNative]::PhysicalBounds($window)
    Measure-SizeTransition 'Max' 'maximized'
    [ZommiWindowsAcceptanceNative]::Restore($window)
    Wait-SizeCondition -Description 'native Restore retains pre-Max placement' -Condition { ([ZommiWindowsAcceptanceNative]::PhysicalBounds($window) -join ',') -eq ($normal -join ',') }
    $result.restorePlacementVerified = $true
    Measure-SizeTransition 'Wide' 'wide'
    Measure-SizeTransition 'Max' 'maximized'
    Measure-SizeTransition 'Wide' 'wide'
    Measure-SizeTransition 'Max' 'maximized'
    Measure-SizeTransition 'Standard' 'standard'
    $result.passed = $true
} catch {
    $result.passed = $false
    $result.error = $_.Exception.Message
    throw
} finally {
    try {
        $result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $ResultPath
        Write-Host "Native size evidence: $ResultPath"
    } finally {
        if ($application) {
            Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($PackageDirectory + '\', [StringComparison]::OrdinalIgnoreCase) } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        }
        Restore-SuspendedZommiApplications -ExecutablePaths $suspended
    }
}
