using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Threading;

// Captures actual composed desktop pixels, including the physical cursor.
// Raw frames stay outside the repository until export and privacy review.
public sealed class DemoRecorder : IDisposable {
    public static bool DesktopUpdates() {
        var previous = SetThreadDpiAwarenessContext(new IntPtr(-4));
        try {
        using (var window = new System.Windows.Forms.Form())
        using (var sample = new Bitmap(1, 1))
        using (var graphics = Graphics.FromImage(sample)) {
            window.FormBorderStyle = System.Windows.Forms.FormBorderStyle.None;
            window.StartPosition = System.Windows.Forms.FormStartPosition.Manual;
            window.Location = new System.Drawing.Point(64, 64);
            window.Size = new Size(64, 64);
            window.ShowInTaskbar = false;
            window.TopMost = true;
            window.Show();
            var foregroundThread = GetWindowThreadProcessId(GetForegroundWindow(), out _);
            var currentThread = GetCurrentThreadId();
            var attached = foregroundThread != 0 && foregroundThread != currentThread &&
                AttachThreadInput(currentThread, foregroundThread, true);
            try {
                SetWindowPos(window.Handle, new IntPtr(-1), 0, 0, 0, 0, 0x43);
                BringWindowToTop(window.Handle);
                SetForegroundWindow(window.Handle);
            } finally {
                if (attached) AttachThreadInput(currentThread, foregroundThread, false);
            }
            foreach (var color in new[] { Color.FromArgb(37, 179, 93), Color.FromArgb(201, 41, 127) }) {
                window.BackColor = color;
                window.Refresh();
                System.Windows.Forms.Application.DoEvents();
                var point = window.PointToScreen(new System.Drawing.Point(32, 32));
                var matched = false;
                for (var attempt = 0; attempt < 10; attempt++) {
                    System.Windows.Forms.Application.DoEvents();
                    Thread.Sleep(50);
                    graphics.CopyFromScreen(point.X, point.Y, 0, 0, sample.Size);
                    if (sample.GetPixel(0, 0).ToArgb() == color.ToArgb()) { matched = true; break; }
                }
                if (!matched) {
                    if (Environment.GetEnvironmentVariable("ZOMMI_DEMO_PROBE_DIAGNOSTICS") == "1") {
                        GetWindowRect(window.Handle, out var bounds);
                        var center = new Point { X=(bounds.Left+bounds.Right)/2, Y=(bounds.Top+bounds.Bottom)/2 };
                        graphics.CopyFromScreen(center.X, center.Y, 0, 0, sample.Size);
                        Console.Error.WriteLine($"Desktop probe: expected={color.ToArgb():X8}, actualAtWindowCenter={sample.GetPixel(0,0).ToArgb():X8}, clientPoint={point}, windowBounds={bounds.Left},{bounds.Top},{bounds.Right},{bounds.Bottom}, pointOwner={WindowFromPoint(center)}, probeWindow={window.Handle}, visible={IsWindowVisible(window.Handle)}, foreground={GetForegroundWindow()}");
                    }
                    return false;
                }
            }
            return true;
        }
        } finally { SetThreadDpiAwarenessContext(previous); }
    }
    [StructLayout(LayoutKind.Sequential)] private struct Point { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)] private struct Rect { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] private static extern bool GetWindowRect(IntPtr window, out Rect bounds);
    [DllImport("user32.dll")] private static extern IntPtr WindowFromPoint(Point point);
    [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
    [DllImport("kernel32.dll")] private static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] private static extern bool AttachThreadInput(uint first, uint second, bool attach);
    [DllImport("user32.dll")] private static extern bool BringWindowToTop(IntPtr window);
    [DllImport("user32.dll")] private static extern bool SetForegroundWindow(IntPtr window);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll")] private static extern bool SetWindowPos(IntPtr window, IntPtr after, int x, int y, int width, int height, uint flags);
    [StructLayout(LayoutKind.Sequential)] private struct CursorInfo {
        public int Size, Flags; public IntPtr Cursor; public Point Position;
    }
    [DllImport("user32.dll")] private static extern bool GetCursorInfo(ref CursorInfo cursor);
    [DllImport("user32.dll")] private static extern bool DrawIconEx(IntPtr dc, int x, int y, IntPtr cursor,
        int width, int height, int step, IntPtr brush, int flags);
    [DllImport("user32.dll")] private static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
    private readonly Thread worker;
    private volatile bool stopped;
    public readonly List<double> Times = new List<double>();
    public Exception Error;
    public double Duration;
    public DemoRecorder(string directory, int left, int top, int width, int height, int maxDurationSeconds = 1200) {
        if (maxDurationSeconds < 1 || maxDurationSeconds > 3600)
            throw new ArgumentOutOfRangeException(nameof(maxDurationSeconds));
        Directory.CreateDirectory(directory);
        worker = new Thread(() => {
            var previous = SetThreadDpiAwarenessContext(new IntPtr(-4));
            var clock = Stopwatch.StartNew();
            try {
                // Keep successful frame timestamps even if the controlling
                // PowerShell process later fails before writing its manifest.
                using (var timeline = new StreamWriter(Path.Combine(directory, "frame-times.jsonl"))) {
                timeline.AutoFlush = true;
                while (!stopped && clock.Elapsed.TotalSeconds < maxDurationSeconds) {
                    using (var frame = new Bitmap(width, height, PixelFormat.Format24bppRgb))
                    using (var graphics = Graphics.FromImage(frame)) {
                        graphics.CopyFromScreen(left, top, 0, 0, frame.Size);
                        var cursor = new CursorInfo { Size = Marshal.SizeOf(typeof(CursorInfo)) };
                        if (GetCursorInfo(ref cursor) && cursor.Flags == 1) {
                            var dc = graphics.GetHdc();
                            try { DrawIconEx(dc, cursor.Position.X-left, cursor.Position.Y-top,
                                cursor.Cursor, 0, 0, 0, IntPtr.Zero, 3); }
                            finally { graphics.ReleaseHdc(dc); }
                        }
                        Times.Add(clock.Elapsed.TotalSeconds);
                        frame.Save(Path.Combine(directory, string.Format("{0:D5}.png", Times.Count-1)), ImageFormat.Png);
                        timeline.WriteLine(Times[Times.Count-1].ToString("R", CultureInfo.InvariantCulture));
                    }
                    var wait = Times.Count / 12.0 - clock.Elapsed.TotalSeconds;
                    if (wait > 0) Thread.Sleep((int)(wait * 1000));
                }
                if (!stopped) Error = new TimeoutException("The native recording reached its duration limit.");
                }
            } catch (Exception error) { Error = error; }
            finally { Duration = clock.Elapsed.TotalSeconds; SetThreadDpiAwarenessContext(previous); }
        });
        worker.IsBackground = true;
        worker.Start();
    }
    public void Dispose() { stopped = true; worker.Join(10000); if (worker.IsAlive) throw new TimeoutException("Recorder did not stop."); }
}
