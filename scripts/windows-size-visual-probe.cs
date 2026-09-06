public static class ZommiRenderedSizeProbe {
    public static int[] Area;
    public static string EvidenceDirectory;
    public static int[] LastBackground;
    public static long LastPresentationTimestamp;
    private static int sequence;
    private static ZommiDesktopFrameCapture desktop;
    private static readonly System.Collections.Generic.List<System.Drawing.Bitmap> images = new System.Collections.Generic.List<System.Drawing.Bitmap>();
    private static readonly System.Collections.Generic.List<long> timestamps = new System.Collections.Generic.List<long>();

    private static void EnsureCapture() {
        if (desktop == null || !desktop.Matches(Area)) {
            if (desktop != null) desktop.Dispose();
            desktop = new ZommiDesktopFrameCapture(Area);
        }
    }

    public static ZommiDesktopFrameCapture.DeferredFrame CaptureDeferred() {
        EnsureCapture();
        return desktop.CaptureDeferred();
    }

    public static int[] AnalyzeDeferred(ZommiDesktopFrameCapture.DeferredFrame frame, long elapsed) {
        LastPresentationTimestamp = frame.PresentationTimestamp;
        return Analyze(desktop.ReadFrame(frame), elapsed, true);
    }

    public static int[] Capture(long elapsed, bool retain) {
        EnsureCapture();
        var bitmap = desktop.Capture();
        LastPresentationTimestamp = desktop.LastPresentTime;
        return Analyze(bitmap, elapsed, retain);
    }

    private static int[] Analyze(System.Drawing.Bitmap bitmap, long elapsed, bool retain) {
        try {
            var marker = FindMarker(bitmap);
            LastBackground = marker == null ? null : Background(bitmap, marker);
            if (marker == null) {
                System.IO.Directory.CreateDirectory(EvidenceDirectory);
                bitmap.Save(System.IO.Path.Combine(EvidenceDirectory, string.Format("missing-{0:D2}-{1:D4}.png", sequence, elapsed)), System.Drawing.Imaging.ImageFormat.Png);
            }
            if (retain) {
                images.Add(bitmap);
                timestamps.Add(elapsed);
                bitmap = null;
            }
            return marker;
        } finally {
            if (bitmap != null) bitmap.Dispose();
        }
    }

    private static int[] Background(System.Drawing.Bitmap bitmap, int[] marker) {
        var left = marker[0] - Area[0] + marker[2] + (int)System.Math.Round(marker[2] * 0.55);
        var top = marker[1] - Area[1] + marker[3] / 2;
        if (left < 1 || top < 1 || left + 1 >= bitmap.Width || top + 1 >= bitmap.Height) throw new System.InvalidOperationException("The panel background sample is outside the captured frame.");
        var color = new int[3];
        for (var row = top - 1; row <= top + 1; row++) {
            for (var column = left - 1; column <= left + 1; column++) {
                var pixel = bitmap.GetPixel(column, row);
                color[0] += pixel.R;
                color[1] += pixel.G;
                color[2] += pixel.B;
            }
        }
        for (var channel = 0; channel < color.Length; channel++) color[channel] /= 9;
        return color;
    }

    private static int[] FindMarker(System.Drawing.Bitmap bitmap) {
        var rectangle = new System.Drawing.Rectangle(0, 0, bitmap.Width, bitmap.Height);
        var data = bitmap.LockBits(rectangle, System.Drawing.Imaging.ImageLockMode.ReadOnly, bitmap.PixelFormat);
        var pixels = new byte[System.Math.Abs(data.Stride) * data.Height];
        System.Runtime.InteropServices.Marshal.Copy(data.Scan0, pixels, 0, pixels.Length);
        var stride = data.Stride;
        bitmap.UnlockBits(data);
        var width = bitmap.Width;
        var height = bitmap.Height;
        var mask = new bool[width * height];
        for (var row = 0; row < height; row++) {
            for (var column = 0; column < width; column++) {
                var offset = row * stride + column * 4;
                var blue = pixels[offset];
                var green = pixels[offset + 1];
                var red = pixels[offset + 2];
                mask[row * width + column] = red > 50 && red < 170 && green < 150 && blue > 130 && blue > red + 10 && blue > green + 30;
            }
        }
        var queue = new int[mask.Length];
        var largest = 400;
        int[] selected = null;
        for (var start = 0; start < mask.Length; start++) {
            if (!mask[start]) continue;
            var consumed = 0;
            var count = 1;
            queue[0] = start;
            mask[start] = false;
            var left = width;
            var top = height;
            var right = 0;
            var bottom = 0;
            while (consumed < count) {
                var position = queue[consumed++];
                var column = position % width;
                var row = position / width;
                left = System.Math.Min(left, column);
                right = System.Math.Max(right, column);
                top = System.Math.Min(top, row);
                bottom = System.Math.Max(bottom, row);
                for (var direction = 0; direction < 4; direction++) {
                    var neighbor = direction == 0 ? (column > 0 ? position - 1 : -1) : direction == 1 ? (column + 1 < width ? position + 1 : -1) : direction == 2 ? position - width : position + width;
                    if (neighbor < 0 || neighbor >= mask.Length || !mask[neighbor]) continue;
                    mask[neighbor] = false;
                    queue[count++] = neighbor;
                }
            }
            if (count > largest && right - left > 20 && bottom - top > 20) {
                largest = count;
                selected = new [] { Area[0] + left, Area[1] + top, right - left + 1, bottom - top + 1 };
            }
        }
        return selected;
    }

    public static void Save() {
        sequence++;
        System.IO.Directory.CreateDirectory(EvidenceDirectory);
        for (var index = 0; index < images.Count; index++) {
            using (var image = images[index]) {
                image.Save(System.IO.Path.Combine(EvidenceDirectory, string.Format("{0:D2}-{1:D3}-{2:D4}.png", sequence, index, timestamps[index])), System.Drawing.Imaging.ImageFormat.Png);
            }
        }
        images.Clear();
        timestamps.Clear();
    }

    public static void Dispose() {
        if (desktop != null) desktop.Dispose();
        desktop = null;
        foreach (var image in images) image.Dispose();
        images.Clear();
        timestamps.Clear();
    }
}
