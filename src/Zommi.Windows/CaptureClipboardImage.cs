using System.Drawing.Imaging;
using Zommi.Capture;

namespace Zommi.Windows;

/// <summary>Exports one selected image at its original resolution.</summary>
internal static class CaptureClipboardImage
{
    internal const long MaximumPixels = 32 * 1024 * 1024;

    public static Bitmap Create(CaptureClipboardItem item)
    {
        if (item.Width <= 0 || item.Height <= 0 || item.Width > 32767 || item.Height > 32767 ||
            (long)item.Width * item.Height > MaximumPixels)
            throw new ArgumentException("The image is too large. Choose a smaller region or use Text only.", nameof(item));
        using var stream = new MemoryStream(item.Png);
        using var image = new Bitmap(stream);
        if (image.Width != item.Width || image.Height != item.Height)
            throw new ArgumentException("A selected image has inconsistent dimensions.", nameof(item));
        var result = new Bitmap(item.Width, item.Height, PixelFormat.Format32bppArgb);
        try
        {
            using var graphics = Graphics.FromImage(result);
            graphics.CompositingMode = System.Drawing.Drawing2D.CompositingMode.SourceCopy;
            graphics.DrawImageUnscaled(image, 0, 0);
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
