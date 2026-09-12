using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using Zommi.Capture;

internal static class NativeContentInput
{
    public static void Activate(nint window)
    {
        var current = GetCurrentThreadId();
        var foreground = GetWindowThreadProcessId(GetForegroundWindow(), out _);
        var attached = foreground != 0 && foreground != current && AttachThreadInput(current, foreground, true);
        try
        {
            // Like the native fixture, keep this disposable browser above
            // unrelated apps when the modal selector restores activation.
            SetWindowPos(window, -1, 0, 0, 0, 0, 0x43);
            BringWindowToTop(window);
            SetForegroundWindow(window);
        }
        finally { if (attached) AttachThreadInput(current, foreground, false); }
        if (GetForegroundWindow() != window) throw new InvalidOperationException("Could not bring the browser fixture to the foreground.");
    }

    public static void AssertSource(nint window, IReadOnlyList<CaptureRectangle> regions)
    {
        var previous = SetThreadDpiAwarenessContext(-4);
        try
        {
            foreach (var region in regions)
            {
                var at = GetAncestor(WindowFromPoint(new NativePoint { X = (int)(region.X + region.Width / 2), Y = (int)(region.Y + region.Height / 2) }), 2);
                if (at != window) throw new InvalidOperationException($"Browser fixture region is covered by HWND {at}; expected {window}.");
            }
            SetCursorPos((int)(regions[0].X + regions[0].Width / 2), (int)(regions[0].Y + regions[0].Height / 2));
        }
        finally { SetThreadDpiAwarenessContext(previous); }
    }

    public static async Task SelectAsync(int processId, IReadOnlyList<CaptureRectangle> regions, CancellationToken token)
    {
        nint selector = 0;
        var watch = Stopwatch.StartNew();
        while (selector == 0 && watch.Elapsed < TimeSpan.FromSeconds(4))
        {
            EnumWindows((window, _) =>
            {
                GetWindowThreadProcessId(window, out var owner);
                var title = new StringBuilder(256);
                GetWindowText(window, title, title.Capacity);
                if (owner == processId && title.ToString() == "Zommi content selection" && IsWindowVisible(window)) selector = window;
                return true;
            }, 0);
            if (selector == 0) await Task.Delay(20, token);
        }
        if (selector == 0) throw new InvalidOperationException("The shared helper did not show its selector.");
        while (GetForegroundWindow() != selector && watch.Elapsed < TimeSpan.FromSeconds(4)) await Task.Delay(20, token);
        if (GetForegroundWindow() != selector) throw new InvalidOperationException("The native selector did not receive foreground input.");
        // Visibility/foreground can precede OnShown completing its input-queue
        // attachment. Wait for the toolbar to reach the UI before
        // pressing Ctrl; AttachThreadInput resets keyboard state on detach.
        var ready = false;
        while (!ready && watch.Elapsed < TimeSpan.FromSeconds(5))
        {
            EnumChildWindows(selector, (child, _) =>
            {
                var title = new StringBuilder(128);
                GetWindowText(child, title, title.Capacity);
                if (title.ToString() == "Cancel" && IsWindowEnabled(child)) ready = true;
                return true;
            }, 0);
            if (!ready) await Task.Delay(20, token);
        }
        if (!ready) throw new InvalidOperationException("The rectangle selector did not become ready.");
        keybd_event(0x11, 0, 0, 0);
        try
        {
            await Task.Delay(60, token);
            if ((GetAsyncKeyState(0x11) & 0x8000) == 0) throw new InvalidOperationException("Ctrl input was not delivered.");
            foreach (var region in regions)
            {
                Mouse(selector, 0x201, (int)Math.Floor(region.X), (int)Math.Floor(region.Y));
                await Task.Delay(30, token);
                Mouse(selector, 0x200, (int)Math.Ceiling(region.Right), (int)Math.Ceiling(region.Bottom));
                Mouse(selector, 0x202, (int)Math.Ceiling(region.Right), (int)Math.Ceiling(region.Bottom));
                await Task.Delay(120, token);
            }
        }
        finally { keybd_event(0x11, 0, 2, 0); }
        PostMessage(selector, 0x100, 13, 0);
        PostMessage(selector, 0x101, 13, 0);
    }

    private static void Mouse(nint window, uint message, int x, int y)
    {
        if (GetForegroundWindow() != window) throw new InvalidOperationException($"The selector lost foreground input: foreground={GetForegroundWindow()}, selector={window}, visible={IsWindowVisible(window)}.");
        var previous = SetThreadDpiAwarenessContext(-4);
        try
        {
            if (!SetCursorPos(x, y)) throw new InvalidOperationException("Could not position the native pointer.");
            GetWindowRect(window, out var bounds);
            // Match the native acceptance driver's synchronous window-message
            // gestures. OS hit testing is checked separately by the desktop
            // gate; this gate verifies the shared helper and browser pipeline.
            var buttons = message == 0x202 ? 0 : 1;
            SendMessage(window, message, buttons, (nint)(((y - bounds.Top) << 16) | ((x - bounds.Left) & 0xffff)));
        }
        finally { SetThreadDpiAwarenessContext(previous); }
    }

    private delegate bool WindowCallback(nint window, nint state);
    [StructLayout(LayoutKind.Sequential)] private struct NativeRect { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] private static extern bool GetWindowRect(nint window, out NativeRect bounds);
    [DllImport("user32.dll")] private static extern nint SendMessage(nint window, uint message, nint word, nint data);
    [StructLayout(LayoutKind.Sequential)] private struct NativePoint { public int X; public int Y; }
    [DllImport("user32.dll")] private static extern nint WindowFromPoint(NativePoint point);
    [DllImport("user32.dll")] private static extern nint GetAncestor(nint window, uint flags);
    [DllImport("user32.dll")] private static extern nint SetThreadDpiAwarenessContext(nint context);
    [DllImport("kernel32.dll")] private static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] private static extern bool AttachThreadInput(uint from, uint to, bool attach);
    [DllImport("user32.dll")] private static extern bool BringWindowToTop(nint window);
    [DllImport("user32.dll")] private static extern bool SetForegroundWindow(nint window);
    [DllImport("user32.dll")] private static extern bool SetWindowPos(nint window, nint after, int x, int y, int width, int height, uint flags);
    [DllImport("user32.dll")] private static extern bool EnumWindows(WindowCallback callback, nint state);
    [DllImport("user32.dll")] private static extern bool EnumChildWindows(nint parent, WindowCallback callback, nint state);
    [DllImport("user32.dll")] private static extern bool IsWindowEnabled(nint window);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(nint window, out int process);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetWindowText(nint window, StringBuilder text, int maximum);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(nint window);
    [DllImport("user32.dll")] private static extern nint GetForegroundWindow();
    [DllImport("user32.dll")] private static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] private static extern bool PostMessage(nint window, uint message, nint word, nint data);
    [DllImport("user32.dll")] private static extern void keybd_event(byte key, byte scan, uint flags, nuint extra);
    [DllImport("user32.dll")] private static extern short GetAsyncKeyState(int key);
}
