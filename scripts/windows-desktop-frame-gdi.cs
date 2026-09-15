public sealed class ZommiDesktopFrameCapture : System.IDisposable {
    [System.Runtime.InteropServices.DllImport("user32.dll")]
    private static extern System.IntPtr SetThreadDpiAwarenessContext(System.IntPtr context);
    [System.Runtime.InteropServices.DllImport("user32.dll")]
    private static extern System.IntPtr GetDC(System.IntPtr window);
    [System.Runtime.InteropServices.DllImport("user32.dll")]
    private static extern int ReleaseDC(System.IntPtr window, System.IntPtr context);
    [System.Runtime.InteropServices.DllImport("gdi32.dll", SetLastError = true)]
    private static extern bool BitBlt(System.IntPtr target, int x, int y, int width, int height, System.IntPtr source, int sourceX, int sourceY, uint operation);
    [System.Runtime.InteropServices.DllImport("gdi32.dll", SetLastError = true)]
    private static extern bool GdiFlush();

    private readonly int[] area;
    private bool disposed;
    public long LastPresentTime { get { return 0; } }

    public sealed class DeferredFrame : System.IDisposable {
        internal System.Drawing.Bitmap Bitmap;
        public long PresentationTimestamp { get { return 0; } }

        public void Dispose() {
            if (Bitmap != null) Bitmap.Dispose();
            Bitmap = null;
        }
    }

    public ZommiDesktopFrameCapture(int[] captureArea) {
        if (captureArea == null || captureArea.Length != 4 || captureArea[2] <= 0 || captureArea[3] <= 0) throw new System.ArgumentException("A positive physical capture region is required.");
        area = (int[])captureArea.Clone();
    }

    public bool Matches(int[] captureArea) {
        if (captureArea == null || captureArea.Length != 4) return false;
        for (var index = 0; index < area.Length; index++) if (area[index] != captureArea[index]) return false;
        return true;
    }

    public DeferredFrame CaptureDeferred() {
        if (disposed) throw new System.ObjectDisposedException("ZommiDesktopFrameCapture");
        var previous = SetThreadDpiAwarenessContext(new System.IntPtr(-4));
        var frame = new DeferredFrame();
        try {
            frame.Bitmap = new System.Drawing.Bitmap(area[2], area[3], System.Drawing.Imaging.PixelFormat.Format32bppRgb);
            using (var graphics = System.Drawing.Graphics.FromImage(frame.Bitmap)) {
                var source = GetDC(System.IntPtr.Zero);
                if (source == System.IntPtr.Zero) throw new System.ComponentModel.Win32Exception();
                try {
                    var target = graphics.GetHdc();
                    try {
                        // Include layered windows and finish the copy before
                        // recording its observation timestamp.
                        const uint sourceCopyWithLayeredWindows = 0x40CC0020;
                        if (!BitBlt(target, 0, 0, area[2], area[3], source, area[0], area[1], sourceCopyWithLayeredWindows) || !GdiFlush()) throw new System.ComponentModel.Win32Exception(System.Runtime.InteropServices.Marshal.GetLastWin32Error());
                    } finally { graphics.ReleaseHdc(target); }
                } finally { ReleaseDC(System.IntPtr.Zero, source); }
            }
            return frame;
        } catch {
            frame.Dispose();
            throw;
        } finally {
            SetThreadDpiAwarenessContext(previous);
        }
    }

    public System.Drawing.Bitmap Capture() {
        using (var frame = CaptureDeferred()) return ReadFrame(frame);
    }

    public System.Drawing.Bitmap ReadFrame(DeferredFrame frame) {
        if (frame == null || frame.Bitmap == null) throw new System.ArgumentException("A retained capture is required.");
        var bitmap = frame.Bitmap;
        frame.Bitmap = null;
        return bitmap;
    }

    public void Dispose() { disposed = true; }
}
