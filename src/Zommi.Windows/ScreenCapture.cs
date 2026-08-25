using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;

namespace Zommi.Windows;

internal static class ScreenCapture
{
    public static byte[] CapturePng(Rectangle screenArea, int maximumDimension = int.MaxValue)
    {
        if (screenArea.Width <= 0 || screenArea.Height <= 0)
        {
            throw new ArgumentException("The screen capture area must have a positive size.", nameof(screenArea));
        }

        using var source = new Bitmap(screenArea.Width, screenArea.Height, PixelFormat.Format32bppArgb);
        using (var graphics = Graphics.FromImage(source))
        {
            graphics.CopyFromScreen(screenArea.Location, Point.Empty, screenArea.Size, CopyPixelOperation.SourceCopy);
        }

        var scale = Math.Min(1d, maximumDimension / (double)Math.Max(source.Width, source.Height));
        if (scale >= 1d)
        {
            return EncodePng(source);
        }

        var targetSize = new Size(
            Math.Max(1, (int)Math.Round(source.Width * scale)),
            Math.Max(1, (int)Math.Round(source.Height * scale)));
        using var resized = new Bitmap(targetSize.Width, targetSize.Height, PixelFormat.Format32bppArgb);
        using (var graphics = Graphics.FromImage(resized))
        {
            graphics.CompositingQuality = CompositingQuality.HighQuality;
            graphics.InterpolationMode = InterpolationMode.HighQualityBicubic;
            graphics.PixelOffsetMode = PixelOffsetMode.HighQuality;
            graphics.SmoothingMode = SmoothingMode.HighQuality;
            graphics.DrawImage(source, new Rectangle(Point.Empty, targetSize));
        }

        return EncodePng(resized);
    }

    private static byte[] EncodePng(Image image)
    {
        using var stream = new MemoryStream();
        image.Save(stream, ImageFormat.Png);
        return stream.ToArray();
    }
}
