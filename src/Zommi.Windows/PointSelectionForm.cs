using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;

namespace Zommi.Windows;

internal sealed class PointSelectionForm : Form
{
    private static readonly nint TopMostWindow = new(-1);
    private const int ExtendedStyleTopMost = 0x00000008;
    private const int ExtendedStyleToolWindow = 0x00000080;
    private const uint NoMove = 0x0002;
    private const uint NoSize = 0x0001;
    private const uint NoActivate = 0x0010;
    private const uint ShowWindow = 0x0040;

    private readonly System.Windows.Forms.Timer topMostGuard;

    public PointSelectionForm()
    {
        Text = "Zommi context selection";
        FormBorderStyle = FormBorderStyle.None;
        StartPosition = FormStartPosition.Manual;
        Bounds = SystemInformation.VirtualScreen;
        ShowInTaskbar = false;
        TopMost = true;
        KeyPreview = true;
        DoubleBuffered = true;
        Cursor = Cursors.Cross;
        BackColor = Color.Magenta;
        TransparencyKey = Color.Magenta;

        topMostGuard = new System.Windows.Forms.Timer { Interval = 120 };
        topMostGuard.Tick += (_, _) =>
        {
            if (Visible)
            {
                KeepAboveOtherWindows(activate: false);
            }
        };

        KeyDown += (_, eventArgs) =>
        {
            if (eventArgs.KeyCode == Keys.Escape)
            {
                DialogResult = DialogResult.Cancel;
                Close();
            }
        };
    }

    public Point? Result { get; private set; }

    protected override CreateParams CreateParams
    {
        get
        {
            var parameters = base.CreateParams;
            parameters.ExStyle |= ExtendedStyleTopMost | ExtendedStyleToolWindow;
            return parameters;
        }
    }

    protected override void OnShown(EventArgs eventArgs)
    {
        base.OnShown(eventArgs);
        KeepAboveOtherWindows(activate: true);
        topMostGuard.Start();
    }

    protected override void OnFormClosed(FormClosedEventArgs eventArgs)
    {
        topMostGuard.Stop();
        base.OnFormClosed(eventArgs);
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            topMostGuard.Dispose();
        }
        base.Dispose(disposing);
    }

    protected override void OnMouseDown(MouseEventArgs eventArgs)
    {
        base.OnMouseDown(eventArgs);
        if (eventArgs.Button == MouseButtons.Right)
        {
            DialogResult = DialogResult.Cancel;
            Close();
            return;
        }
        if (eventArgs.Button != MouseButtons.Left)
        {
            return;
        }

        Result = Cursor.Position;
        DialogResult = DialogResult.OK;
        Close();
    }

    protected override void OnPaint(PaintEventArgs eventArgs)
    {
        base.OnPaint(eventArgs);
        eventArgs.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        const string instruction = "Click a window or control to attach its context · Esc to cancel";
        using var font = new Font("Segoe UI Semibold", 11f);
        var textSize = eventArgs.Graphics.MeasureString(instruction, font);
        var pill = new RectangleF(
            Math.Max(20f, (ClientSize.Width - textSize.Width) / 2f - 16f),
            Math.Max(20f, ClientSize.Height * 0.08f),
            textSize.Width + 32f,
            textSize.Height + 18f);
        using var path = RoundedRectangle(pill, 12f);
        using var fill = new SolidBrush(Color.FromArgb(232, 39, 43, 56));
        eventArgs.Graphics.FillPath(fill, path);
        eventArgs.Graphics.DrawString(
            instruction,
            font,
            Brushes.White,
            pill.Left + 16f,
            pill.Top + 9f);
    }

    private static GraphicsPath RoundedRectangle(RectangleF bounds, float radius)
    {
        var diameter = radius * 2f;
        var path = new GraphicsPath();
        path.AddArc(bounds.Left, bounds.Top, diameter, diameter, 180, 90);
        path.AddArc(bounds.Right - diameter, bounds.Top, diameter, diameter, 270, 90);
        path.AddArc(bounds.Right - diameter, bounds.Bottom - diameter, diameter, diameter, 0, 90);
        path.AddArc(bounds.Left, bounds.Bottom - diameter, diameter, diameter, 90, 90);
        path.CloseFigure();
        return path;
    }

    private void KeepAboveOtherWindows(bool activate)
    {
        TopMost = true;
        var flags = NoMove | NoSize | ShowWindow;
        if (!activate)
        {
            flags |= NoActivate;
        }
        SetWindowPos(Handle, TopMostWindow, 0, 0, 0, 0, flags);
        if (activate)
        {
            BringWindowToTop(Handle);
            Activate();
            SetForegroundWindow(Handle);
            SetFocus(Handle);
        }
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool SetWindowPos(
        nint window,
        nint insertAfter,
        int x,
        int y,
        int width,
        int height,
        uint flags);

    [DllImport("user32.dll")]
    private static extern bool SetForegroundWindow(nint window);

    [DllImport("user32.dll")]
    private static extern bool BringWindowToTop(nint window);

    [DllImport("user32.dll")]
    private static extern nint SetFocus(nint window);
}
