[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $PackageDirectory,

    [switch] $NonVisualOnly,

    [string] $ResultPath
)

$ErrorActionPreference = 'Stop'

Add-Type @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class ZommiWindowsAcceptanceNative
{
    private delegate bool EnumWindowsProc(IntPtr window, IntPtr state);

    [DllImport("user32.dll")]
    private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr state);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern int GetWindowText(IntPtr window, StringBuilder text, int maximum);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern int GetClassName(IntPtr window, StringBuilder text, int maximum);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool PostMessage(IntPtr window, uint message, IntPtr word, IntPtr data);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr SendMessage(IntPtr window, uint message, IntPtr word, IntPtr data);

    [DllImport("user32.dll")]
    private static extern uint GetDpiForWindow(IntPtr window);

    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr window);

    [DllImport("user32.dll")]
    private static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    private static extern IntPtr GetWindow(IntPtr window, uint command);

    [DllImport("user32.dll")]
    private static extern bool IsIconic(IntPtr window);

    [DllImport("user32.dll")]
    private static extern bool ShowWindow(IntPtr window, int command);

    [DllImport("user32.dll")]
    private static extern bool SetForegroundWindow(IntPtr window);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool GetWindowRect(IntPtr window, out NativeRect bounds);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern int GetWindowLong(IntPtr window, int index);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateWindowEx(
        int extendedStyle,
        string className,
        string windowName,
        uint style,
        int x,
        int y,
        int width,
        int height,
        IntPtr parent,
        IntPtr menu,
        IntPtr instance,
        IntPtr parameter);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool DestroyWindow(IntPtr window);

    [DllImport("user32.dll")]
    private static extern IntPtr WindowFromPoint(NativePoint point);

    [DllImport("user32.dll")]
    private static extern IntPtr GetAncestor(IntPtr window, uint flags);

    [DllImport("user32.dll")]
    private static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool SetWindowPos(
        IntPtr window,
        IntPtr insertAfter,
        int x,
        int y,
        int width,
        int height,
        uint flags);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SetCursorPos(int x, int y);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr GetDC(IntPtr window);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern int ReleaseDC(IntPtr window, IntPtr deviceContext);

    [DllImport("gdi32.dll", SetLastError = true)]
    private static extern IntPtr CreateCompatibleDC(IntPtr deviceContext);

    [DllImport("gdi32.dll", SetLastError = true)]
    private static extern bool DeleteDC(IntPtr deviceContext);

    [DllImport("gdi32.dll", SetLastError = true)]
    private static extern IntPtr CreateCompatibleBitmap(IntPtr deviceContext, int width, int height);

    [DllImport("gdi32.dll", SetLastError = true)]
    private static extern IntPtr SelectObject(IntPtr deviceContext, IntPtr value);

    [DllImport("gdi32.dll", SetLastError = true)]
    private static extern bool DeleteObject(IntPtr value);

    [DllImport("gdi32.dll", SetLastError = true)]
    private static extern bool BitBlt(
        IntPtr destination,
        int destinationX,
        int destinationY,
        int width,
        int height,
        IntPtr source,
        int sourceX,
        int sourceY,
        uint operation);

    [DllImport("user32.dll")]
    private static extern void keybd_event(byte virtualKey, byte scanCode, uint flags, UIntPtr extraInfo);

    [DllImport("user32.dll")]
    private static extern void mouse_event(uint flags, uint x, uint y, uint data, UIntPtr extraInfo);

    [StructLayout(LayoutKind.Sequential)]
    private struct NativeRect
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct NativePoint
    {
        public int X;
        public int Y;
    }

    public static IntPtr FindWindow(int processId, string title)
    {
        IntPtr match = IntPtr.Zero;
        EnumWindows((window, state) =>
        {
            uint owner;
            GetWindowThreadProcessId(window, out owner);
            if (owner != processId)
            {
                return true;
            }

            var text = new StringBuilder(256);
            GetWindowText(window, text, text.Capacity);
            if (text.ToString() == title)
            {
                match = window;
                return false;
            }
            return true;
        }, IntPtr.Zero);
        return match;
    }

    public static IntPtr FindVisibleWindow(int processId)
    {
        IntPtr match = IntPtr.Zero;
        EnumWindows((window, state) =>
        {
            uint owner;
            GetWindowThreadProcessId(window, out owner);
            if (owner == processId && IsWindowVisible(window))
            {
                match = window;
                return false;
            }
            return true;
        }, IntPtr.Zero);
        return match;
    }

    public static int[] Bounds(IntPtr window)
    {
        NativeRect bounds;
        if (!GetWindowRect(window, out bounds))
        {
            return new int[0];
        }
        return new[]
        {
            bounds.Left,
            bounds.Top,
            bounds.Right - bounds.Left,
            bounds.Bottom - bounds.Top,
        };
    }

    public static int[] PhysicalBounds(IntPtr window)
    {
        var previous = SetThreadDpiAwarenessContext(new IntPtr(-4));
        try
        {
            NativeRect bounds;
            if (!GetWindowRect(window, out bounds))
            {
                return new int[0];
            }
            return new[]
            {
                bounds.Left,
                bounds.Top,
                bounds.Right - bounds.Left,
                bounds.Bottom - bounds.Top,
            };
        }
        finally
        {
            if (previous != IntPtr.Zero)
            {
                SetThreadDpiAwarenessContext(previous);
            }
        }
    }

    public static bool SetPhysicalCursorPos(int x, int y)
    {
        var previous = SetThreadDpiAwarenessContext(new IntPtr(-4));
        try
        {
            return SetCursorPos(x, y);
        }
        finally
        {
            if (previous != IntPtr.Zero)
            {
                SetThreadDpiAwarenessContext(previous);
            }
        }
    }

    public static bool Visible(IntPtr window)
    {
        return IsWindowVisible(window);
    }

    public static bool TopMost(IntPtr window)
    {
        const int extendedStyle = -20;
        const int topMost = 0x00000008;
        return (GetWindowLong(window, extendedStyle) & topMost) != 0;
    }

    public static bool TaskbarEligible(IntPtr window)
    {
        const int extendedStyle = -20;
        const int toolWindow = 0x00000080;
        const int appWindow = 0x00040000;
        const uint owner = 4;
        var style = GetWindowLong(window, extendedStyle);
        return (style & toolWindow) == 0 &&
            (((style & appWindow) != 0) || GetWindow(window, owner) == IntPtr.Zero);
    }

    public static bool NativeTaskbarToggleAvailable(IntPtr window)
    {
        const int windowStyle = -16;
        const int minimizeBox = 0x00020000;
        const int systemMenu = 0x00080000;
        var style = GetWindowLong(window, windowStyle);
        return (style & minimizeBox) != 0 && (style & systemMenu) != 0;
    }

    public static bool Minimized(IntPtr window)
    {
        return IsIconic(window);
    }

    public static void Minimize(IntPtr window)
    {
        const uint systemCommand = 0x0112;
        const int minimize = 0xF020;
        SendMessage(window, systemCommand, new IntPtr(minimize), IntPtr.Zero);
    }

    public static void Restore(IntPtr window)
    {
        const uint systemCommand = 0x0112;
        const int restore = 0xF120;
        SendMessage(window, systemCommand, new IntPtr(restore), IntPtr.Zero);
        SetForegroundWindow(window);
    }

    public static bool Foreground(IntPtr window)
    {
        return GetForegroundWindow() == window;
    }

    public static IntPtr CreateCompetingTopMost(int x, int y, int width, int height)
    {
        const int topMost = 0x00000008;
        const int toolWindow = 0x00000080;
        const int noActivate = 0x08000000;
        const uint popup = 0x80000000;
        const uint visible = 0x10000000;
        const uint noActivatePosition = 0x0010;
        const uint showWindow = 0x0040;
        var window = CreateWindowEx(
            topMost | toolWindow | noActivate,
            "STATIC",
            "Zommi acceptance competing topmost",
            popup | visible,
            x,
            y,
            width,
            height,
            IntPtr.Zero,
            IntPtr.Zero,
            IntPtr.Zero,
            IntPtr.Zero);
        if (window != IntPtr.Zero)
        {
            SetWindowPos(
                window,
                new IntPtr(-1),
                x,
                y,
                width,
                height,
                noActivatePosition | showWindow);
        }
        return window;
    }

    public static bool IsWindowAtPoint(IntPtr window, int x, int y)
    {
        return WindowFromPoint(new NativePoint { X = x, Y = y }) == window;
    }

    public static bool IsOwnedWindowAtPoint(IntPtr window, int x, int y)
    {
        const uint root = 2;
        var hit = WindowFromPhysicalPoint(x, y);
        return hit != IntPtr.Zero && GetAncestor(hit, root) == window;
    }

    public static string DescribeWindowAtPoint(int x, int y)
    {
        const uint root = 2;
        const uint rootOwner = 3;
        var hit = WindowFromPhysicalPoint(x, y);
        var rootWindow = hit == IntPtr.Zero ? IntPtr.Zero : GetAncestor(hit, root);
        var ownerWindow = hit == IntPtr.Zero ? IntPtr.Zero : GetAncestor(hit, rootOwner);
        uint processId = 0;
        if (hit != IntPtr.Zero)
        {
            GetWindowThreadProcessId(hit, out processId);
        }
        var className = new StringBuilder(256);
        if (hit != IntPtr.Zero)
        {
            GetClassName(hit, className, className.Capacity);
        }
        return string.Format(
            "point={0},{1};hit={2};root={3};rootOwner={4};pid={5};class={6}",
            x,
            y,
            hit.ToInt64(),
            rootWindow.ToInt64(),
            ownerWindow.ToInt64(),
            processId,
            className.ToString());
    }

    public static bool PostMouseLeaveAtPoint(int x, int y)
    {
        const uint mouseLeave = 0x02A3;
        var hit = WindowFromPhysicalPoint(x, y);
        return hit != IntPtr.Zero &&
            PostMessage(hit, mouseLeave, IntPtr.Zero, IntPtr.Zero);
    }

    private static IntPtr WindowFromPhysicalPoint(int x, int y)
    {
        var previous = SetThreadDpiAwarenessContext(new IntPtr(-4));
        try
        {
            return WindowFromPoint(new NativePoint { X = x, Y = y });
        }
        finally
        {
            if (previous != IntPtr.Zero)
            {
                SetThreadDpiAwarenessContext(previous);
            }
        }
    }

    public static void CloseCompetingWindow(IntPtr window)
    {
        if (window != IntPtr.Zero)
        {
            DestroyWindow(window);
        }
    }

    public static void SendAltA(bool shift)
    {
        const byte alt = 0x12;
        const byte shiftKey = 0x10;
        const byte a = 0x41;
        const uint keyUp = 0x0002;
        keybd_event(alt, 0, 0, UIntPtr.Zero);
        if (shift)
        {
            keybd_event(shiftKey, 0, 0, UIntPtr.Zero);
        }
        keybd_event(a, 0, 0, UIntPtr.Zero);
        System.Threading.Thread.Sleep(40);
        keybd_event(a, 0, keyUp, UIntPtr.Zero);
        if (shift)
        {
            keybd_event(shiftKey, 0, keyUp, UIntPtr.Zero);
        }
        keybd_event(alt, 0, keyUp, UIntPtr.Zero);
    }

    public static bool DragWindowFromTitlebar(int startX, int startY, int endX, int endY)
    {
        const uint leftDown = 0x0002;
        const uint leftUp = 0x0004;
        if (!SetPhysicalCursorPos(startX, startY))
        {
            return false;
        }
        mouse_event(leftDown, 0, 0, 0, UIntPtr.Zero);
        System.Threading.Thread.Sleep(80);
        SetPhysicalCursorPos(startX + Math.Sign(endX - startX) * 10, startY);
        System.Threading.Thread.Sleep(120);
        SetPhysicalCursorPos(endX, endY);
        System.Threading.Thread.Sleep(120);
        mouse_event(leftUp, 0, 0, 0, UIntPtr.Zero);
        return true;
    }

    public static bool CancelSelection(IntPtr window)
    {
        const uint keyDown = 0x0100;
        const uint keyUp = 0x0101;
        const int escape = 0x1B;
        return PostMessage(window, keyDown, new IntPtr(escape), IntPtr.Zero) &&
            PostMessage(window, keyUp, new IntPtr(escape), IntPtr.Zero);
    }

    public static bool DragSelection(IntPtr window, int startX, int startY, int endX, int endY)
    {
        const uint leftDown = 0x0201;
        const uint mouseMove = 0x0200;
        const uint leftUp = 0x0202;
        const int leftButton = 0x0001;
        SendMessage(window, leftDown, new IntPtr(leftButton), Point(startX, startY));
        System.Threading.Thread.Sleep(100);
        SendMessage(window, mouseMove, new IntPtr(leftButton), Point(endX, endY));
        System.Threading.Thread.Sleep(100);
        SendMessage(window, leftUp, IntPtr.Zero, Point(endX, endY));
        return true;
    }

    public static uint WindowDpi(IntPtr window)
    {
        var dpi = GetDpiForWindow(window);
        return dpi == 0 ? 96 : dpi;
    }

    public static bool TryCopyDesktopPixel(out int error)
    {
        const uint sourceCopy = 0x00CC0020;
        error = 0;
        var source = GetDC(IntPtr.Zero);
        if (source == IntPtr.Zero)
        {
            error = Marshal.GetLastWin32Error();
            return false;
        }

        var target = CreateCompatibleDC(source);
        var bitmap = target == IntPtr.Zero
            ? IntPtr.Zero
            : CreateCompatibleBitmap(source, 1, 1);
        var previous = bitmap == IntPtr.Zero
            ? IntPtr.Zero
            : SelectObject(target, bitmap);
        try
        {
            if (target == IntPtr.Zero || bitmap == IntPtr.Zero || previous == IntPtr.Zero)
            {
                error = Marshal.GetLastWin32Error();
                return false;
            }
            if (!BitBlt(target, 0, 0, 1, 1, source, 0, 0, sourceCopy))
            {
                error = Marshal.GetLastWin32Error();
                return false;
            }
            return true;
        }
        finally
        {
            if (previous != IntPtr.Zero)
            {
                SelectObject(target, previous);
            }
            if (bitmap != IntPtr.Zero)
            {
                DeleteObject(bitmap);
            }
            if (target != IntPtr.Zero)
            {
                DeleteDC(target);
            }
            ReleaseDC(IntPtr.Zero, source);
        }
    }

    private static IntPtr Point(int x, int y)
    {
        return new IntPtr((y << 16) | (x & 0xffff));
    }
}
'@

function Wait-ForWindow {
    param(
        [Parameter(Mandatory = $true)]
        [int] $ProcessId,

        [Parameter(Mandatory = $true)]
        [string] $Title
    )

    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    while ([DateTime]::UtcNow -lt $deadline) {
        $window = [ZommiWindowsAcceptanceNative]::FindWindow($ProcessId, $Title)
        if ($window -ne [IntPtr]::Zero) {
            return $window
        }
        Start-Sleep -Milliseconds 50
    }
    throw "Timed out waiting for '$Title' from process $ProcessId."
}

function Wait-ForVisibleProcessWindow {
    param(
        [Parameter(Mandatory = $true)]
        [int] $ProcessId
    )

    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    while ([DateTime]::UtcNow -lt $deadline) {
        $window = [ZommiWindowsAcceptanceNative]::FindVisibleWindow($ProcessId)
        if ($window -ne [IntPtr]::Zero) {
            return $window
        }
        Start-Sleep -Milliseconds 10
    }
    throw "Timed out waiting for a visible window from process $ProcessId."
}

function Wait-ForPackagedSelector {
    param(
        [Parameter(Mandatory = $true)]
        [string] $CaptureExecutable
    )

    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    $lastWindow = [IntPtr]::Zero
    $lastTopMost = $false
    $lastForeground = $false
    while ([DateTime]::UtcNow -lt $deadline) {
        $helpers = Get-CimInstance Win32_Process | Where-Object {
            $_.ExecutablePath -eq $CaptureExecutable
        }
        foreach ($helper in $helpers) {
            $window = [ZommiWindowsAcceptanceNative]::FindWindow(
                $helper.ProcessId,
                'Zommi image selection'
            )
            if ($window -ne [IntPtr]::Zero) {
                $lastWindow = $window
                $lastTopMost = [ZommiWindowsAcceptanceNative]::TopMost($window)
                $lastForeground = [ZommiWindowsAcceptanceNative]::Foreground($window)
                if ($lastTopMost -and $lastForeground) {
                    return $window
                }
            }
        }
        Start-Sleep -Milliseconds 50
    }
    throw "Timed out waiting for the packaged application region selector to activate: window=$lastWindow topMost=$lastTopMost foreground=$lastForeground."
}

function Wait-ForAcceptanceEvent {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path,

        [Parameter(Mandatory = $true)]
        [string] $Name,

        [int] $After = 0
    )

    $deadline = [DateTime]::UtcNow.AddSeconds(20)
    while ([DateTime]::UtcNow -lt $deadline) {
        if (Test-Path -LiteralPath $Path) {
            $events = @(Get-Content -LiteralPath $Path | ForEach-Object {
                try {
                    $_ | ConvertFrom-Json
                }
                catch {
                    $null
                }
            } | Where-Object { $null -ne $_ })
            for ($index = $After; $index -lt $events.Count; $index++) {
                if ($events[$index].event -eq $Name) {
                    return [pscustomobject]@{
                        Event = $events[$index]
                        Count = $events.Count
                    }
                }
            }
        }
        Start-Sleep -Milliseconds 100
    }
    throw "Timed out waiting for acceptance event '$Name'."
}

function Invoke-CaptureRequest {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Executable,

        [Parameter(Mandatory = $true)]
        [string] $Method,

        [hashtable] $Parameters = @{},

        [scriptblock] $Interact
    )

    $start = [System.Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $Executable
    $start.Arguments = '--capture-host'
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $start
    if (-not $process.Start()) {
        throw "Could not start capture helper $Executable."
    }

    try {
        $request = @{
            id = 'acceptance'
            method = $Method
            params = $Parameters
        } | ConvertTo-Json -Compress -Depth 8
        $process.StandardInput.WriteLine($request)
        $process.StandardInput.Flush()
        if ($null -ne $Interact) {
            & $Interact $process
        }

        $read = $process.StandardOutput.ReadLineAsync()
        if (-not $read.Wait([TimeSpan]::FromSeconds(20))) {
            throw "Timed out waiting for capture response to $Method."
        }
        $response = $read.Result | ConvertFrom-Json
        if ($response.id -ne 'acceptance' -or $response.ok -ne $true) {
            throw "Capture request $Method failed: $($response.error)"
        }

        $shutdown = @{
            id = 'shutdown'
            method = 'shutdown'
            params = @{}
        } | ConvertTo-Json -Compress
        $process.StandardInput.WriteLine($shutdown)
        $process.StandardInput.Flush()
        $null = $process.StandardOutput.ReadLine()
        $process.StandardInput.Close()
        if (-not $process.WaitForExit(5000)) {
            throw 'Capture helper did not stop after shutdown.'
        }
        if ($process.ExitCode -ne 0) {
            throw "Capture helper exited $($process.ExitCode): $($process.StandardError.ReadToEnd())"
        }
        return $response.result
    }
    finally {
        if (-not $process.HasExited) {
            $process.Kill()
            $process.WaitForExit()
        }
        $process.Dispose()
    }
}

function Invoke-CaptureSelectedTextProbe {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Executable
    )

    $start = [System.Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $Executable
    $start.Arguments = '--acceptance-selected-text'
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $start
    if (-not $process.Start()) {
        throw "Could not start selected-text probe $Executable."
    }

    try {
        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        if (-not $process.WaitForExit(15000)) {
            throw 'Selected-text probe did not stop.'
        }
        if ($process.ExitCode -ne 0) {
            throw "Selected-text probe exited $($process.ExitCode): $stderr"
        }
        $result = $stdout | ConvertFrom-Json
        if ($result.marker -notin @($result.selection)) {
            throw 'Packaged selected-text probe did not preserve its exact marker.'
        }
        return $result
    }
    finally {
        if (-not $process.HasExited) {
            $process.Kill()
            $process.WaitForExit()
        }
        $process.Dispose()
    }
}

function Invoke-CaptureWindowOwnershipProbe {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Executable
    )

    $start = [System.Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $Executable
    $start.Arguments = '--acceptance-window-ownership'
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $start
    if (-not $process.Start()) {
        throw "Could not start window-ownership probe $Executable."
    }
    try {
        $output = $process.StandardOutput.ReadToEnd()
        $errorOutput = $process.StandardError.ReadToEnd()
        if (-not $process.WaitForExit(15000)) {
            throw 'Window-ownership probe did not stop.'
        }
        if ($process.ExitCode -ne 0) {
            throw "Window-ownership probe exited $($process.ExitCode): $errorOutput"
        }
        $result = $output | ConvertFrom-Json
        if ($result.ownWindowAccepted -ne $true -or
            $result.siblingWindowRejected -ne $true -or
            $result.matchingBrowserDocumentAccepted -ne $true -or
            $result.siblingBrowserDocumentRejected -ne $true) {
            throw "Window-ownership probe admitted a same-process sibling window: $output"
        }
        return $result
    }
    finally {
        if (-not $process.HasExited) {
            $process.Kill()
            $process.WaitForExit()
        }
        $process.Dispose()
    }
}

function Get-DesktopCaptureDiagnostics {
    $process = [System.Diagnostics.Process]::GetCurrentProcess()
    $sessionName = if ([string]::IsNullOrWhiteSpace($env:SESSIONNAME)) { '<unset>' } else { $env:SESSIONNAME }
    $clientName = if ([string]::IsNullOrWhiteSpace($env:CLIENTNAME)) { '<unset>' } else { $env:CLIENTNAME }
    $virtualScreen = '<unavailable>'

    try {
        Add-Type -AssemblyName System.Windows.Forms
        $bounds = [System.Windows.Forms.SystemInformation]::VirtualScreen
        $virtualScreen = "$($bounds.X),$($bounds.Y) $($bounds.Width)x$($bounds.Height)"
    }
    catch {
        $virtualScreen = "<error: $($_.Exception.GetBaseException().Message)>"
    }

    return "runnerPid=$PID; sessionId=$($process.SessionId); sessionName=$sessionName; clientName=$clientName; userInteractive=$([Environment]::UserInteractive); virtualScreen=$virtualScreen"
}

function Assert-DesktopCaptureSurface {
    $lastError = $null
    foreach ($attempt in 1..20) {
        $errorCode = 0
        if ([ZommiWindowsAcceptanceNative]::TryCopyDesktopPixel([ref] $errorCode)) {
            if ($attempt -gt 1) {
                Write-Host "desktop-surface: recovered on attempt $attempt"
            }
            return
        }
        $lastError = if ($errorCode -eq 0) {
            'unknown Win32 error'
        } else {
            $exception = [ComponentModel.Win32Exception]::new($errorCode)
            "$($exception.Message) ($errorCode)"
        }
        Start-Sleep -Milliseconds 250
    }

    $diagnostics = Get-DesktopCaptureDiagnostics
    throw "The runner process cannot access a Windows desktop capture surface after 20 attempts. This is a runner session/display attachment failure; it does not prove Windows was locked. $diagnostics; copyError=$lastError"
}

function Assert-ProbeRegionSize {
    param(
        [Parameter(Mandatory = $true)]
        [int] $Width,

        [Parameter(Mandatory = $true)]
        [int] $Height,

        [Parameter(Mandatory = $true)]
        [string] $Source
    )

    # A DPI-unaware automation process can land one physical pixel on either
    # side of the requested size when Windows virtualizes coordinates across
    # mixed-scale monitors. Keep that rounding tolerance narrow and require the
    # returned PNG to match the reported bounds exactly below.
    if ([Math]::Abs($Width - 40) -gt 1 -or [Math]::Abs($Height - 30) -gt 1) {
        throw "$Source region is outside the 40 by 30 DPI tolerance: ${Width}x${Height}."
    }
}

function Suspend-ConflictingZommiApplications {
    param(
        [Parameter(Mandatory = $true)]
        [string] $EntryPoint
    )

    $normalizedEntryPoint = [IO.Path]::GetFullPath($EntryPoint)
    $applications = @(Get-CimInstance Win32_Process | Where-Object {
        $_.Name -eq 'Zommi.exe' -and
        $_.ExecutablePath -and
        -not [string]::Equals(
            [IO.Path]::GetFullPath($_.ExecutablePath),
            $normalizedEntryPoint,
            [StringComparison]::OrdinalIgnoreCase)
    } | Sort-Object ProcessId)
    $applicationPaths = @($applications | ForEach-Object {
        [IO.Path]::GetFullPath($_.ExecutablePath)
    } | Select-Object -Unique)
    if ($applicationPaths.Count -eq 0) {
        return @()
    }

    $rootPrefixes = @($applicationPaths | ForEach-Object {
        [IO.Path]::GetDirectoryName($_).TrimEnd('\') + '\'
    } | Select-Object -Unique)
    $relatedProcesses = @(Get-CimInstance Win32_Process | Where-Object {
        if (-not $_.ExecutablePath) {
            return $false
        }
        $processPath = [IO.Path]::GetFullPath($_.ExecutablePath)
        foreach ($prefix in $rootPrefixes) {
            if ($processPath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
                return $true
            }
        }
        return $false
    })
    foreach ($process in ($relatedProcesses | Sort-Object ProcessId -Descending)) {
        Stop-Process -Id $process.ProcessId -Force -ErrorAction Stop
    }

    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    do {
        $remaining = @(Get-CimInstance Win32_Process | Where-Object {
            $_.Name -eq 'Zommi.exe' -and $_.ExecutablePath -and
            $applicationPaths -contains ([IO.Path]::GetFullPath($_.ExecutablePath))
        })
        if ($remaining.Count -eq 0) {
            break
        }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    if ($remaining.Count -ne 0) {
        throw "Could not suspend conflicting Zommi process: $($remaining.ProcessId -join ',')."
    }
    Start-Sleep -Milliseconds 300
    return $applicationPaths
}

function Restore-SuspendedZommiApplications {
    param(
        [string[]] $ExecutablePaths
    )

    if ($ExecutablePaths.Count -eq 0) {
        return
    }
    $expectedPaths = @($ExecutablePaths | Where-Object {
        Test-Path -LiteralPath $_ -PathType Leaf
    } | Select-Object -Unique)
    $runnerTrackingId = $env:RUNNER_TRACKING_ID
    try {
        Remove-Item Env:RUNNER_TRACKING_ID -ErrorAction SilentlyContinue
        foreach ($path in $expectedPaths) {
            Start-Process `
                -FilePath $path `
                -WorkingDirectory ([IO.Path]::GetDirectoryName($path)) | Out-Null
        }
    }
    finally {
        if ($null -ne $runnerTrackingId) {
            $env:RUNNER_TRACKING_ID = $runnerTrackingId
        }
    }
    if ($expectedPaths.Count -eq 0) {
        return
    }
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    do {
        $runningPaths = @(Get-CimInstance Win32_Process | Where-Object {
            $_.Name -eq 'Zommi.exe' -and $_.ExecutablePath -and
            $expectedPaths -contains ([IO.Path]::GetFullPath($_.ExecutablePath))
        } | ForEach-Object {
            [IO.Path]::GetFullPath($_.ExecutablePath)
        } | Select-Object -Unique)
        if ($runningPaths.Count -eq $expectedPaths.Count) {
            return
        }
        Start-Sleep -Milliseconds 200
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Could not restore suspended Zommi application: $($expectedPaths -join ',')."
}

function Invoke-PackagedApplicationAcceptance {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Package,

        [Parameter(Mandatory = $true)]
        [string] $CaptureExecutable
    )

    $entrypoint = Join-Path $Package 'Zommi.exe'
    $core = Join-Path $Package 'zommi-core-host.exe'
    foreach ($required in @($entrypoint, $core, $CaptureExecutable)) {
        if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
            throw "Packaged application input is missing: $required"
        }
    }
    $packageExecutables = @($entrypoint, $core, $CaptureExecutable)

    # The product deliberately owns one global mutex and two global hotkeys.
    # An already deployed Zommi would redirect this probe to itself, so an
    # explicit interactive gate temporarily suspends it and restores the exact
    # executable after the isolated package has been cleaned up.
    $suspendedApplications = @(
        Suspend-ConflictingZommiApplications -EntryPoint $entrypoint
    )

    $existing = @(Get-CimInstance Win32_Process | Where-Object {
        $_.ExecutablePath -in $packageExecutables
    })
    if ($existing.Count -ne 0) {
        Restore-SuspendedZommiApplications -ExecutablePaths $suspendedApplications
        throw "Package already has running processes: $($existing.ProcessId -join ',')."
    }

    $acceptanceLog = Join-Path $env:TEMP (
        "zommi-windows-acceptance-$([Guid]::NewGuid().ToString('N')).jsonl"
    )
    $start = [System.Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $entrypoint
    $start.WorkingDirectory = $Package
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.EnvironmentVariables['ZOMMI_ACCEPTANCE_LOG'] = $acceptanceLog
    $application = [System.Diagnostics.Process]::new()
    $application.StartInfo = $start
    try {
        if (-not $application.Start()) {
            throw "Could not start packaged Flutter application $entrypoint."
        }
    }
    catch {
        $application.Dispose()
        Restore-SuspendedZommiApplications -ExecutablePaths $suspendedApplications
        throw
    }

    try {
        $window = Wait-ForVisibleProcessWindow -ProcessId $application.Id
        $firstVisibleBounds = [ZommiWindowsAcceptanceNative]::Bounds($window)
        if ($firstVisibleBounds.Count -ne 4 -or
            $firstVisibleBounds[2] -lt 640 -or
            $firstVisibleBounds[3] -lt 500) {
            throw "Packaged application did not start as a complete taskbar chat window: $($firstVisibleBounds -join ',')."
        }

        $readyResult = Wait-ForAcceptanceEvent -Path $acceptanceLog -Name 'desktop.ready'
        $ready = $readyResult.Event
        $eventCount = $readyResult.Count
        if ($ready.contextShortcut -ne $true -or $ready.imageShortcut -ne $true) {
            throw "Packaged shortcuts were not both registered: $($ready | ConvertTo-Json -Compress)"
        }

        $taskbarBounds = [ZommiWindowsAcceptanceNative]::Bounds($window)
        if (-not [ZommiWindowsAcceptanceNative]::Visible($window) -or
            -not [ZommiWindowsAcceptanceNative]::TaskbarEligible($window)) {
            throw 'Packaged Flutter window is not visible and taskbar eligible.'
        }
        if (-not [ZommiWindowsAcceptanceNative]::NativeTaskbarToggleAvailable($window)) {
            throw 'Packaged taskbar window has no native minimize/system-menu styles.'
        }
        if ([ZommiWindowsAcceptanceNative]::TopMost($window)) {
            throw 'Packaged taskbar window unexpectedly remained always-on-top.'
        }

        $physicalBounds = [ZommiWindowsAcceptanceNative]::PhysicalBounds($window)
        if ($physicalBounds.Count -ne 4) {
            throw 'Could not read the packaged taskbar window physical bounds.'
        }
        $centerX = [int]($physicalBounds[0] + $physicalBounds[2] / 2.0)
        $centerY = [int]($physicalBounds[1] + $physicalBounds[3] / 2.0)
        if (-not [ZommiWindowsAcceptanceNative]::SetPhysicalCursorPos($centerX, $centerY)) {
            throw 'Could not hover the packaged taskbar window.'
        }
        Start-Sleep -Milliseconds 750
        $hoverBounds = [ZommiWindowsAcceptanceNative]::Bounds($window)
        if (($hoverBounds -join ',') -ne ($taskbarBounds -join ',')) {
            throw "Taskbar window resized on hover: before=$($taskbarBounds -join ',') after=$($hoverBounds -join ',')."
        }
        if (-not [ZommiWindowsAcceptanceNative]::SetPhysicalCursorPos(300, 300)) {
            throw 'Could not move the pointer away from the packaged taskbar window.'
        }
        Start-Sleep -Milliseconds 750
        $leaveBounds = [ZommiWindowsAcceptanceNative]::Bounds($window)
        if (($leaveBounds -join ',') -ne ($taskbarBounds -join ',')) {
            throw "Taskbar window resized after pointer exit: before=$($taskbarBounds -join ',') after=$($leaveBounds -join ',')."
        }

        $dragStartX = [int]($physicalBounds[0] + $physicalBounds[2] / 2.0)
        $dragStartY = [int]($physicalBounds[1] + 28)
        if (-not [ZommiWindowsAcceptanceNative]::DragWindowFromTitlebar(
            $dragStartX,
            $dragStartY,
            $dragStartX + 48,
            $dragStartY
        )) {
            throw 'Could not drag the packaged custom titlebar.'
        }
        $dragDeadline = [DateTime]::UtcNow.AddSeconds(5)
        do {
            Start-Sleep -Milliseconds 50
            $draggedBounds = [ZommiWindowsAcceptanceNative]::Bounds($window)
        } while (($draggedBounds[0] -eq $taskbarBounds[0]) -and
                 ($draggedBounds[1] -eq $taskbarBounds[1]) -and
                 [DateTime]::UtcNow -lt $dragDeadline)
        if (($draggedBounds[0] -eq $taskbarBounds[0]) -and
            ($draggedBounds[1] -eq $taskbarBounds[1])) {
            throw "Packaged custom titlebar did not move the window: before=$($taskbarBounds -join ',') after=$($draggedBounds -join ',')."
        }

        [ZommiWindowsAcceptanceNative]::Minimize($window)
        $minimizeDeadline = [DateTime]::UtcNow.AddSeconds(5)
        while (-not [ZommiWindowsAcceptanceNative]::Minimized($window) -and
               [DateTime]::UtcNow -lt $minimizeDeadline) {
            Start-Sleep -Milliseconds 50
        }
        if (-not [ZommiWindowsAcceptanceNative]::Minimized($window)) {
            throw 'Packaged taskbar window did not minimize.'
        }
        [ZommiWindowsAcceptanceNative]::Restore($window)
        $restoreDeadline = [DateTime]::UtcNow.AddSeconds(5)
        while (([ZommiWindowsAcceptanceNative]::Minimized($window) -or
                -not [ZommiWindowsAcceptanceNative]::Visible($window)) -and
               [DateTime]::UtcNow -lt $restoreDeadline) {
            Start-Sleep -Milliseconds 50
        }
        if ([ZommiWindowsAcceptanceNative]::Minimized($window) -or
            -not [ZommiWindowsAcceptanceNative]::Visible($window)) {
            throw 'Packaged taskbar window did not restore.'
        }

        if (-not [ZommiWindowsAcceptanceNative]::SetCursorPos(300, 300)) {
            throw 'Could not place the pointer for packaged context capture.'
        }
        [ZommiWindowsAcceptanceNative]::SendAltA($false)
        $contextResult = Wait-ForAcceptanceEvent `
            -Path $acceptanceLog `
            -Name 'shortcut.context' `
            -After $eventCount
        $context = $contextResult.Event
        $eventCount = $contextResult.Count
        if ($context.attached -ne $true) {
            throw "Packaged context shortcut did not attach context: $($context | ConvertTo-Json -Compress)"
        }
        $contextFocusDeadline = [DateTime]::UtcNow.AddSeconds(5)
        while (-not [ZommiWindowsAcceptanceNative]::Foreground($window) -and
               [DateTime]::UtcNow -lt $contextFocusDeadline) {
            Start-Sleep -Milliseconds 50
        }
        if (-not [ZommiWindowsAcceptanceNative]::Foreground($window)) {
            throw 'Alt+A did not restore and focus the packaged taskbar window.'
        }
        $shortcutBounds = [ZommiWindowsAcceptanceNative]::Bounds($window)
        if (($shortcutBounds[2..3] -join ',') -ne ($taskbarBounds[2..3] -join ',')) {
            throw "Context shortcut resized the taskbar chat window: before=$($taskbarBounds -join ',') after=$($shortcutBounds -join ',')."
        }

        [ZommiWindowsAcceptanceNative]::Minimize($window)
        $imageShortcutMinimizeDeadline = [DateTime]::UtcNow.AddSeconds(5)
        while (-not [ZommiWindowsAcceptanceNative]::Minimized($window) -and
               [DateTime]::UtcNow -lt $imageShortcutMinimizeDeadline) {
            Start-Sleep -Milliseconds 50
        }
        if (-not [ZommiWindowsAcceptanceNative]::Minimized($window)) {
            throw 'Could not minimize Zommi before the Alt+Shift+A restore gate.'
        }

        [ZommiWindowsAcceptanceNative]::SendAltA($true)
        $selector = Wait-ForPackagedSelector -CaptureExecutable $CaptureExecutable
        $selectorBounds = [ZommiWindowsAcceptanceNative]::Bounds($selector)
        $probeX = $selectorBounds[0] + 40
        $probeY = $selectorBounds[1] + 40
        $competitor = [ZommiWindowsAcceptanceNative]::CreateCompetingTopMost(
            $selectorBounds[0],
            $selectorBounds[1],
            160,
            160
        )
        if ($competitor -eq [IntPtr]::Zero) {
            throw 'Could not create the competing topmost acceptance window.'
        }
        try {
            Start-Sleep -Milliseconds 400
            if (-not [ZommiWindowsAcceptanceNative]::IsWindowAtPoint(
                $selector,
                $probeX,
                $probeY
            )) {
                throw 'Packaged image selector was covered by another topmost window.'
            }
        }
        finally {
            [ZommiWindowsAcceptanceNative]::CloseCompetingWindow($competitor)
        }
        if (-not [ZommiWindowsAcceptanceNative]::CancelSelection($selector)) {
            throw 'Could not cancel the packaged application region selector.'
        }
        $cancelResult = Wait-ForAcceptanceEvent `
            -Path $acceptanceLog `
            -Name 'shortcut.image.cancelled' `
            -After $eventCount
        $eventCount = $cancelResult.Count
        $cancelFocusDeadline = [DateTime]::UtcNow.AddSeconds(5)
        while (([ZommiWindowsAcceptanceNative]::Minimized($window) -or
                -not [ZommiWindowsAcceptanceNative]::Visible($window) -or
                -not [ZommiWindowsAcceptanceNative]::Foreground($window)) -and
               [DateTime]::UtcNow -lt $cancelFocusDeadline) {
            Start-Sleep -Milliseconds 50
        }
        if ([ZommiWindowsAcceptanceNative]::Minimized($window) -or
            -not [ZommiWindowsAcceptanceNative]::Visible($window) -or
            -not [ZommiWindowsAcceptanceNative]::Foreground($window)) {
            throw 'Cancelled Alt+Shift+A did not restore, show, and focus the minimized packaged taskbar window.'
        }

        [ZommiWindowsAcceptanceNative]::SendAltA($true)
        $selector = Wait-ForPackagedSelector -CaptureExecutable $CaptureExecutable
        if (-not [ZommiWindowsAcceptanceNative]::TopMost($selector) -or
            -not [ZommiWindowsAcceptanceNative]::Foreground($selector)) {
            throw 'Packaged image selector lost its topmost foreground state.'
        }
        $dpi = [double][ZommiWindowsAcceptanceNative]::WindowDpi($selector)
        $logicalWidth = [int][Math]::Max(4, [Math]::Round(40 * 96 / $dpi))
        $logicalHeight = [int][Math]::Max(4, [Math]::Round(30 * 96 / $dpi))
        if (-not [ZommiWindowsAcceptanceNative]::DragSelection(
            $selector,
            100,
            100,
            100 + $logicalWidth,
            100 + $logicalHeight
        )) {
            throw 'Could not drag the packaged application region selector.'
        }
        $imageResult = Wait-ForAcceptanceEvent `
            -Path $acceptanceLog `
            -Name 'shortcut.image' `
            -After $eventCount
        $image = $imageResult.Event
        Assert-ProbeRegionSize `
            -Width $image.width `
            -Height $image.height `
            -Source 'Packaged image shortcut'
        if ($image.attached -ne $true -or
            $image.hasImage -ne $true -or
            $image.hasPointerContext -ne $true) {
            throw "Packaged image shortcut contract failed: $($image | ConvertTo-Json -Compress)"
        }
        $imageFocusDeadline = [DateTime]::UtcNow.AddSeconds(5)
        while (-not [ZommiWindowsAcceptanceNative]::Foreground($window) -and
               [DateTime]::UtcNow -lt $imageFocusDeadline) {
            Start-Sleep -Milliseconds 50
        }
        if (-not [ZommiWindowsAcceptanceNative]::Foreground($window)) {
            throw 'Alt+Shift+A did not restore and focus the packaged taskbar window.'
        }

        Start-Sleep -Milliseconds 300
        if ($application.HasExited -or -not [ZommiWindowsAcceptanceNative]::Visible($window)) {
            throw 'Packaged Flutter application did not survive capture acceptance.'
        }
        $processes = @(Get-CimInstance Win32_Process | Where-Object {
            $_.ExecutablePath -in $packageExecutables
        })
        $coreProcesses = @($processes | Where-Object { $_.ExecutablePath -eq $core })
        $applicationCoreProcesses = @($coreProcesses | Where-Object {
            $_.ParentProcessId -eq $application.Id -and
            $_.CommandLine -notmatch '(?:^|\s)--wsl-proxy(?:\s|$)'
        })
        $proxyCoreProcesses = @($coreProcesses | Where-Object {
            $_.CommandLine -match '(?:^|\s)--wsl-proxy(?:\s|$)'
        })
        $captureProcesses = @($processes | Where-Object {
            $_.ExecutablePath -eq $CaptureExecutable
        })
        if ($applicationCoreProcesses.Count -ne 1 -or
            $proxyCoreProcesses.Count -lt 1 -or
            $captureProcesses.Count -ne 2) {
            throw "Unexpected packaged process topology: $($processes | Select-Object Name,ProcessId,ExecutablePath | ConvertTo-Json -Compress)"
        }

        return @{
            contextAttached = $true
            contextApplication = $context.application
            contextWindowTitle = $context.windowTitle
            imageCancelled = $true
            imageDimensions = @($image.width, $image.height)
            imagePointerContext = $true
            taskbarBounds = @($taskbarBounds)
            physicalBounds = @($physicalBounds)
            draggedBounds = @($draggedBounds)
            firstVisibleBounds = @($firstVisibleBounds)
            hoverBounds = @($hoverBounds)
            leaveBounds = @($leaveBounds)
            shortcutBounds = @($shortcutBounds)
            minimizedAndRestored = $true
            minimizedImageShortcutRestored = $true
            nativeTaskbarToggle = $true
            shortcutsRestoreFocus = $true
            processCount = $processes.Count
            shortcutsRegistered = $true
            taskbarEligible = $true
            topMost = $false
        }
    }
    finally {
        try {
            $processes = @(Get-CimInstance Win32_Process | Where-Object {
                $_.ExecutablePath -in $packageExecutables
            })
            foreach ($process in ($processes | Sort-Object ProcessId -Descending)) {
                Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
            }
            if (-not $application.HasExited) {
                $application.WaitForExit(3000) | Out-Null
            }
            $application.Dispose()
            if (Test-Path -LiteralPath $acceptanceLog) {
                Remove-Item -LiteralPath $acceptanceLog -Force
            }
        }
        finally {
            Restore-SuspendedZommiApplications -ExecutablePaths $suspendedApplications
        }
    }
}

function Read-PngDimension {
    param(
        [Parameter(Mandatory = $true)]
        [byte[]] $Bytes,

        [Parameter(Mandatory = $true)]
        [int] $Offset
    )

    return ([int]$Bytes[$Offset] -shl 24) -bor
        ([int]$Bytes[$Offset + 1] -shl 16) -bor
        ([int]$Bytes[$Offset + 2] -shl 8) -bor
        [int]$Bytes[$Offset + 3]
}

function Write-AcceptanceResult {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable] $Result
    )

    $json = $Result | ConvertTo-Json -Compress
    if (-not [string]::IsNullOrWhiteSpace($ResultPath)) {
        $absoluteResult = [IO.Path]::GetFullPath($ResultPath)
        $parent = Split-Path -Parent $absoluteResult
        if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
            throw "Acceptance result parent directory is missing: $parent"
        }
        $encoding = New-Object Text.UTF8Encoding($false)
        [IO.File]::WriteAllText($absoluteResult, "$json`r`n", $encoding)
    }
    Write-Output $json
}

$package = [IO.Path]::GetFullPath($PackageDirectory)
$capture = Join-Path $package 'native/Zommi.Capture.exe'
if (-not (Test-Path -LiteralPath $capture -PathType Leaf)) {
    throw "Packaged capture helper is missing: $capture"
}

$selectedText = Invoke-CaptureSelectedTextProbe -Executable $capture
Write-Host "selected-text: ok ($($selectedText.marker))"

$windowOwnership = Invoke-CaptureWindowOwnershipProbe -Executable $capture
Write-Host 'window-ownership: ok (same-process sibling rejected)'

$cancelled = Invoke-CaptureRequest -Executable $capture -Method 'selectImage' -Interact {
    param($process)
    $window = Wait-ForWindow -ProcessId $process.Id -Title 'Zommi image selection'
    if (-not [ZommiWindowsAcceptanceNative]::CancelSelection($window)) {
        throw 'Could not post Escape to the region selector.'
    }
}
if ($cancelled.cancelled -ne $true) {
    throw 'Region selector did not preserve cancellation.'
}
Write-Host 'region-cancel: ok'

if ($NonVisualOnly) {
    Write-AcceptanceResult -Result @{
        captureHelper = $capture
        selectedText = $true
        windowOwnership = $true
        cancellation = $true
        regionPixels = 'not-requested'
    }
    exit 0
}

Assert-DesktopCaptureSurface

$selected = Invoke-CaptureRequest -Executable $capture -Method 'selectImage' -Interact {
    param($process)
    $window = Wait-ForWindow -ProcessId $process.Id -Title 'Zommi image selection'
    $dpi = [double][ZommiWindowsAcceptanceNative]::WindowDpi($window)
    $logicalWidth = [int][Math]::Max(4, [Math]::Round(40 * 96 / $dpi))
    $logicalHeight = [int][Math]::Max(4, [Math]::Round(30 * 96 / $dpi))
    if (-not [ZommiWindowsAcceptanceNative]::DragSelection(
        $window,
        100,
        100,
        100 + $logicalWidth,
        100 + $logicalHeight
    )) {
        throw 'Could not post the region drag to the selector.'
    }
}
if ($selected.cancelled -eq $true) {
    throw "Region selector cancelled the scripted selection: $($selected.errorMessage)"
}
Assert-ProbeRegionSize `
    -Width $selected.bounds.width `
    -Height $selected.bounds.height `
    -Source 'Capture helper'

$prefix = 'data:image/png;base64,'
if (-not $selected.dataUrl.StartsWith($prefix, [StringComparison]::Ordinal)) {
    throw 'Region selector did not return an inline PNG.'
}
$png = [Convert]::FromBase64String($selected.dataUrl.Substring($prefix.Length))
$signature = [byte[]](137, 80, 78, 71, 13, 10, 26, 10)
if ($png.Length -lt 24) {
    throw 'Region selector returned an invalid PNG signature.'
}
for ($index = 0; $index -lt $signature.Length; $index++) {
    if ($png[$index] -ne $signature[$index]) {
        throw 'Region selector returned an invalid PNG signature.'
    }
}
$width = Read-PngDimension -Bytes $png -Offset 16
$height = Read-PngDimension -Bytes $png -Offset 20
if ($width -ne $selected.bounds.width -or $height -ne $selected.bounds.height) {
    throw "PNG dimensions ${width}x${height} do not match the reported bounds $($selected.bounds.width)x$($selected.bounds.height)."
}

$applicationResult = Invoke-PackagedApplicationAcceptance `
    -Package $package `
    -CaptureExecutable $capture

Write-AcceptanceResult -Result @{
    captureHelper = $capture
    selectedText = $true
    windowOwnership = $true
    cancellation = $true
    selectedBounds = @($selected.bounds.x, $selected.bounds.y, $selected.bounds.width, $selected.bounds.height)
    pngDimensions = @($width, $height)
    pngBytes = $png.Length
    application = $applicationResult
}
