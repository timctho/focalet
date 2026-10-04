using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using Zommi.Capture;

namespace Zommi.Windows;

internal sealed record ContentSelection(Rectangle Region, nint Window, CaptureRectangle? WindowBounds,
    string? WindowTitle, int ProcessId, byte[] FrozenPng, DateTimeOffset FrozenAtUtc,
    IReadOnlyList<ImageAnnotation> Annotations);

/// <summary>Freeze, select, annotate and explicitly attach without waiting on a source provider.</summary>
internal class ContentSelectionForm : PointSelectionForm
{
    private sealed record Entry(ContentSelection Selection, AnnotationDocument Drawing);
    private readonly List<Entry> entries = [];
    private readonly Bitmap desktop;
    private readonly DateTimeOffset frozenAt;
    private readonly CaptureToolbar toolbar;
    private readonly CaptureTheme theme;
    private readonly int maximumSelections;
    private readonly string confirmLabel;
    private readonly float scale;
    private Point? anchor;
    private Rectangle dragged;
    private bool controlAtMouseDown;
    private bool continuousSelection;
    private int activeIndex = -1;
    private string tool = "select";
    private string color = "#FF686B";
    private int widthIndex = 1;
    private readonly List<AnnotationPoint> points = [];
    private ImageAnnotation? pendingStroke;

    public ContentSelectionForm(uint returnProcessId, Bitmap capturedDesktop, int maximumSelections = 8, CaptureTheme? theme = null,
        string confirmLabel = "Attach", string? destinationName = null) : base(returnProcessId)
    {
        Text = "Zommi content selection";
        this.maximumSelections = maximumSelections;
        this.confirmLabel = confirmLabel;
        AutoScaleMode = AutoScaleMode.None;
        Opacity = 1;
        frozenAt = DateTimeOffset.UtcNow;
        desktop = capturedDesktop;
        scale = Math.Max(1, DeviceDpi / 96f);
        this.theme = theme ?? CaptureTheme.Default;
        toolbar = new CaptureToolbar(scale, this.theme, confirmLabel, destinationName);
        toolbar.Invoked += InvokeTool;
        Controls.Add(toolbar);
        UpdateToolbar(reposition: true);
    }

    public IReadOnlyList<ContentSelection> Selections => entries.Select(entry => entry.Selection with
    {
        Annotations = entry.Drawing.Strokes.ToArray(),
    }).ToArray();
    public string? ErrorMessage => null;
    private Entry? Active => activeIndex >= 0 && activeIndex < entries.Count ? entries[activeIndex] : null;

    protected override void OnKeyDown(KeyEventArgs e)
    {
        base.OnKeyDown(e);
        if (e.KeyCode == Keys.ControlKey) { UpdateToolbar(); Invalidate(); }
    }

    protected override void OnKeyUp(KeyEventArgs e)
    {
        base.OnKeyUp(e);
        if (e.KeyCode == Keys.ControlKey) { UpdateToolbar(reposition: true); Invalidate(); }
    }

    protected override bool ProcessCmdKey(ref Message message, Keys keyData)
    {
        if (keyData == Keys.Escape) { Cancel(); return true; }
        if (keyData is Keys.Enter or (Keys.Control | Keys.Enter)) { if (anchor is null && pendingStroke is null) Finish(); return true; }
        if (anchor is not null || pendingStroke is not null) return base.ProcessCmdKey(ref message, keyData);
        var action = keyData switch
        {
            Keys.Control | Keys.Z => "undo", Keys.Control | Keys.Y => "redo", Keys.Control | Keys.Shift | Keys.Z => "redo",
            Keys.Delete => "delete", Keys.S => "select", Keys.P => "pen", Keys.A => "arrow",
            Keys.R => "rectangle", Keys.O => "ellipse", Keys.H => "highlighter", _ => null,
        };
        if (action is null) return base.ProcessCmdKey(ref message, keyData);
        InvokeTool(action);
        return true;
    }

    private void InvokeTool(string action)
    {
        if (anchor is not null || pendingStroke is not null) return;
        switch (action)
        {
            case "attach": Finish(); return;
            case "cancel": Cancel(); return;
            case "undo": Active?.Drawing.Undo(); break;
            case "redo": Active?.Drawing.Redo(); break;
            case "delete":
                if (activeIndex >= 0) entries.RemoveAt(activeIndex);
                activeIndex = Math.Min(activeIndex, entries.Count - 1);
                if (entries.Count == 0) { tool = "select"; continuousSelection = false; }
                break;
            case "select": if (entries.Count < maximumSelections) tool = action; break;
            default:
                if (action.StartsWith('#')) color = action;
                else if (action.StartsWith("width", StringComparison.Ordinal)) widthIndex = int.Parse(action.AsSpan(5), System.Globalization.CultureInfo.InvariantCulture);
                else if (Active is not null) { tool = action; continuousSelection = false; }
                break;
        }
        UpdateToolbar(reposition: action is "delete" or "select", choosingRegion: action == "select");
        Invalidate();
        Focus();
    }

    private void UpdateToolbar(bool reposition = false, bool choosingRegion = false)
    {
        var status = Active is { } active
            ? active.Drawing.Strokes.Count >= AnnotationDocument.MaximumStrokes
                ? "Drawing limit · Undo a mark to continue"
                : tool == "select" && continuousSelection
                    ? entries.Count >= maximumSelections ? $"Region limit · Draw, then {confirmLabel.ToLowerInvariant()}" : "Select more · Choose a tool to draw"
                    : $"{(char)('A' + activeIndex)} · {active.Selection.Region.Width} × {active.Selection.Region.Height} · Draw, then {confirmLabel.ToLowerInvariant()}"
            : "Drag to select · Ctrl for more";
        toolbar.UpdateState(tool, color, widthIndex, entries.Count, maximumSelections,
            Active?.Drawing.CanUndo ?? false, Active?.Drawing.CanRedo ?? false, status);
        // Ctrl-drag can start where the previous crop's toolbar was. Keep that
        // area available until Ctrl is released and the current drag is complete.
        toolbar.Visible = (ModifierKeys & Keys.Control) == 0 && anchor is null;
        Cursor = Cursors.Cross;
        if (reposition)
        {
            // Explicit Add region/S still moves the toolbar away for the next
            // drag. A completed Ctrl crop anchors it to that crop instead.
            var region = choosingRegion ? null : Active?.Selection.Region;
            var screen = Screen.FromPoint(region is { } selected ? new Point(selected.Left + selected.Width / 2, selected.Top + selected.Height / 2) : Cursor.Position);
            var available = screen.WorkingArea;
            var margin = (int)(12 * scale);
            var x = region?.Left ?? available.Left + (available.Width - toolbar.Width) / 2;
            var y = region is { } bounds ? bounds.Bottom + margin : available.Top + (int)(24 * scale);
            if (y + toolbar.Height > available.Bottom - margin && region is { } above) y = above.Top - toolbar.Height - margin;
            x = Math.Clamp(x, available.Left + margin, Math.Max(available.Left + margin, available.Right - toolbar.Width - margin));
            y = Math.Clamp(y, available.Top + margin, Math.Max(available.Top + margin, available.Bottom - toolbar.Height - margin));
            toolbar.Location = new Point(x - Left, y - Top);
        }
    }

    protected override void WndProc(ref Message message)
    {
        if (message.Msg is 0x0201 or 0x0203) controlAtMouseDown = (message.WParam.ToInt64() & 0x0008) != 0;
        base.WndProc(ref message);
    }

    protected override void OnMouseDown(MouseEventArgs e)
    {
        if (e.Button == MouseButtons.Right) { Cancel(); return; }
        if (e.Button != MouseButtons.Left) return;
        if (!controlAtMouseDown)
        {
            for (var index = entries.Count - 1; index >= 0; index--)
                if (Badge(entries[index].Selection.Region).Contains(e.Location))
                {
                    activeIndex = index;
                    if (tool == "select") tool = "pen";
                    continuousSelection = false;
                    UpdateToolbar(reposition: true); Invalidate(); return;
                }
        }
        if (tool == "select" || controlAtMouseDown)
        {
            if (entries.Count >= maximumSelections) return;
            anchor = PointToScreen(e.Location);
            dragged = Rectangle.Empty;
            Capture = true;
            UpdateToolbar(); Invalidate();
            return;
        }
        var screenPoint = PointToScreen(e.Location);
        for (var index = entries.Count - 1; index >= 0; index--)
            if (entries[index].Selection.Region.Contains(screenPoint))
            {
                activeIndex = index;
                if (Active!.Drawing.Strokes.Count >= AnnotationDocument.MaximumStrokes) { UpdateToolbar(); return; }
                points.Clear();
                points.Add(LocalPoint(screenPoint));
                pendingStroke = CurrentStroke();
                Capture = true;
                UpdateToolbar();
                InvalidateArea(entries[index].Selection.Region);
                return;
            }
    }

    protected override void OnMouseMove(MouseEventArgs e)
    {
        var screenPoint = PointToScreen(e.Location);
        if (anchor is { } start)
        {
            var previous = dragged;
            dragged = Rectangle.Intersect(RectangleBetween(start, screenPoint), Bounds);
            InvalidateArea(previous); InvalidateArea(dragged);
        }
        else if (pendingStroke is not null)
        {
            AddPoint(screenPoint);
            pendingStroke = CurrentStroke();
            InvalidateArea(Active!.Selection.Region);
        }
    }

    protected override void OnMouseUp(MouseEventArgs e)
    {
        if (e.Button != MouseButtons.Left) return;
        if (pendingStroke is not null)
        {
            AddPoint(PointToScreen(e.Location));
            Active!.Drawing.Add(CurrentStroke());
            pendingStroke = null; points.Clear(); Capture = false;
            UpdateToolbar(); InvalidateArea(Active.Selection.Region);
            return;
        }
        if (anchor is not { } start) return;
        Capture = false; anchor = null;
        var previous = dragged;
        var bounds = Rectangle.Intersect(RectangleBetween(start, PointToScreen(e.Location)), Bounds);
        dragged = Rectangle.Empty;
        InvalidateArea(previous);
        if (bounds.Width < 4 || bounds.Height < 4 || entries.Count >= maximumSelections) { UpdateToolbar(); return; }
        var duplicate = entries.FindIndex(entry => entry.Selection.Region == bounds);
        if (duplicate >= 0) activeIndex = duplicate;
        else
        {
            var window = NativeCaptureWindow.ForRegion(bounds);
            var crop = bounds; crop.Offset(-Left, -Top);
            using var image = desktop.Clone(crop, PixelFormat.Format32bppArgb);
            var selected = new ContentSelection(bounds, window, window == 0 ? null : NativeCaptureWindow.Bounds(window),
                window == 0 ? null : NativeCaptureWindow.Title(window), window == 0 ? 0 : NativeCaptureWindow.ProcessId(window),
                ScreenCapture.EncodePng(image), frozenAt, []);
            entries.Add(new Entry(selected, new AnnotationDocument()));
            activeIndex = entries.Count - 1;
        }
        // Ctrl starts continuous selection. Releasing it must not turn the next
        // crop into a one-shot selection; an explicit drawing tool or badge exits.
        continuousSelection |= controlAtMouseDown;
        tool = continuousSelection ? "select" : "pen";
        UpdateToolbar(reposition: true);
        Invalidate();
    }

    private AnnotationPoint LocalPoint(Point point)
    {
        var region = Active!.Selection.Region;
        return new(Math.Clamp(point.X - region.Left, 0, region.Width - 1), Math.Clamp(point.Y - region.Top, 0, region.Height - 1));
    }

    private void AddPoint(Point point)
    {
        var local = LocalPoint(point);
        if (tool is "pen" or "highlighter")
        {
            if (points.Count < AnnotationDocument.MaximumPointsPerStroke && points[^1] != local) points.Add(local);
        }
        else if (points.Count == 1) points.Add(local);
        else points[1] = local;
    }

    private ImageAnnotation CurrentStroke() => new(Enum.Parse<AnnotationTool>(tool, true), color,
        Math.Min(64, new[] { 2f, 4f, 7f }[widthIndex] * scale * (tool == "highlighter" ? 4 : 1)), points.ToArray());

    private void Finish()
    {
        if (entries.Count == 0 || anchor is not null || pendingStroke is not null) return;
        GrantForeground(); DialogResult = DialogResult.OK; Close();
    }
    private void Cancel() { GrantForeground(); DialogResult = DialogResult.Cancel; Close(); }
    private static Rectangle RectangleBetween(Point a, Point b) => Rectangle.FromLTRB(Math.Min(a.X, b.X), Math.Min(a.Y, b.Y), Math.Max(a.X, b.X), Math.Max(a.Y, b.Y));
    private void InvalidateArea(Rectangle bounds)
    {
        if (bounds.IsEmpty) return;
        bounds.Offset(-Left, -Top); bounds.Inflate(8, 36); Invalidate(bounds);
    }
    private Rectangle Badge(Rectangle screen)
    {
        var size = (int)(24 * scale);
        return new Rectangle(screen.Left - Left, Math.Max(3, screen.Top - Top - size - 6), size, size);
    }

    protected override void OnPaintBackground(PaintEventArgs e) { }
    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics;
        g.DrawImageUnscaled(desktop, 0, 0);
        using (var dimmed = new Region(ClientRectangle))
        {
            foreach (var entry in entries) { var r = entry.Selection.Region; r.Offset(-Left, -Top); dimmed.Exclude(r); }
            if (!dragged.IsEmpty) { var r = dragged; r.Offset(-Left, -Top); dimmed.Exclude(r); }
            using var shade = new SolidBrush(Color.FromArgb(135, theme.Surface));
            g.FillRegion(shade, dimmed);
        }
        g.SmoothingMode = SmoothingMode.AntiAlias;
        for (var index = 0; index < entries.Count; index++)
        {
            var entry = entries[index];
            var bounds = entry.Selection.Region; bounds.Offset(-Left, -Top);
            var state = g.Save();
            g.SetClip(bounds); g.TranslateTransform(bounds.Left, bounds.Top);
            foreach (var stroke in entry.Drawing.Strokes) AnnotationRenderer.Draw(g, stroke);
            if (index == activeIndex && pendingStroke is not null) AnnotationRenderer.Draw(g, pendingStroke);
            g.Restore(state);
            DrawFrame(g, bounds, index == activeIndex);
            var badge = Badge(entry.Selection.Region);
            using var badgePath = CaptureToolbar.Rounded(badge, 6 * scale);
            using var badgeFill = new SolidBrush(index == activeIndex ? theme.Accent : theme.Surface);
            g.FillPath(badgeFill, badgePath);
            using var font = new Font("Segoe UI Semibold", 10f);
            TextRenderer.DrawText(g, ((char)('A' + index)).ToString(), font, badge,
                index == activeIndex ? theme.OnAccent : theme.Accent, TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter);
        }
        if (!dragged.IsEmpty)
        {
            var rectangle = dragged; rectangle.Offset(-Left, -Top);
            DrawFrame(g, rectangle, true);
            using var font = new Font("Segoe UI Semibold", 10f);
            var label = new Rectangle(rectangle.Left + 8, rectangle.Top + 8, 150, 26);
            using var fill = new SolidBrush(theme.Surface); g.FillRectangle(fill, label);
            TextRenderer.DrawText(g, $"{rectangle.Width} × {rectangle.Height}", font, label, theme.Accent, TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter);
        }
        for (var i = toolbar.Visible ? 3 : 0; i > 0; i--)
        {
            var shadow = toolbar.Bounds; shadow.Inflate(i * 2, i * 2); shadow.Offset(0, 2);
            using var path = CaptureToolbar.Rounded(shadow, 16 * scale);
            using var brush = new SolidBrush(Color.FromArgb(18, 0, 0, 0)); g.FillPath(brush, path);
        }
    }

    private void DrawFrame(Graphics g, Rectangle bounds, bool active)
    {
        using var border = new Pen(active ? theme.Accent : theme.Outline, active ? 2f : 1f);
        g.DrawRectangle(border, bounds);
        if (!active) return;
        using var corner = new Pen(theme.Accent, 3f) { StartCap = LineCap.Round, EndCap = LineCap.Round };
        var length = Math.Min(12, Math.Min(bounds.Width, bounds.Height) / 3);
        foreach (var (x, y, dx, dy) in new[]
        {
            (bounds.Left, bounds.Top, 1, 1), (bounds.Right, bounds.Top, -1, 1),
            (bounds.Left, bounds.Bottom, 1, -1), (bounds.Right, bounds.Bottom, -1, -1),
        }) g.DrawLines(corner, [new(x + dx * length, y), new(x, y), new(x, y + dy * length)]);
    }

}
