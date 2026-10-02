using System.Diagnostics;
using System.Runtime.InteropServices;
using FlaUI.Core;
using FlaUI.Core.AutomationElements;
using FlaUI.Core.Definitions;
using FlaUI.UIA3;

namespace Zommi.Windows;

/// <summary>Remembers a destination before the selector takes keyboard focus.</summary>
internal sealed record CapturePasteTarget(nint Window, nint Focus, uint ProcessId, long ProcessStarted)
{
    private AutomationElement? InputElement { get; init; }
    private ITextRange? Selection { get; init; }
    public string Description => NativeCaptureWindow.Title(Window);
    public static CapturePasteTarget? Remember()
    {
        var window = GetForegroundWindow();
        var thread = GetWindowThreadProcessId(window, out var process);
        var info = new GuiThreadInfo { Size = (uint)Marshal.SizeOf<GuiThreadInfo>() };
        if (window == 0 || thread == 0 || !GetGUIThreadInfo(thread, ref info) || info.Focus == 0) return null;
        var started = ProcessStart(process);
        return started is null ? null : new(window, info.Focus, process, started.Value);
    }

    // Called on the tracker's MTA worker. Inspect identity/editability only:
    // never read input values, document text, passwords or screen pixels.
    internal static CapturePasteTarget? RememberInput(UIA3Automation automation, int excludedProcess)
    {
        var target = Remember();
        if (target is null || target.ProcessId == excludedProcess) return null;
        var element = automation.FocusedElement();
        if (element is null || element.Properties.IsPassword.ValueOrDefault ||
            !element.Properties.IsEnabled.ValueOrDefault || !element.Properties.HasKeyboardFocus.ValueOrDefault) return null;
        var type = element.Properties.ControlType.ValueOrDefault;
        var value = element.Patterns.Value.PatternOrDefault;
        if (value?.IsReadOnly.ValueOrDefault == true) return null;
        if (type != ControlType.Edit && !(value is not null && !value.IsReadOnly.ValueOrDefault)) return null;
        ITextRange? selection = null;
        try { selection = element.Patterns.Text.PatternOrDefault?.GetSelection().FirstOrDefault()?.Clone(); }
        catch (Exception error) when (error is not OutOfMemoryException) { /* Some terminal editors expose no text range. */ }
        if (!target.IsCurrent() || !element.Properties.HasKeyboardFocus.ValueOrDefault) return null;
        return target with { InputElement = element, Selection = selection };
    }

    public async Task<bool> IsInputCurrentAsync()
    {
        if (!IsCurrent()) return false;
        if (InputElement is null) return true;
        return await Task.Run(() =>
        {
            try { return InputElement.Properties.HasKeyboardFocus.ValueOrDefault && IsCurrent(); }
            catch (Exception error) when (error is not OutOfMemoryException) { return false; }
        });
    }

    public async Task<bool> RestoreInputAsync()
    {
        if (!Restore()) return false;
        if (InputElement is null) return true;
        return await Task.Run(() =>
        {
            try
            {
                InputElement.Focus();
                if (!IsCurrent() || !InputElement.Properties.HasKeyboardFocus.ValueOrDefault) return false;
                Selection?.Select();
                return IsCurrent() && InputElement.Properties.HasKeyboardFocus.ValueOrDefault;
            }
            catch (Exception error) when (error is not OutOfMemoryException) { return false; }
        });
    }

    private bool Exists() => IsWindow(Window) && IsWindow(Focus) &&
        WindowProcess(Window) == ProcessId && WindowProcess(Focus) == ProcessId &&
        ProcessStart(ProcessId) == ProcessStarted;

    public bool IsCurrent()
    {
        if (!Exists() || GetForegroundWindow() != Window) return false;
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
            SetFocus(Focus);
            return IsCurrent();
        }
        finally { if (attached) AttachThreadInput(current, thread, false); }
    }

    // Also wait for the selector's confirmation key, so holding Enter cannot
    // continue repeating into the destination after focus is restored.
    public static bool ModifiersReleased => new[] { 0x0D, 0x10, 0x11, 0x12, 0x5B, 0x5C }
        .All(key => (GetAsyncKeyState(key) & 0x8000) == 0);

    public bool Paste(uint clipboardSequence, nint clipboardOwner = 0)
    {
        if (!ModifiersReleased || !IsCurrent() || GetClipboardSequenceNumber() != clipboardSequence ||
            (clipboardOwner != 0 && GetClipboardOwner() != clipboardOwner)) return false;
        var keys = new[] { Key(0x11), Key(0x56), Key(0x56, true), Key(0x11, true) };
        var sent = SendInput((uint)keys.Length, keys, Marshal.SizeOf<Input>());
        if (sent > 0 && sent < keys.Length)
        {
            // Release only our injected keys; never retry a possibly accepted paste.
            var release = new[] { Key(0x56, true), Key(0x11, true) };
            SendInput((uint)release.Length, release, Marshal.SizeOf<Input>());
        }
        return sent == keys.Length;
    }

    private static Input Key(ushort value, bool up = false) => new()
    {
        Type = 1, Data = new InputData { Keyboard = new KeyboardInput { Key = value, Flags = up ? 2u : 0u } },
    };

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
    [StructLayout(LayoutKind.Sequential)]
    private struct Input { public uint Type; public InputData Data; }
    [StructLayout(LayoutKind.Explicit)]
    private struct InputData
    {
        [FieldOffset(0)] public KeyboardInput Keyboard;
        [FieldOffset(0)] public MouseInput Mouse;
    }
    [StructLayout(LayoutKind.Sequential)]
    private struct KeyboardInput { public ushort Key, Scan; public uint Flags, Time; public nuint Extra; }
    [StructLayout(LayoutKind.Sequential)]
    private struct MouseInput { public int X, Y; public uint Data, Flags, Time; public nuint Extra; }

    [DllImport("user32.dll")] internal static extern uint GetClipboardSequenceNumber();
    [DllImport("user32.dll")] private static extern nint GetClipboardOwner();
    [DllImport("user32.dll")] private static extern nint GetForegroundWindow();
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(nint window, out uint process);
    [DllImport("user32.dll")] private static extern bool GetGUIThreadInfo(uint thread, ref GuiThreadInfo info);
    [DllImport("user32.dll")] private static extern bool IsWindow(nint window);
    [DllImport("user32.dll")] private static extern bool IsIconic(nint window);
    [DllImport("user32.dll")] private static extern bool ShowWindow(nint window, int command);
    [DllImport("user32.dll")] private static extern bool SetForegroundWindow(nint window);
    [DllImport("user32.dll")] private static extern nint SetFocus(nint window);
    [DllImport("user32.dll")] private static extern bool AttachThreadInput(uint first, uint second, bool attach);
    [DllImport("kernel32.dll")] private static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] private static extern short GetAsyncKeyState(int key);
    [DllImport("user32.dll")] private static extern uint SendInput(uint count, Input[] inputs, int size);
}
