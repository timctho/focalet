using System.ComponentModel;
using System.Runtime.InteropServices;

namespace Focalet.CaptureTool;

/// <summary>Stop an active paste when the user types or navigates, even if an editor is rebuilt in place.</summary>
internal sealed class CapturePasteActivity : IDisposable
{
    internal const nuint PasteTag = 0x46434C54;
    private readonly Hook keyboardCallback;
    private readonly Hook mouseCallback;
    private nint keyboard;
    private nint mouse;
    internal bool Changed { get; private set; }

    internal CapturePasteActivity()
    {
        keyboardCallback = Keyboard;
        mouseCallback = Mouse;
        var module = GetModuleHandle(null);
        keyboard = SetWindowsHookEx(13, keyboardCallback, module, 0);
        mouse = SetWindowsHookEx(14, mouseCallback, module, 0);
        if (keyboard == 0 || mouse == 0)
        {
            var error = Marshal.GetLastWin32Error();
            Dispose();
            throw new Win32Exception(error, "Could not watch destination input changes.");
        }
    }

    private nint Keyboard(int code, nint message, nint data)
    {
        if (code >= 0 && message is 0x0100 or 0x0104)
        {
            var key = Marshal.PtrToStructure<KeyboardEvent>(data);
            // Ignore only our own injected paste, modifier holds and busy Alt+A.
            // Other typing/navigation cancels, including input from another tool.
            if (key.Extra != PasteTag && key.Key is not (0x10 or 0x11 or 0x12 or >= 0xA0 and <= 0xA5) &&
                !(key.Key == 0x41 && (GetAsyncKeyState(0x12) & 0x8000) != 0)) Changed = true;
        }
        return CallNextHookEx(0, code, message, data);
    }

    private nint Mouse(int code, nint message, nint data)
    {
        // Moving the pointer is harmless; clicks and scrolling express new intent.
        if (code >= 0 && message is 0x0201 or 0x0204 or 0x0207 or 0x020A or 0x020B or 0x020E) Changed = true;
        return CallNextHookEx(0, code, message, data);
    }

    public void Dispose()
    {
        if (keyboard != 0) { UnhookWindowsHookEx(keyboard); keyboard = 0; }
        if (mouse != 0) { UnhookWindowsHookEx(mouse); mouse = 0; }
    }

    private delegate nint Hook(int code, nint message, nint data);
    [StructLayout(LayoutKind.Sequential)] private struct KeyboardEvent { public uint Key, Scan, Flags, Time; public nuint Extra; }
    [DllImport("user32.dll", SetLastError = true)] private static extern nint SetWindowsHookEx(int kind, Hook callback, nint module, uint thread);
    [DllImport("user32.dll")] private static extern bool UnhookWindowsHookEx(nint hook);
    [DllImport("user32.dll")] private static extern nint CallNextHookEx(nint hook, int code, nint message, nint data);
    [DllImport("user32.dll")] private static extern short GetAsyncKeyState(int key);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] private static extern nint GetModuleHandle(string? name);
}
