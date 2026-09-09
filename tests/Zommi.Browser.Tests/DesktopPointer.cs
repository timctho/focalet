using System.Runtime.InteropServices;

// CDP mouse events do not move the Windows desktop pointer. In a headful test,
// native hover events after resizing can otherwise replace the scripted target.
internal sealed class DesktopPointer : IDisposable
{
    [StructLayout(LayoutKind.Sequential)]
    private struct Point { public int X; public int Y; }
    [DllImport("user32.dll")] private static extern bool GetCursorPos(out Point point);
    [DllImport("user32.dll")] private static extern bool SetCursorPos(int x, int y);
    private Point previous;
    private Point parked;

    public static DesktopPointer? Park()
    {
        if (!OperatingSystem.IsWindows() || Environment.GetEnvironmentVariable("ZOMMI_BROWSER_TEST_HEADFUL") != "1") return null;
        var result = new DesktopPointer();
        // Windows clips this to the desktop's upper-left edge, outside page content.
        if (!GetCursorPos(out result.previous) || !SetCursorPos(-32768, -32768) || !GetCursorPos(out result.parked))
            throw new InvalidOperationException("Could not move the desktop pointer outside the browser test content.");
        return result;
    }

    public void Dispose()
    {
        // Do not overwrite a new position chosen by the user during the test.
        if (GetCursorPos(out var current) && current.X == parked.X && current.Y == parked.Y)
            SetCursorPos(previous.X, previous.Y);
    }

    public void Repark()
    {
        if (!SetCursorPos(-32768, -32768) || !GetCursorPos(out parked))
            throw new InvalidOperationException("Could not park the pointer after native selection.");
    }
}
