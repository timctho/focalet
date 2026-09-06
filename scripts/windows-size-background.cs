public sealed class ZommiSizeBackground : System.IDisposable {
    [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
    private struct Message { public System.IntPtr Window; public uint Kind; public System.UIntPtr Word; public System.IntPtr Data; public uint Time; public int Left, Top; public uint Private; }
    [System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)] private static extern System.IntPtr CreateWindowEx(uint extendedStyle, string className, string title, uint style, int left, int top, int width, int height, System.IntPtr parent, System.IntPtr menu, System.IntPtr instance, System.IntPtr parameter);
    [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern bool SetWindowPos(System.IntPtr window, System.IntPtr after, int left, int top, int width, int height, uint flags);
    [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern bool DestroyWindow(System.IntPtr window);
    [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern bool UpdateWindow(System.IntPtr window);
    [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern System.IntPtr SetThreadDpiAwarenessContext(System.IntPtr context);
    [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern int GetMessage(out Message message, System.IntPtr window, uint minimum, uint maximum);
    [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern bool TranslateMessage(ref Message message);
    [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern System.IntPtr DispatchMessage(ref Message message);
    [System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true)] private static extern bool PostThreadMessage(uint thread, uint message, System.UIntPtr word, System.IntPtr data);
    [System.Runtime.InteropServices.DllImport("kernel32.dll")] private static extern uint GetCurrentThreadId();
    private System.IntPtr window;
    private readonly System.Threading.Thread thread;
    private readonly System.Threading.ManualResetEvent ready = new System.Threading.ManualResetEvent(false);
    private uint threadId;
    private System.Exception startupFailure;

    public ZommiSizeBackground(System.IntPtr application, int[] area) {
        thread = new System.Threading.Thread(() => {
            threadId = GetCurrentThreadId();
            var previous = SetThreadDpiAwarenessContext(new System.IntPtr(-4));
            try {
                window = CreateWindowEx(0x08000080, "STATIC", "Zommi size contrast fixture", 0x80000004, area[0], area[1], area[2], area[3], System.IntPtr.Zero, System.IntPtr.Zero, System.IntPtr.Zero, System.IntPtr.Zero);
                if (window == System.IntPtr.Zero || !SetWindowPos(window, application, area[0], area[1], area[2], area[3], 0x0050) || !UpdateWindow(window)) {
                    startupFailure = new System.InvalidOperationException("Could not show the isolated resize background.");
                    return;
                }
                ready.Set();
                Message message;
                int received;
                while ((received = GetMessage(out message, System.IntPtr.Zero, 0, 0)) > 0) {
                    if (message.Kind == 0x8001) break;
                    TranslateMessage(ref message);
                    DispatchMessage(ref message);
                }
                if (received < 0) startupFailure = new System.InvalidOperationException("The resize background message loop failed.");
            } catch (System.Exception error) {
                startupFailure = error;
            } finally {
                if (window != System.IntPtr.Zero) DestroyWindow(window);
                window = System.IntPtr.Zero;
                SetThreadDpiAwarenessContext(previous);
                if (startupFailure != null) ready.Set();
            }
        });
        thread.IsBackground = true;
        thread.SetApartmentState(System.Threading.ApartmentState.STA);
        thread.Start();
        if (!ready.WaitOne(10000)) {
            Dispose();
            throw new System.TimeoutException("The resize background message loop did not start.");
        }
        if (startupFailure != null) {
            Dispose();
            throw new System.InvalidOperationException("Could not start the resize background message loop.", startupFailure);
        }
    }

    public void Dispose() {
        if (thread != null && thread.IsAlive) {
            if (!PostThreadMessage(threadId, 0x8001, System.UIntPtr.Zero, System.IntPtr.Zero) && thread.IsAlive) throw new System.ComponentModel.Win32Exception(System.Runtime.InteropServices.Marshal.GetLastWin32Error());
            if (!thread.Join(5000)) throw new System.TimeoutException("The resize background message loop did not stop.");
        }
        ready.Dispose();
    }
}
