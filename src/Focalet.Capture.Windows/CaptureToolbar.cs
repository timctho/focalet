using System.Drawing.Drawing2D;

namespace Focalet.Windows;

internal sealed class CaptureToolbar : Panel
{
    private readonly CaptureTheme theme;
    private readonly Dictionary<string, CaptureToolButton> buttons = [];
    private readonly ToolTip tips = new() { InitialDelay = 350, ReshowDelay = 100 };
    private readonly Label hint;
    private readonly float scale;
    public event Action<string>? Invoked;

    public CaptureToolbar(float scale, CaptureTheme theme, string confirmLabel = "Attach", string? destinationName = null)
    {
        this.theme = theme;
        this.scale = scale;
        DoubleBuffered = true;
        BackColor = theme.Surface;
        AccessibleName = "Capture drawing toolbar";
        Size = new Size(S(554), S(destinationName is null ? 98 : 126));
        var x = 12;
        foreach (var (id, label) in new (string, string)[]
        {
            ("select", "Add region (S or Ctrl-drag)"), ("pen", "Pen (P)"), ("arrow", "Arrow (A)"),
            ("rectangle", "Rectangle (R)"), ("ellipse", "Ellipse (O)"), ("highlighter", "Highlighter (H)"),
            ("undo", "Undo (Ctrl+Z)"), ("redo", "Redo (Ctrl+Y)"), ("delete", "Remove region (Delete)"),
        })
        {
            Add(id, label, new Rectangle(S(x), S(10), S(36), S(36)));
            x += 40;
            if (id is "highlighter") x += 10;
        }
        Add("attach", $"{confirmLabel} (Enter)", new Rectangle(S(394), S(10), S(104), S(36)), confirmLabel);
        Add("cancel", "Cancel (Esc)", new Rectangle(S(506), S(10), S(36), S(36)));
        var colors = new[] { ("#FF686B", "Coral"), ("#FFD166", "Amber"), ("#A6E3BA", "Mint"), ("#70B8FF", "Blue"), ("#FFFFFF", "White") };
        for (var i = 0; i < colors.Length; i++)
            Add(colors[i].Item1, colors[i].Item2, new Rectangle(S(12 + i * 25), S(60), S(23), S(25)));
        for (var i = 0; i < 3; i++)
            Add($"width{i}", new[] { "Thin stroke", "Medium stroke", "Thick stroke" }[i], new Rectangle(S(151 + i * 29), S(60), S(27), S(25)));
        hint = new Label
        {
            AutoSize = false, Bounds = new Rectangle(S(248), S(62), S(292), S(24)),
            ForeColor = theme.Muted, BackColor = theme.Surface, TextAlign = ContentAlignment.MiddleRight,
            Font = new Font("Segoe UI", 9f),
        };
        Controls.Add(hint);
        if (destinationName is not null)
        {
            var destination = new Label
            {
                Text = "Paste to: " + destinationName.Replace('\r', ' ').Replace('\n', ' '),
                Bounds = new Rectangle(S(12), S(96), S(530), S(22)), AutoEllipsis = true,
                ForeColor = theme.OnSurface, BackColor = theme.Surface, Font = new Font("Segoe UI", 9f),
            };
            Controls.Add(destination);
            tips.SetToolTip(destination, destination.Text);
        }
    }

    private int S(int value) => (int)Math.Round(value * scale);
    private void Add(string id, string label, Rectangle bounds, string text = "")
    {
        var name = label.Split(" (", StringSplitOptions.None)[0];
        var button = new CaptureToolButton(id, theme) { Bounds = bounds, Text = text.Length > 0 ? text : name, AccessibleName = name, AccessibleDescription = label, Font = new Font("Segoe UI Semibold", 9f) };
        button.Click += (_, _) => Invoked?.Invoke(id);
        buttons.Add(id, button);
        Controls.Add(button);
        tips.SetToolTip(button, label);
    }

    public void UpdateState(string tool, string color, int width, int count, int maximum, bool undo, bool redo, string status)
    {
        foreach (var (id, button) in buttons)
        {
            button.Selected = id == tool || id == color || id == $"width{width}";
            button.Enabled = id switch
            {
                "cancel" => true,
                "select" => count < maximum,
                "undo" => undo,
                "redo" => redo,
                _ => count > 0,
            };
            button.Invalidate();
        }
        hint.Text = status;
        AccessibleDescription = status;
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        base.OnPaint(e);
        e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        using var path = Rounded(new RectangleF(.5f, .5f, Width - 1, Height - 1), S(14));
        using var line = new Pen(theme.Outline);
        e.Graphics.DrawPath(line, path);
        using var divider = new Pen(theme.Outline);
        e.Graphics.DrawLine(divider, S(14), S(52), Width - S(14), S(52));
    }

    protected override void OnSizeChanged(EventArgs e)
    {
        base.OnSizeChanged(e);
        if (Width <= 0 || Height <= 0) return;
        using var path = Rounded(ClientRectangle, Math.Max(12, S(14)));
        var old = Region;
        Region = new Region(path);
        old?.Dispose();
    }

    internal static GraphicsPath Rounded(RectangleF bounds, float radius)
    {
        var diameter = Math.Min(radius * 2, Math.Min(bounds.Width, bounds.Height));
        var path = new GraphicsPath();
        path.AddArc(bounds.Left, bounds.Top, diameter, diameter, 180, 90);
        path.AddArc(bounds.Right - diameter, bounds.Top, diameter, diameter, 270, 90);
        path.AddArc(bounds.Right - diameter, bounds.Bottom - diameter, diameter, diameter, 0, 90);
        path.AddArc(bounds.Left, bounds.Bottom - diameter, diameter, diameter, 90, 90);
        path.CloseFigure();
        return path;
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing) { tips.Dispose(); foreach (Control child in Controls) child.Font.Dispose(); }
        base.Dispose(disposing);
    }
}

internal sealed class CaptureToolButton(string icon, CaptureTheme theme) : Button
{
    public bool Selected { get; set; }
    private bool hovered;
    protected override void OnMouseEnter(EventArgs e) { base.OnMouseEnter(e); hovered = true; Invalidate(); }
    protected override void OnMouseLeave(EventArgs e) { base.OnMouseLeave(e); hovered = false; Invalidate(); }
    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.Clear(theme.Surface);
        var active = Enabled && (Selected || icon == "attach");
        using var path = CaptureToolbar.Rounded(new RectangleF(1, 1, Width - 2, Height - 2), 8);
        using var fill = new SolidBrush(active ? theme.Accent : hovered && Enabled ? theme.Hover : theme.Surface);
        g.FillPath(fill, path);
        var color = !Enabled ? theme.Outline : active ? theme.OnAccent : theme.OnSurface;
        using var pen = new Pen(color, 1.8f) { StartCap = LineCap.Round, EndCap = LineCap.Round, LineJoin = LineJoin.Round };
        using var brush = new SolidBrush(color);
        if (icon == "attach")
        {
            TextRenderer.DrawText(g, Text + "  ↵", Font, ClientRectangle, color, TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter);
        }
        else if (icon.StartsWith('#'))
        {
            var diameter = Math.Min(Width, Height) - 10;
            using var swatch = new SolidBrush(ColorTranslator.FromHtml(icon));
            g.FillEllipse(swatch, (Width - diameter) / 2f, (Height - diameter) / 2f, diameter, diameter);
            if (Selected) g.DrawEllipse(pen, (Width - diameter) / 2f - 2, (Height - diameter) / 2f - 2, diameter + 4, diameter + 4);
        }
        else
        {
            var state = g.Save();
            g.TranslateTransform(Width / 2f, Height / 2f);
            var factor = Math.Min(Width / 36f, Height / 36f);
            g.ScaleTransform(factor, factor);
            switch (icon)
            {
                case "select":
                    g.DrawRectangle(pen, -8, -8, 16, 16); g.DrawLine(pen, -4, 0, 4, 0); g.DrawLine(pen, 0, -4, 0, 4); break;
                case "pen":
                    g.DrawPolygon(pen, [new(-8, 8), new(-6, 2), new(4, -8), new(8, -4), new(-2, 6)]); g.DrawLine(pen, 2, -6, 6, -2); break;
                case "arrow":
                    g.DrawLine(pen, -8, 8, 8, -8); g.DrawLines(pen, [new(-2, -8), new(8, -8), new(8, 2)]); break;
                case "rectangle": g.DrawRectangle(pen, -9, -7, 18, 14); break;
                case "ellipse": g.DrawEllipse(pen, -9, -7, 18, 14); break;
                case "highlighter":
                    g.DrawPolygon(pen, [new(-5, 3), new(3, -9), new(9, -5), new(1, 7)]); g.DrawLine(pen, -9, 10, 7, 10); break;
                case "undo":
                    g.DrawArc(pen, -6, -4, 15, 12, 220, 275); g.DrawLines(pen, [new(-9, -8), new(-9, -1), new(-2, -1)]); break;
                case "redo":
                    g.DrawArc(pen, -9, -4, 15, 12, 45, 275); g.DrawLines(pen, [new(9, -8), new(9, -1), new(2, -1)]); break;
                case "delete":
                    g.DrawLine(pen, -8, -5, 8, -5); g.DrawLines(pen, [new(-6, -2), new(-5, 9), new(5, 9), new(6, -2)]); g.DrawLine(pen, -3, -9, 3, -9); break;
                case "cancel": g.DrawLine(pen, -6, -6, 6, 6); g.DrawLine(pen, -6, 6, 6, -6); break;
                case "width0": g.FillEllipse(brush, -2, -2, 4, 4); break;
                case "width1": g.FillEllipse(brush, -3.5f, -3.5f, 7, 7); break;
                case "width2": g.FillEllipse(brush, -5, -5, 10, 10); break;
            }
            g.Restore(state);
        }
        if (Focused && ShowFocusCues)
        {
            using var focus = new Pen(theme.Muted) { DashStyle = DashStyle.Dot };
            g.DrawPath(focus, path);
        }
    }
}
