using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;
using Zommi.Capture;

namespace Zommi.Windows;

internal sealed record RegionSelectionResult(Rectangle Bounds, byte[] Png,
    ContextSnapshot? Snapshot = null, RegionAlignment? Alignment = null);

internal sealed class RegionSelectionForm : Form
{
    private static readonly nint TopMostWindow = new(-1);
    private const int ExtendedStyleTopMost = 0x00000008;
    private const int ExtendedStyleToolWindow = 0x00000080;
    private const uint NoMove = 0x0002;
    private const uint NoSize = 0x0001;
    private const uint NoActivate = 0x0010;
    private const uint ShowWindow = 0x0040;

    private readonly uint returnProcessId;
    private readonly System.Windows.Forms.Timer topMostGuard;
    private Point? anchor;
    private Rectangle selectedArea;

    public RegionSelectionForm(uint returnProcessId = 0)
    {
        this.returnProcessId = returnProcessId;
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

        // Screen selection is a short-lived modal desktop operation. A
        // different always-on-top app can otherwise enter the topmost band
        // after this form and cover part of the selectable surface. Reassert
        // the z-order while selection is active, just like native snipping UI.
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
                GrantForeground();
                DialogResult = DialogResult.Cancel;
                Close();
            }
        };
    }

    public Rectangle? Result { get; private set; }

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

    protected override void OnActivated(EventArgs eventArgs)
    {
        base.OnActivated(eventArgs);
        KeepAboveOtherWindows(activate: false);
    }

    protected override void OnDeactivate(EventArgs eventArgs)
    {
        base.OnDeactivate(eventArgs);
        if (Visible)
        {
            KeepAboveOtherWindows(activate: false);
        }
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

        Result = new Rectangle(
            Left + selectedArea.Left,
            Top + selectedArea.Top,
            selectedArea.Width,
            selectedArea.Height);
        topMostGuard.Stop();
        GrantForeground();
        // Finish the input message before the host queries another process's
        // accessibility provider, which may need the sender's message pump.
        DialogResult = DialogResult.OK;
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

    private void KeepAboveOtherWindows(bool activate)
    {
        TopMost = true;
        var flags = NoMove | NoSize | ShowWindow;
        if (!activate)
        {
            flags |= NoActivate;
        }
        SetWindowPos(
            Handle,
            TopMostWindow,
            0,
            0,
            0,
            0,
            flags);
        if (activate)
        {
            ForceForeground();
        }
    }

    private void ForceForeground()
    {
        var foreground = GetForegroundWindow();
        var foregroundThread = foreground == nint.Zero
            ? 0
            : GetWindowThreadProcessId(foreground, out _);
        var currentThread = GetCurrentThreadId();
        var attached = foregroundThread != 0 &&
            foregroundThread != currentThread &&
            AttachThreadInput(currentThread, foregroundThread, true);
        try
        {
            BringWindowToTop(Handle);
            Activate();
            SetForegroundWindow(Handle);
            SetFocus(Handle);
        }
        finally
        {
            if (attached)
            {
                AttachThreadInput(currentThread, foregroundThread, false);
            }
        }
    }

    private void GrantForeground()
    {
        if (returnProcessId != 0) AllowSetForegroundWindow(returnProcessId);
    }

    [DllImport("user32.dll")]
    private static extern bool AllowSetForegroundWindow(uint processId);

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
    private static extern nint GetForegroundWindow();

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(nint window, out uint processId);

    [DllImport("kernel32.dll")]
    private static extern uint GetCurrentThreadId();

    [DllImport("user32.dll")]
    private static extern bool AttachThreadInput(uint attach, uint attachTo, bool value);

    [DllImport("user32.dll")]
    private static extern bool BringWindowToTop(nint window);

    [DllImport("user32.dll")]
    private static extern nint SetFocus(nint window);

}
