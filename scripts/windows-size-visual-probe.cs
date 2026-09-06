public static class ZommiRenderedSizeProbe {
    [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern System.IntPtr SetThreadDpiAwarenessContext(System.IntPtr context);
    [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern System.IntPtr GetDC(System.IntPtr window);
    [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern int ReleaseDC(System.IntPtr window, System.IntPtr context);
    [System.Runtime.InteropServices.DllImport("gdi32.dll")] private static extern bool BitBlt(System.IntPtr target, int targetLeft, int targetTop, int width, int height, System.IntPtr source, int sourceLeft, int sourceTop, uint operation);

    public static int[] Area;
    public static string EvidenceDirectory;
    private static int sequence;
    private static readonly System.Collections.Generic.List<System.Drawing.Bitmap> images = new System.Collections.Generic.List<System.Drawing.Bitmap>();
    private static readonly System.Collections.Generic.List<long> timestamps = new System.Collections.Generic.List<long>();

    public static int[] Capture(long elapsed, bool retain) {
        var previous = SetThreadDpiAwarenessContext(new System.IntPtr(-4));
        var bitmap = new System.Drawing.Bitmap(Area[2], Area[3], System.Drawing.Imaging.PixelFormat.Format24bppRgb);
        try {
            using (var graphics = System.Drawing.Graphics.FromImage(bitmap)) {
                var destination = graphics.GetHdc();
                var source = GetDC(System.IntPtr.Zero);
                var copied = BitBlt(destination, 0, 0, bitmap.Width, bitmap.Height, source, Area[0], Area[1], 0x00CC0020);
                ReleaseDC(System.IntPtr.Zero, source);
                graphics.ReleaseHdc(destination);
                if (!copied) throw new System.InvalidOperationException("Rendered size capture failed.");
            }
            var marker = FindMarker(bitmap);
            if (retain && elapsed < 1200) {
                images.Add(bitmap);
                timestamps.Add(elapsed);
                bitmap = null;
            }
            return marker;
        } finally {
            if (bitmap != null) bitmap.Dispose();
            SetThreadDpiAwarenessContext(previous);
        }
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
                var offset = row * stride + column * 3;
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
}
