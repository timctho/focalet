using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using Zommi.Capture;

namespace Zommi.Windows;

internal static class AnnotationRenderer
{
    public static void Draw(Graphics graphics, ImageAnnotation stroke)
    {
        if (stroke.Points.Count == 0) return;
        var color = ColorTranslator.FromHtml(stroke.Color);
        if (stroke.Tool == AnnotationTool.Highlighter) color = Color.FromArgb(85, color);
        using var pen = new Pen(color, stroke.Width)
        {
            StartCap = LineCap.Round, EndCap = LineCap.Round, LineJoin = LineJoin.Round,
        };
        var points = stroke.Points.Select(point => new PointF(point.X, point.Y)).ToArray();
        if (stroke.Tool is AnnotationTool.Pen or AnnotationTool.Highlighter)
        {
            // Draw a stroke into one path, so translucent joints do not darken.
            if (points.Length == 1)
            {
                using var brush = new SolidBrush(color);
                graphics.FillEllipse(brush, points[0].X - pen.Width / 2, points[0].Y - pen.Width / 2, pen.Width, pen.Width);
            }
            else graphics.DrawLines(pen, points);
            return;
        }
        if (points.Length != 2) return;
        var a = points[0]; var b = points[1];
        var bounds = RectangleF.FromLTRB(Math.Min(a.X, b.X), Math.Min(a.Y, b.Y), Math.Max(a.X, b.X), Math.Max(a.Y, b.Y));
        switch (stroke.Tool)
        {
            case AnnotationTool.Rectangle:
                graphics.DrawRectangle(pen, bounds.X, bounds.Y, bounds.Width, bounds.Height);
                break;
            case AnnotationTool.Ellipse:
                if (bounds.Width > 0 && bounds.Height > 0) graphics.DrawEllipse(pen, bounds);
                break;
            case AnnotationTool.Arrow:
                graphics.DrawLine(pen, a, b);
                var angle = Math.Atan2(b.Y - a.Y, b.X - a.X);
                var length = Math.Min(Math.Max(12, stroke.Width * 3), Math.Sqrt(Math.Pow(b.X - a.X, 2) + Math.Pow(b.Y - a.Y, 2)) * .5);
                graphics.DrawLines(pen,
                [
                    new((float)(b.X - length * Math.Cos(angle - .55)), (float)(b.Y - length * Math.Sin(angle - .55))),
                    b,
                    new((float)(b.X - length * Math.Cos(angle + .55)), (float)(b.Y - length * Math.Sin(angle + .55))),
                ]);
                break;
        }
    }

    public static byte[] Apply(byte[] png, IReadOnlyList<ImageAnnotation> strokes)
    {
        if (strokes.Count == 0) return png;
        using var stream = new System.IO.MemoryStream(png);
        using var original = new Bitmap(stream);
        using var image = new Bitmap(original.Width, original.Height, PixelFormat.Format32bppArgb);
        using (var graphics = Graphics.FromImage(image))
        {
            graphics.DrawImageUnscaled(original, 0, 0);
            graphics.SetClip(new Rectangle(0, 0, image.Width, image.Height));
            graphics.SmoothingMode = SmoothingMode.AntiAlias;
            foreach (var stroke in strokes) Draw(graphics, stroke);
        }
        return ScreenCapture.EncodePng(image);
    }

    public static bool SamePixels(byte[] first, byte[] second)
    {
        using var firstStream = new System.IO.MemoryStream(first);
        using var secondStream = new System.IO.MemoryStream(second);
        using var a = new Bitmap(firstStream);
        using var b = new Bitmap(secondStream);
        if (a.Size != b.Size) return false;
        var bounds = new Rectangle(Point.Empty, a.Size);
        var aData = a.LockBits(bounds, ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
        try
        {
            var bData = b.LockBits(bounds, ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
            try
            {
                var firstRow = new byte[a.Width * 4]; var secondRow = new byte[a.Width * 4];
                for (var row = 0; row < a.Height; row++)
                {
                    Marshal.Copy(aData.Scan0 + row * aData.Stride, firstRow, 0, firstRow.Length);
                    Marshal.Copy(bData.Scan0 + row * bData.Stride, secondRow, 0, secondRow.Length);
                    // GDI and browser PNGs can differ only in their unused alpha byte.
                    for (var x = 0; x < firstRow.Length; x += 4)
                        if (firstRow[x] != secondRow[x] || firstRow[x + 1] != secondRow[x + 1] || firstRow[x + 2] != secondRow[x + 2]) return false;
                }
                return true;
            }
            finally { b.UnlockBits(bData); }
        }
        finally { a.UnlockBits(aData); }
    }
}
