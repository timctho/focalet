using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;
using System.Runtime.InteropServices;

namespace Zommi.Windows;

internal static class ScreenCapture
{
    private const uint SourceCopy = 0x00CC0020;

    public static byte[] CapturePng(Rectangle screenArea, int maximumDimension = int.MaxValue)
    {
        if (screenArea.Width <= 0 || screenArea.Height <= 0)
        {
            throw new ArgumentException("The screen capture area must have a positive size.", nameof(screenArea));
        }

        using var source = CaptureBitmap(screenArea);

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

    public static Bitmap CaptureBitmap(Rectangle screenArea)
    {
        var image = new Bitmap(screenArea.Width, screenArea.Height, PixelFormat.Format32bppArgb);
        try
        {
            using var graphics = Graphics.FromImage(image);
            CopyFromDesktop(graphics, screenArea);
            return image;
        }
        catch { image.Dispose(); throw; }
    }

    internal static byte[] EncodePng(Image image)
    {
        using var stream = new MemoryStream();
        image.Save(stream, ImageFormat.Png);
        return stream.ToArray();
    }

    private static void CopyFromDesktop(Graphics target, Rectangle screenArea)
    {
        var desktopDc = GetDC(nint.Zero);
        if (desktopDc == nint.Zero)
        {
            throw new System.ComponentModel.Win32Exception(
                Marshal.GetLastWin32Error(),
                "Could not acquire the Windows desktop device context.");
        }

        var targetDc = nint.Zero;
        try
        {
            targetDc = target.GetHdc();
            if (!BitBlt(
                targetDc,
                0,
                0,
                screenArea.Width,
                screenArea.Height,
                desktopDc,
                screenArea.X,
                screenArea.Y,
                SourceCopy))
            {
                throw new System.ComponentModel.Win32Exception(
                    Marshal.GetLastWin32Error(),
                    "Could not copy pixels from the Windows desktop device context.");
            }
        }
        finally
        {
            if (targetDc != nint.Zero)
            {
                target.ReleaseHdc(targetDc);
            }
            _ = ReleaseDC(nint.Zero, desktopDc);
        }
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern nint GetDC(nint window);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern int ReleaseDC(nint window, nint deviceContext);

    [DllImport("gdi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool BitBlt(
        nint destination,
        int destinationX,
        int destinationY,
        int width,
        int height,
        nint source,
        int sourceX,
        int sourceY,
        uint operation);
}
