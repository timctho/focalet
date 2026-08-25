using System.ComponentModel;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;

namespace Zommi.Windows;

internal sealed record RegionSelectionResult(Rectangle Bounds, byte[] Png);

internal sealed class RegionSelectionForm : Form
{
    private readonly Func<Rectangle, byte[]> captureRegion;
    private Point? anchor;
    private Rectangle selectedArea;

    public RegionSelectionForm(Func<Rectangle, byte[]>? captureRegion = null)
    {
        this.captureRegion = captureRegion ?? (area => ScreenCapture.CapturePng(area));
        Text = "Zommi image selection";
        FormBorderStyle = FormBorderStyle.None;
        StartPosition = FormStartPosition.Manual;
        Bounds = SystemInformation.VirtualScreen;
        ShowInTaskbar = false;
        TopMost = true;
        KeyPreview = true;
        DoubleBuffered = true;
        Cursor = Cursors.Cross;
        BackColor = Color.Black;
        Opacity = 0.28;

        KeyDown += (_, eventArgs) =>
        {
            if (eventArgs.KeyCode == Keys.Escape)
            {
                DialogResult = DialogResult.Cancel;
                Close();
            }
        };
    }

    public RegionSelectionResult? Result { get; private set; }

    public string? ErrorMessage { get; private set; }

    protected override void OnMouseDown(MouseEventArgs eventArgs)
    {
        base.OnMouseDown(eventArgs);
        if (eventArgs.Button != MouseButtons.Left)
        {
            return;
        }

        anchor = eventArgs.Location;
        selectedArea = Rectangle.Empty;
        Capture = true;
        Invalidate();
    }

    protected override void OnMouseMove(MouseEventArgs eventArgs)
    {
        base.OnMouseMove(eventArgs);
        if (anchor is not { } start)
        {
            return;
        }

        selectedArea = Normalize(start, eventArgs.Location);
        Invalidate();
    }

    protected override void OnMouseUp(MouseEventArgs eventArgs)
    {
        base.OnMouseUp(eventArgs);
        if (eventArgs.Button != MouseButtons.Left || anchor is not { } start)
        {
            return;
        }

        Capture = false;
        anchor = null;
        selectedArea = Normalize(start, eventArgs.Location);
        if (selectedArea.Width < 4 || selectedArea.Height < 4)
        {
            selectedArea = Rectangle.Empty;
            Invalidate();
            return;
        }

        var screenArea = new Rectangle(
            Left + selectedArea.Left,
            Top + selectedArea.Top,
            selectedArea.Width,
            selectedArea.Height);
        Hide();
        Application.DoEvents();
        Thread.Sleep(80);

        try
        {
            Result = new RegionSelectionResult(screenArea, captureRegion(screenArea));
            DialogResult = DialogResult.OK;
        }
        catch (Exception exception) when (exception is ExternalException or ArgumentException or Win32Exception)
        {
            ErrorMessage = exception.Message;
            DialogResult = DialogResult.Abort;
        }

        Close();
    }

    protected override void OnPaint(PaintEventArgs eventArgs)
    {
        base.OnPaint(eventArgs);
        if (selectedArea.IsEmpty)
        {
            using var instructionFont = new Font("Segoe UI Semibold", 14f);
            const string instruction = "Drag to select image context · Esc to cancel";
            var size = eventArgs.Graphics.MeasureString(instruction, instructionFont);
            var x = (ClientSize.Width - size.Width) / 2f;
            var y = Math.Max(24f, ClientSize.Height * 0.12f);
            eventArgs.Graphics.DrawString(instruction, instructionFont, Brushes.White, x, y);
            return;
        }

        eventArgs.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        using var fill = new SolidBrush(Color.FromArgb(45, 255, 255, 255));
        using var border = new Pen(Color.White, 2f);
        eventArgs.Graphics.FillRectangle(fill, selectedArea);
        eventArgs.Graphics.DrawRectangle(border, selectedArea);
        using var sizeFont = new Font("Segoe UI", 9f);
        eventArgs.Graphics.DrawString(
            $"{selectedArea.Width} × {selectedArea.Height}",
            sizeFont,
            Brushes.White,
            selectedArea.Left + 6,
            selectedArea.Top + 6);
    }

    private static Rectangle Normalize(Point first, Point second) => Rectangle.FromLTRB(
        Math.Min(first.X, second.X),
        Math.Min(first.Y, second.Y),
        Math.Max(first.X, second.X),
        Math.Max(first.Y, second.Y));

}
