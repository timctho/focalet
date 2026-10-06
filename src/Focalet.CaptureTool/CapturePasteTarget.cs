using System.Runtime.InteropServices;
using System.Text;
using FlaUI.Core.AutomationElements;
using FlaUI.Core.Definitions;
using FlaUI.UIA3;

using Focalet.Windows;

namespace Focalet.CaptureTool;

internal enum CaptureInputKind { Unknown, Input, Protected }
internal enum CaptureInputState { Current, Settling, Changed }
internal sealed record CaptureInputObservation(CapturePasteTarget Target, CaptureInputKind Kind);

/// <summary>Identity of the input focused when the user invokes paste.</summary>
internal sealed record CapturePasteTarget(nint Window, nint Focus, uint ProcessId, long ProcessStarted)
    : WindowFocus(Window, Focus, ProcessId, ProcessStarted)
{
    private CaptureInputIdentity? InputIdentity { get; init; }
    private UIA3Automation? InputAutomation { get; init; }
    public string Description => NativeCaptureWindow.Title(Window);
    public new static CapturePasteTarget? Remember()
        => RememberWindow() is { Focus: not 0 } target ? target : null;

    internal static CapturePasteTarget? RememberWindow()
    {
        var focus = WindowFocus.Remember();
        return focus is null ? null : new(focus.Window, focus.Focus, focus.ProcessId, focus.ProcessStarted);
    }

    // Called only on paste invocation. Inspect identity/editability only:
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
        if (!terminal && type == ControlType.Edit && readOnly == true)
            return new(target, CaptureInputKind.Protected);
        if (!target.IsCurrent() || !element.Properties.HasKeyboardFocus.ValueOrDefault) return Unknown();
        // The user already chose the caret. Keep identity for interruption checks,
        // without selecting UIA output ranges or moving focus.
        var editor = CaptureInputIdentity.Editor(automation, element);
        if (editor.Properties.IsPassword.ValueOrDefault || !editor.Properties.IsEnabled.ValueOrDefault)
            return new(target, CaptureInputKind.Protected);
        var identity = CaptureInputIdentity.Remember(automation, editor);
        return new(target with { InputIdentity = identity, InputAutomation = automation }, CaptureInputKind.Input);
    }

    internal static bool IsTerminalControl(string windowClass, string? inputClass) =>
        windowClass == "ConsoleWindowClass" || inputClass == "TermControl";

    private static string WindowClass(nint window)
    {
        var text = new StringBuilder(256);
        GetClassName(window, text, text.Capacity);
        return text.ToString();
    }

    internal bool ContainsWindow(nint window) => window == Window || GetAncestor(window, 2) == Window;

    public async Task<bool> IsInputCurrentAsync()
        => await InputStateAsync() == CaptureInputState.Current;

    internal async Task<CaptureInputState> InputStateAsync()
    {
        if (!IsCurrent()) return CaptureInputState.Changed;
        if (InputIdentity is null) return CaptureInputState.Current;
        return await Task.Run(() =>
        {
            try
            {
                var focused = InputAutomation?.FocusedElement();
                if (!IsCurrent()) return CaptureInputState.Changed;
                if (focused is null) return CaptureInputState.Settling;
                var process = focused.Properties.ProcessId.ValueOrDefault;
                if (process != ProcessId && (Focus == 0 || process != WindowProcess(Focus))) return CaptureInputState.Changed;
                var window = focused.Properties.NativeWindowHandle.ValueOrDefault;
                if (window != 0 && !ContainsWindow(window)) return CaptureInputState.Changed;
                if (!focused.Properties.HasKeyboardFocus.ValueOrDefault) return CaptureInputState.Settling;
                var editor = CaptureInputIdentity.Editor(InputAutomation!, focused);
                if (editor.Properties.IsPassword.ValueOrDefault || !editor.Properties.IsEnabled.ValueOrDefault)
                    return CaptureInputState.Changed;
                if (editor.Properties.ControlType.ValueOrDefault == ControlType.Edit &&
                    editor.Patterns.Value.PatternOrDefault?.IsReadOnly.ValueOrDefault == true)
                    return CaptureInputState.Settling;
                if (InputIdentity.Matches(InputAutomation!, editor))
                    return IsCurrent() ? CaptureInputState.Current : CaptureInputState.Changed;
                if (editor.Properties.ControlType.ValueOrDefault == ControlType.Edit ||
                    editor.Patterns.Value.PatternOrDefault?.IsReadOnly.ValueOrDefault == false)
                    return CaptureInputState.Changed;
                // Upload controls can temporarily take focus. Wait for the
                // original editor; never paste into the temporary control.
                return CaptureInputState.Settling;
            }
            // UIA providers can be temporarily unavailable while a rich editor
            // updates. An unreadable provider is not evidence of another input.
            catch (Exception error) when (error is not OutOfMemoryException) { return CaptureInputState.Settling; }
        });
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

    private static uint WindowProcess(nint window) { GetWindowThreadProcessId(window, out var process); return process; }

    private static Input Key(ushort value, bool up = false) => new()
    {
        Type = 1, Data = new InputData { Keyboard = new KeyboardInput { Key = value, Flags = up ? 2u : 0u, Extra = CapturePasteActivity.PasteTag } },
    };

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
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(nint window, out uint process);
    [DllImport("user32.dll")] private static extern nint GetAncestor(nint window, uint flags);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetClassName(nint window, StringBuilder text, int count);
    [DllImport("user32.dll")] private static extern short GetAsyncKeyState(int key);
    [DllImport("user32.dll")] private static extern uint SendInput(uint count, Input[] inputs, int size);
}
