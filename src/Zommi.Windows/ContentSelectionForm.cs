using Zommi.Capture;

namespace Zommi.Windows;

internal sealed record ContentSelection(Rectangle Region, nint Window, CaptureRectangle? WindowBounds,
    string? WindowTitle, int ProcessId);

/// <summary>Draw rectangles without depending on the source application's accessibility provider.</summary>
internal sealed class ContentSelectionForm : PointSelectionForm
{
    private readonly FlowLayoutPanel toolbar = new()
    {
        AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink,
        WrapContents = false, Padding = new Padding(8),
        BackColor = Color.FromArgb(35, 39, 51), ForeColor = Color.White,
    };
    private readonly Label hint = new() { AutoSize = true, Padding = new Padding(8, 10, 8, 4) };
    private readonly Button attach;
    private readonly List<ContentSelection> selections = [];
    private Point? anchor;
    private Rectangle dragged;
    private bool additive;
    private bool controlAtMouseDown;
    private const int MaximumSelections = 8;

    public ContentSelectionForm(uint returnProcessId) : base(returnProcessId)
    {
        Text = "Zommi content selection";
        Opacity = 0.65;
        toolbar.Controls.Add(hint);
        attach = AddButton("Attach", Finish);
        AddButton("Cancel", Cancel);
        Controls.Add(toolbar);
        UpdateHint();
        var area = Screen.FromPoint(Cursor.Position).WorkingArea;
        var size = toolbar.PreferredSize;
        toolbar.Location = new Point(area.Left + Math.Max(12, (area.Width - size.Width) / 2) - Left, area.Top + 24 - Top);
    }

    public IReadOnlyList<ContentSelection> Selections => selections;
    public string? ErrorMessage => null;

    private Button AddButton(string text, Action action)
    {
        var button = new Button { Text = text, AccessibleName = text, AutoSize = true, FlatStyle = FlatStyle.Flat };
        button.Click += (_, _) => action();
        toolbar.Controls.Add(button);
        return button;
    }

    protected override bool ProcessCmdKey(ref Message message, Keys keyData)
    {
        if ((keyData & Keys.KeyCode) == Keys.Enter) { if (anchor is null) Finish(); return true; }
        if (keyData == Keys.Escape) { Cancel(); return true; }
        return base.ProcessCmdKey(ref message, keyData);
    }

    private void UpdateHint()
    {
        hint.Text = selections.Count == 0 ? "Drag a rectangle · Ctrl to select several · Esc to cancel" :
            $"{selections.Count}/{MaximumSelections} selected · Enter to attach · Esc to cancel";
        attach.Enabled = selections.Count > 0;
    }

    protected override void WndProc(ref Message message)
    {
        // WM_LBUTTONDOWN carries the modifiers for this input event. Reading
        // thread keyboard state later can lose Ctrl when foreground activation
        // attaches/detaches input queues, or the user releases it while queued.
        if (message.Msg is 0x0201 or 0x0203) controlAtMouseDown = (message.WParam.ToInt64() & 0x0008) != 0;
        base.WndProc(ref message);
    }

    protected override void OnMouseDown(MouseEventArgs e)
    {
        if (e.Button == MouseButtons.Right) { Cancel(); return; }
        if (e.Button != MouseButtons.Left) return;
        anchor = PointToScreen(e.Location);
        additive = controlAtMouseDown || selections.Count > 0;
        dragged = Rectangle.Empty;
        Capture = true;
    }

    protected override void OnMouseMove(MouseEventArgs e)
    {
        if (anchor is not { } start) return;
        var previous = dragged;
        dragged = RectangleBetween(start, PointToScreen(e.Location));
        InvalidateArea(previous);
        InvalidateArea(dragged);
    }

    protected override void OnMouseUp(MouseEventArgs e)
    {
        if (e.Button != MouseButtons.Left || anchor is not { } start) return;
        Capture = false;
        anchor = null;
        var previous = dragged;
        var bounds = RectangleBetween(start, PointToScreen(e.Location));
        dragged = Rectangle.Empty;
        InvalidateArea(previous);
        if (bounds.Width < 4 || bounds.Height < 4 || selections.Count >= MaximumSelections) return;
        var window = NativeCaptureWindow.ForRegion(bounds);
        var selected = new ContentSelection(bounds, window, window == 0 ? null : NativeCaptureWindow.Bounds(window),
            window == 0 ? null : NativeCaptureWindow.Title(window), window == 0 ? 0 : NativeCaptureWindow.ProcessId(window));
        if (!selections.Contains(selected)) selections.Add(selected);
        UpdateHint();
        InvalidateArea(bounds);
        if (!additive) Finish();
    }

    private void Finish()
    {
        if (selections.Count == 0) return;
        GrantForeground();
        DialogResult = DialogResult.OK;
        Close();
    }

    private void Cancel() { GrantForeground(); DialogResult = DialogResult.Cancel; Close(); }

    private static Rectangle RectangleBetween(Point a, Point b) => Rectangle.FromLTRB(
        Math.Min(a.X, b.X), Math.Min(a.Y, b.Y), Math.Max(a.X, b.X), Math.Max(a.Y, b.Y));

    private void InvalidateArea(Rectangle bounds)
    {
        if (bounds.IsEmpty) return;
        bounds.Offset(-Left, -Top);
        bounds.Inflate(6, 30);
        Invalidate(bounds);
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        using var border = new Pen(Color.White, 3);
        using var selectedBorder = new Pen(Color.FromArgb(111, 205, 255), 3);
        using var font = new Font("Segoe UI", 10, FontStyle.Bold);
        for (var index = 0; index < selections.Count; index++)
        {
            var bounds = selections[index].Region;
            bounds.Offset(-Left, -Top);
            e.Graphics.DrawRectangle(selectedBorder, bounds);
            e.Graphics.FillRectangle(Brushes.Black, bounds.Left, Math.Max(0, bounds.Top - 24), 28, 24);
            e.Graphics.DrawString((index + 1).ToString(), font, Brushes.White, bounds.Left + 3, Math.Max(0, bounds.Top - 24));
        }
        if (dragged.IsEmpty) return;
        var rectangle = dragged;
        rectangle.Offset(-Left, -Top);
        e.Graphics.DrawRectangle(border, rectangle);
        e.Graphics.DrawString($"{rectangle.Width} × {rectangle.Height}", font, Brushes.White, rectangle.Left + 6, rectangle.Top + 6);
    }
}
