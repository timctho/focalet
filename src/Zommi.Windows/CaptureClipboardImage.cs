using System.Drawing.Imaging;
using Zommi.Capture;

namespace Zommi.Windows;

/// <summary>One native clipboard image keeps every selection in image-only paste handlers.</summary>
internal static class CaptureClipboardImage
{
    internal const long MaximumPixels = 32 * 1024 * 1024;

    public static Bitmap Create(IReadOnlyList<CaptureClipboardItem> items)
    {
        if (items.Count == 0) throw new ArgumentException("No selected images.", nameof(items));
        const int labelHeight = 28;
        var width = items.Max(item => item.Width);
        var height = items.Sum(item => (long)item.Height + (items.Count > 1 ? labelHeight : 0));
        if (width > 32767 || height > 32767 || width * height > MaximumPixels)
            throw new ArgumentException("The combined image is too large. Choose smaller regions or use Text only.", nameof(items));
        var result = new Bitmap(width, (int)height, PixelFormat.Format32bppArgb);
        try
        {
            using var graphics = Graphics.FromImage(result);
            graphics.Clear(Color.White);
            using var font = new Font("Segoe UI", 11, FontStyle.Bold, GraphicsUnit.Pixel);
            var top = 0;
            for (var index = 0; index < items.Count; index++)
            {
                var item = items[index];
                if (items.Count > 1)
                {
                    graphics.DrawString($"[{(char)('A' + index)}] {item.Width} × {item.Height}", font, Brushes.Black, 6, top + 6);
                    top += labelHeight;
                }
                using var stream = new MemoryStream(item.Png);
                using var image = new Bitmap(stream);
                if (image.Width != item.Width || image.Height != item.Height)
                    throw new ArgumentException("A selected image has inconsistent dimensions.", nameof(items));
                graphics.DrawImageUnscaled(image, 0, top);
                top += image.Height;
            }
            return result;
        }
        catch { result.Dispose(); throw; }
    }

    public static byte[] Dib(Bitmap image)
    {
        using var stream = new MemoryStream();
        image.Save(stream, ImageFormat.Bmp);
        // CF_DIB is the BMP info header and pixels, without BITMAPFILEHEADER.
        return stream.ToArray()[14..];
    }
}
