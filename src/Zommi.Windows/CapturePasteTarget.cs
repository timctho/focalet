using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
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
    internal string? RestoreFailure { get; private set; }
    public string Description => NativeCaptureWindow.Title(Window);
    public static CapturePasteTarget? Remember()
        => RememberWindow() is { Focus: not 0 } target ? target : null;

    internal static CapturePasteTarget? RememberWindow()
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

    // Called on the tracker's MTA worker. Inspect identity/editability only:
    // never read input values, document text, passwords or screen pixels.
    internal static CaptureInputObservation ObserveInput(UIA3Automation automation, CapturePasteTarget target)
    {
        CaptureInputObservation Unknown() => new(target, CaptureInputKind.Unknown);
        if (!target.IsCurrent()) return Unknown();
        var element = automation.FocusedElement();
        if (element is null || !element.Properties.HasKeyboardFocus.ValueOrDefault) return Unknown();
        var elementProcess = element.Properties.ProcessId.ValueOrDefault;
        var elementWindow = element.Properties.NativeWindowHandle.ValueOrDefault;
        if ((elementProcess != target.ProcessId && (target.Focus == 0 || elementProcess != WindowProcess(target.Focus))) ||
            (elementWindow != 0 && !target.ContainsWindow(elementWindow))) return Unknown();
        if (element.Properties.IsPassword.ValueOrDefault || !element.Properties.IsEnabled.ValueOrDefault)
            return new(target, CaptureInputKind.Protected);
        var type = element.Properties.ControlType.ValueOrDefault;
        var terminal = IsTerminalControl(WindowClass(target.Window), element.Properties.ClassName.ValueOrDefault);
        var value = element.Patterns.Value.PatternOrDefault;
        var text = element.Patterns.Text.PatternOrDefault;
        bool? readOnly = value?.IsReadOnly.ValueOrDefault;
        if (readOnly is null && text is not null)
        {
            var attribute = text.DocumentRange.GetAttributeValue(automation.TextAttributeLibrary.IsReadOnly);
            if (attribute is bool flag) readOnly = flag;
        }
        var editable = terminal || (readOnly != true && (type == ControlType.Edit || readOnly == false));
        if (!editable)
        {
            var kind = (readOnly == true && type is ControlType.Document or ControlType.Text) || type is ControlType.Button or ControlType.Hyperlink or ControlType.List or
                ControlType.ListItem or ControlType.Menu or ControlType.MenuItem or ControlType.Tree or ControlType.TreeItem
                ? CaptureInputKind.NonInput : CaptureInputKind.Unknown;
            // A read-only editor is never an automatic destination. Ordinary
            // source documents/buttons may return to the immediately prior app.
            if (type == ControlType.Edit && readOnly == true) kind = CaptureInputKind.Protected;
            if (kind == CaptureInputKind.Unknown && HasReadOnlyDocumentParent(automation, element)) kind = CaptureInputKind.NonInput;
            return new(target, kind);
        }
        ITextRange? selection = null;
        // Terminal TextPattern selections refer to rendered output, not its
        // command-line caret; selecting one can put the console in selection mode.
        try { if (!terminal) selection = text?.GetSelection().FirstOrDefault()?.Clone(); }
        catch (Exception error) when (error is not OutOfMemoryException) { /* Some terminal editors expose no text range. */ }
        if (!target.IsCurrent() || !element.Properties.HasKeyboardFocus.ValueOrDefault) return Unknown();
        return new(target with { InputElement = element, Selection = selection }, CaptureInputKind.Input);
    }

    internal static bool IsTerminalControl(string windowClass, string? inputClass) =>
        windowClass == "ConsoleWindowClass" || inputClass == "TermControl";

    private static bool HasReadOnlyDocumentParent(UIA3Automation automation, AutomationElement element)
    {
        // Browser pages can focus an ARIA Group/container with no Value or Edit
        // pattern. Its nearest Document distinguishes a source page from an
        // opaque native input; inspect only roles and read-only state, no text.
        var walker = automation.TreeWalkerFactory.GetControlViewWalker();
        for (var depth = 0; depth < 16; depth++)
        {
            var parent = walker.GetParent(element);
            if (parent is null) return false;
            element = parent;
            if (element.Properties.ControlType.ValueOrDefault == ControlType.Document)
            {
                var value = element.Patterns.Value.PatternOrDefault;
                if (value is not null) return value.IsReadOnly.ValueOrDefault;
                return element.Patterns.Text.PatternOrDefault?.DocumentRange.GetAttributeValue(automation.TextAttributeLibrary.IsReadOnly) is true;
            }
            // ARIA dialogs can expose virtual Window nodes inside a document.
            // Only a native window ends this document search.
            if (element.Properties.ControlType.ValueOrDefault == ControlType.Window &&
                element.Properties.NativeWindowHandle.ValueOrDefault != 0) return false;
        }
        return false;
    }

    internal static bool IsShellSurface(nint window) => WindowClass(window) is
        "Shell_TrayWnd" or "Shell_SecondaryTrayWnd" or "Progman" or "WorkerW" or "MultitaskingViewFrame" or "ForegroundStaging";

    private static string WindowClass(nint window)
    {
        var text = new StringBuilder(256);
        GetClassName(window, text, text.Capacity);
        return text.ToString();
    }

    internal bool ContainsWindow(nint window) => window == Window || GetAncestor(window, 2) == Window;

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
        RestoreFailure = null;
        if (!Restore()) { RestoreFailure = "The native window/control could not be restored."; return false; }
        if (InputElement is null) return true;
        return await Task.Run(() =>
        {
            try
            {
                if (!InputElement.Properties.HasKeyboardFocus.ValueOrDefault) InputElement.Focus();
                // Chromium applies the accessibility focus action asynchronously.
                // Keep the UI pumping while waiting for the actual editor identity.
                var wait = Stopwatch.StartNew();
                while (IsCurrent() && !InputElement.Properties.HasKeyboardFocus.ValueOrDefault && wait.ElapsedMilliseconds < 1500)
                    Thread.Sleep(25);
                if (!IsCurrent() || !InputElement.Properties.HasKeyboardFocus.ValueOrDefault)
                { RestoreFailure = "The accessible editor did not acquire keyboard focus."; return false; }
                Selection?.Select();
                return IsCurrent() && InputElement.Properties.HasKeyboardFocus.ValueOrDefault;
            }
            catch (Exception error) when (error is not OutOfMemoryException)
            { RestoreFailure = error.GetType().Name + ": " + error.Message; return false; }
        });
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
    [DllImport("user32.dll")] private static extern nint GetAncestor(nint window, uint flags);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetClassName(nint window, StringBuilder text, int count);
    [DllImport("user32.dll")] private static extern bool IsIconic(nint window);
    [DllImport("user32.dll")] private static extern bool ShowWindow(nint window, int command);
    [DllImport("user32.dll")] private static extern bool SetForegroundWindow(nint window);
    [DllImport("user32.dll")] private static extern nint SetFocus(nint window);
    [DllImport("user32.dll")] private static extern bool AttachThreadInput(uint first, uint second, bool attach);
    [DllImport("kernel32.dll")] private static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] private static extern short GetAsyncKeyState(int key);
    [DllImport("user32.dll")] private static extern uint SendInput(uint count, Input[] inputs, int size);
}
