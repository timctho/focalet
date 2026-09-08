using Zommi.Capture;

namespace Zommi.Windows;

/// <summary>One desktop gesture surface: click an outlined object, drag a region,
/// or choose the whole window. Selection clicks never reach the source app.</summary>
internal sealed class ContentSelectionForm : PointSelectionForm
{
    private readonly ForegroundContextCapture capture;
    private readonly uint excludedProcessId;
    private readonly System.Windows.Forms.Timer hoverTimer = new() { Interval = 160 };
    private readonly FlowLayoutPanel toolbar = new() { AutoSize = true, WrapContents = false, Padding = new Padding(8) };
    private readonly Button larger;
    private readonly Button smaller;
    private readonly Button wholeWindow;
    private readonly Label hint = new() { AutoSize = true, Padding = new Padding(8, 10, 8, 4) };
    private IReadOnlyList<ContextScopeChoice> scopes = [];
    private int scopeIndex;
    private Point? lastPoint;
    private Point? anchor;
    private Rectangle dragged;
    private nint targetWindow;
    private CaptureRectangle? targetBounds;
    private string targetTitle = "";

    public ContentSelectionForm(ForegroundContextCapture capture, uint returnProcessId) : base(returnProcessId)
    {
        this.capture = capture;
        excludedProcessId = returnProcessId;
        Text = "Zommi content selection";
        Opacity = 0.65;
        toolbar.BackColor = Color.FromArgb(35, 39, 51);
        toolbar.ForeColor = Color.White;
        toolbar.Controls.Add(hint);
        smaller = AddButton("Smaller", () => ChangeScope(-1));
        larger = AddButton("Larger", () => ChangeScope(1));
        wholeWindow = AddButton("Whole window", SelectWindow);
        AddButton("Cancel", () => { GrantForeground(); DialogResult = DialogResult.Cancel; Close(); });
        Controls.Add(toolbar);
        PositionToolbar(Cursor.Position);
        UpdateHint();
        hoverTimer.Tick += (_, _) => ObservePointer();
    }

    public Rectangle? SelectedRegion { get; private set; }
    public nint SelectedWindow { get; private set; }
    public CaptureRectangle? SelectedWindowBounds { get; private set; }
    public string? SelectedWindowTitle { get; private set; }

    protected override bool ProcessCmdKey(ref Message message, Keys keyData)
    {
        // Enter confirms the outlined content even when a toolbar button has
        // focus. Otherwise WinForms can activate the initially focused Cancel.
        if (keyData == Keys.Enter) { SelectObject(); return true; }
        if (keyData == Keys.Up) { ChangeScope(1); return true; }
        if (keyData == Keys.Down) { ChangeScope(-1); return true; }
        return base.ProcessCmdKey(ref message, keyData);
    }

    private Button AddButton(string text, Action action)
    {
        var button = new Button { Text = text, AccessibleName = text, AutoSize = true, FlatStyle = FlatStyle.Flat, TabStop = true };
        button.Click += (_, _) => action();
        toolbar.Controls.Add(button);
        return button;
    }

    protected override void OnShown(EventArgs e)
    {
        base.OnShown(e);
        hoverTimer.Start();
        ObservePointer();
    }

    private void PositionToolbar(Point point)
    {
        var area = Screen.FromPoint(point).WorkingArea;
        var size = toolbar.PreferredSize;
        var bounds = scopes.Count > 0 ? scopes[scopeIndex].Bounds : Rectangle.Empty;
        var x = bounds.IsEmpty ? area.Left + (area.Width - size.Width) / 2 : bounds.Left;
        var y = bounds.IsEmpty ? area.Top + 24 : bounds.Bottom + 8;
        if (y + size.Height > area.Bottom - 12) y = bounds.Top - size.Height - 8;
        toolbar.Location = new Point(
            Math.Clamp(x, area.Left + 12, Math.Max(area.Left + 12, area.Right - size.Width - 12)) - Left,
            Math.Clamp(y, area.Top + 12, Math.Max(area.Top + 12, area.Bottom - size.Height - 12)) - Top);
    }

    private void ObservePointer()
    {
        var point = Cursor.Position;
        if (anchor is not null || toolbar.Bounds.Contains(PointToClient(point)) || point == lastPoint) return;
        if (scopes.Count > 0)
        {
            var selected = scopes[scopeIndex].Bounds;
            selected.Inflate(10, 10);
            if (selected.Contains(point)) return;
        }
        lastPoint = point;
        targetWindow = NativeCaptureWindow.BeneathOverlay(point, excludedProcessId);
        targetBounds = targetWindow == 0 ? null : NativeCaptureWindow.Bounds(targetWindow);
        targetTitle = targetWindow == 0 ? "" : NativeCaptureWindow.Title(targetWindow);
        scopes = targetWindow == 0 ? [] : capture.ScopeChoices(point, targetWindow)
            .Where(scope => targetBounds is { } bounds &&
                BrowserObservationBridge.ToRectangle(scope.Bounds) != bounds &&
                scope.Bounds.Width > 3 && scope.Bounds.Height > 3 &&
                bounds.Contains(BrowserObservationBridge.ToRectangle(scope.Bounds)))
            .ToArray();
        scopeIndex = 0;
        UpdateHint();
        PositionToolbar(point);
        Invalidate();
    }

    private void ChangeScope(int delta)
    {
        if (scopes.Count == 0) return;
        scopeIndex = Math.Clamp(scopeIndex + delta, 0, scopes.Count - 1);
        UpdateHint();
        Invalidate();
    }

    private void UpdateHint()
    {
        hint.Text = scopes.Count == 0 ? "Drag to select a region" : "Click an outline or drag a region";
        smaller.Enabled = scopeIndex > 0;
        larger.Enabled = scopeIndex + 1 < scopes.Count;
        wholeWindow.Enabled = targetBounds is { IsValid: true };
    }

    private void SelectObject()
    {
        if (scopes.Count == 0) return;
        Complete(scopes[scopeIndex].Bounds, targetWindow);
    }

    private void SelectWindow()
    {
        if (targetBounds is not { IsValid: true } bounds) return;
        var rectangle = Rectangle.FromLTRB((int)bounds.X, (int)bounds.Y, (int)bounds.Right, (int)bounds.Bottom);
        // Only the visible desktop portion can be shared by this capture path.
        Complete(Rectangle.Intersect(rectangle, SystemInformation.VirtualScreen), targetWindow);
    }

    private void Complete(Rectangle bounds, nint window)
    {
        if (bounds.Width < 4 || bounds.Height < 4) return;
        SelectedRegion = bounds;
        SelectedWindow = window;
        SelectedWindowBounds = window == 0 ? null : targetBounds;
        SelectedWindowTitle = window == 0 ? null : targetTitle;
        GrantForeground();
        DialogResult = DialogResult.OK;
        Close();
    }

    protected override void OnMouseDown(MouseEventArgs e)
    {
        if (e.Button == MouseButtons.Right) { GrantForeground(); DialogResult = DialogResult.Cancel; Close(); return; }
        if (e.Button != MouseButtons.Left) return;
        ObservePointer();
        anchor = PointToScreen(e.Location);
        dragged = Rectangle.Empty;
        Capture = true;
    }

    protected override void OnMouseMove(MouseEventArgs e)
    {
        base.OnMouseMove(e);
        if (anchor is not { } start) return;
        var point = PointToScreen(e.Location);
        dragged = Rectangle.FromLTRB(Math.Min(start.X, point.X), Math.Min(start.Y, point.Y), Math.Max(start.X, point.X), Math.Max(start.Y, point.Y));
        Invalidate();
    }

    protected override void OnMouseUp(MouseEventArgs e)
    {
        if (e.Button != MouseButtons.Left || anchor is not { } start) return;
        var point = PointToScreen(e.Location);
        anchor = null;
        Capture = false;
        if (Math.Abs(point.X - start.X) >= 4 || Math.Abs(point.Y - start.Y) >= 4)
            Complete(Rectangle.FromLTRB(Math.Min(start.X, point.X), Math.Min(start.Y, point.Y), Math.Max(start.X, point.X), Math.Max(start.Y, point.Y)), 0);
        else SelectObject();
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        var bounds = anchor is not null ? dragged : scopes.Count > 0 ? scopes[scopeIndex].Bounds : Rectangle.Empty;
        if (bounds.IsEmpty) return;
        bounds.Offset(-Left, -Top);
        using var pen = new Pen(Color.White, 3);
        using var fill = new SolidBrush(Color.FromArgb(45, 255, 255, 255));
        e.Graphics.FillRectangle(fill, bounds);
        e.Graphics.DrawRectangle(pen, bounds);
        var label = anchor is not null ? $"{bounds.Width} × {bounds.Height}" : scopes[scopeIndex].Label;
        using var font = new Font("Segoe UI", 11);
        var size = e.Graphics.MeasureString(label, font);
        var position = new PointF(Math.Clamp(bounds.Left, 4, Math.Max(4, ClientSize.Width - size.Width - 16)), Math.Clamp(bounds.Top - size.Height - 8, 4, Math.Max(4, ClientSize.Height - size.Height - 12)));
        e.Graphics.FillRectangle(Brushes.Black, position.X, position.Y, size.Width + 12, size.Height + 6);
        e.Graphics.DrawString(label, font, Brushes.White, position.X + 6, position.Y + 3);
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing) hoverTimer.Dispose();
        base.Dispose(disposing);
    }
}
