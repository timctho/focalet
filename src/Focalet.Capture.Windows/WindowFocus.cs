using System.Diagnostics;
using System.Runtime.InteropServices;

namespace Focalet.Windows;

/// <summary>Window identity and focus observed at an explicit capture or paste invocation.</summary>
internal record WindowFocus(nint Window, nint Focus, uint ProcessId, long ProcessStarted)
{
    internal static WindowFocus? Remember()
    {
        var window = GetForegroundWindow();
        var thread = GetWindowThreadProcessId(window, out var process);
        var info = new GuiThreadInfo { Size = (uint)Marshal.SizeOf<GuiThreadInfo>() };
        if (window == 0 || thread == 0) return null;
        // WinUI/terminal windows can own keyboard focus without a native child
        // HWND. Their accessible input is resolved independently below.
        _ = GetGUIThreadInfo(thread, ref info);
        var started = ProcessStart(process);
        return started is null ? null : new(window, info.Focus, process, started.Value);
    }

    private bool Exists() => IsWindow(Window) && (Focus == 0 || (IsWindow(Focus) && GetAncestor(Focus, 2) == Window)) &&
        WindowProcess(Window) == ProcessId &&
        ProcessStart(ProcessId) == ProcessStarted;

    public bool IsCurrent()
    {
        if (!Exists() || GetForegroundWindow() != Window) return false;
        if (Focus == 0) return true; // UIA identity is checked separately when available.
        var info = new GuiThreadInfo { Size = (uint)Marshal.SizeOf<GuiThreadInfo>() };
        return GetGUIThreadInfo(GetWindowThreadProcessId(Window, out _), ref info) && info.Focus == Focus;
    }

    public bool Restore()
    {
        if (!Exists()) return false;
        var thread = GetWindowThreadProcessId(Window, out _);
        var current = GetCurrentThreadId();
        var attached = thread != current && AttachThreadInput(current, thread, true);
        try
        {
            if (IsIconic(Window)) ShowWindow(Window, 9);
            SetForegroundWindow(Window);
            if (GetForegroundWindow() != Window) return false;
            if (Focus != 0) SetFocus(Focus);
            return IsCurrent();
        }
        finally { if (attached) AttachThreadInput(current, thread, false); }
    }

    private static uint WindowProcess(nint window) { GetWindowThreadProcessId(window, out var process); return process; }
    private static long? ProcessStart(uint process)
    {
        try { using var value = Process.GetProcessById(checked((int)process)); return value.StartTime.ToUniversalTime().Ticks; }
        catch (Exception error) when (error is ArgumentException or InvalidOperationException or System.ComponentModel.Win32Exception or OverflowException) { return null; }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct GuiThreadInfo
    {
        public uint Size, Flags;
        public nint Active, Focus, Capture, MenuOwner, MoveSize, Caret;
        public int Left, Top, Right, Bottom;
    }
    [DllImport("user32.dll")] private static extern nint GetForegroundWindow();
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(nint window, out uint process);
    [DllImport("user32.dll")] private static extern bool GetGUIThreadInfo(uint thread, ref GuiThreadInfo info);
    [DllImport("user32.dll")] private static extern bool IsWindow(nint window);
    [DllImport("user32.dll")] private static extern nint GetAncestor(nint window, uint flags);
    [DllImport("user32.dll")] private static extern bool IsIconic(nint window);
    [DllImport("user32.dll")] private static extern bool ShowWindow(nint window, int command);
    [DllImport("user32.dll")] private static extern bool SetForegroundWindow(nint window);
    [DllImport("user32.dll")] private static extern nint SetFocus(nint window);
    [DllImport("user32.dll")] private static extern bool AttachThreadInput(uint first, uint second, bool attach);
    [DllImport("kernel32.dll")] private static extern uint GetCurrentThreadId();
}
