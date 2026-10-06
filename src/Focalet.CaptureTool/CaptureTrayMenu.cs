using System.Drawing.Imaging;
using System.Drawing.Text;
using System.Runtime.InteropServices;

namespace Focalet.CaptureTool;

internal sealed record CaptureTrayItem(string Text, Action? Invoke = null, Func<bool>? IsChecked = null);

/// <summary>A native, keyboard-accessible popup matching Desktop's rounded tray surface.</summary>
internal sealed class CaptureTrayMenu : Form
{
    private readonly CaptureTrayItem[] items;
    private readonly Control[] rows;
    private Font? menuFont;
    private int hovered = -1;
    private int dpi = 96;
    private bool painting;
    private bool refreshingChecks;

    internal CaptureTrayMenu(params CaptureTrayItem[] items)
    {
        this.items = items;
        FormBorderStyle = FormBorderStyle.None;
        StartPosition = FormStartPosition.Manual;
        AutoScaleMode = AutoScaleMode.None;
        ShowInTaskbar = false;
        TopMost = true;
        Text = "Focalet Capture menu";
        rows = items.Select((item, index) =>
        {
            Control row = item.Invoke is null ? new MenuLabel() : item.IsChecked is null
                ? new MenuButton() : new MenuCheckBox();
            row.Text = item.Text;
            row.AccessibleName = item.Text;
            row.Enabled = item.Invoke is not null;
            row.TabStop = item.Invoke is not null;
            row.MouseEnter += (_, _) => { hovered = index; PaintSurface(); };
            row.MouseLeave += (_, _) => { hovered = -1; PaintSurface(); };
            row.GotFocus += (_, _) => PaintSurface();
            row.LostFocus += (_, _) => PaintSurface();
            if (row is CheckBox check)
                check.CheckedChanged += (_, _) =>
                {
                    if (refreshingChecks || !Visible) return;
                    Hide(); item.Invoke?.Invoke();
                };
            else row.Click += (_, _) => { Hide(); item.Invoke?.Invoke(); };
            Controls.Add(row);
            return row;
        }).ToArray();
        Deactivate += (_, _) => Hide();
    }

    protected override CreateParams CreateParams
    {
        get { var value = base.CreateParams; value.ExStyle |= 0x80000 | 0x80; return value; }
    }

    internal void ShowAt(Point pointer, string status)
    {
        rows[0].Text = rows[0].AccessibleName = status;
        hovered = -1;
        Location = pointer;
        dpi = (int)GetDpiForWindow(Handle);
        if (dpi == 0) dpi = 96;
        if (menuFont is null || menuFont.Size != Scale(11))
        {
            var previousFont = menuFont;
            Font = menuFont = new Font("Segoe UI", Scale(11), FontStyle.Regular, GraphicsUnit.Pixel);
            previousFont?.Dispose();
        }
        var width = Math.Max(Scale(280), rows.Max(row => TextRenderer.MeasureText(row.Text, Font).Width) + Scale(56));
        Size = new Size(width, Scale(10 + items.Length * 30));
        refreshingChecks = true;
        try
        {
            for (var i = 0; i < rows.Length; i++)
            {
                rows[i].Bounds = new Rectangle(0, Scale(5 + i * 30), width, Scale(30));
                if (rows[i] is CheckBox check) check.Checked = items[i].IsChecked?.Invoke() == true;
            }
        }
        finally { refreshingChecks = false; }
        var work = Screen.FromPoint(pointer).WorkingArea;
        Location = new Point(Math.Clamp(pointer.X - Width, work.Left, Math.Max(work.Left, work.Right - Width)),
            Math.Clamp(pointer.Y - Height, work.Top, Math.Max(work.Top, work.Bottom - Height)));
        Show();
        Activate();
        rows.FirstOrDefault(row => row.Enabled)?.Focus();
        PaintSurface();
    }

    protected override bool ProcessCmdKey(ref Message message, Keys keyData)
    {
        if (keyData == Keys.Escape) { Hide(); return true; }
        if (keyData is Keys.Down or Keys.Up or Keys.Tab or (Keys.Shift | Keys.Tab))
        {
            var enabled = rows.Where(row => row.Enabled).ToArray();
            var current = Array.FindIndex(enabled, row => row.Focused);
            var direction = keyData is Keys.Up or (Keys.Shift | Keys.Tab) ? -1 : 1;
            if (enabled.Length > 0) enabled[(current + direction + enabled.Length) % enabled.Length].Focus();
            return true;
        }
        if (keyData == Keys.Enter)
        {
            var index = Array.FindIndex(rows, row => row.Focused && row.Enabled);
            if (index >= 0) { Hide(); items[index].Invoke?.Invoke(); }
            return true;
        }
        return base.ProcessCmdKey(ref message, keyData);
    }

    protected override void OnPaintBackground(PaintEventArgs e) { }
    protected override void OnPaint(PaintEventArgs e) => PaintSurface();

    private int Scale(int value) => (int)Math.Round(value * dpi / 96.0);

    private void PaintSurface()
    {
        if (painting || Disposing || IsDisposed || !Visible || !IsHandleCreated || Width <= 0 || Height <= 0) return;
        painting = true;
        try
        {
            using var bitmap = new Bitmap(Width, Height, PixelFormat.Format32bppPArgb);
            using (var graphics = Graphics.FromImage(bitmap))
            using (var foreground = new SolidBrush(Color.FromArgb(230, 230, 230)))
            using (var muted = new SolidBrush(Color.FromArgb(160, 160, 160)))
            using (var hover = new SolidBrush(Color.FromArgb(60, 60, 60)))
            using (var format = new StringFormat { LineAlignment = StringAlignment.Center })
            {
                graphics.Clear(Color.FromArgb(40, 40, 40));
                graphics.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;
                for (var i = 0; i < rows.Length; i++)
                {
                    var row = rows[i];
                    if (row.Enabled && (hovered >= 0 ? hovered == i : row.Focused)) graphics.FillRectangle(hover, row.Bounds);
                    if (row is CheckBox { Checked: true })
                        graphics.DrawString("✓", Font, foreground, new Rectangle(Scale(10), row.Top, Scale(20), row.Height), format);
                    graphics.DrawString(row.Text, Font, row.Enabled ? foreground : muted,
                        new Rectangle(Scale(32), row.Top, Width - Scale(44), row.Height), format);
                }
            }
            // Match Desktop's 18-DIP contour, including smooth hover edges on
            // Windows 10 where DWM does not provide rounded popup corners.
            var data = bitmap.LockBits(new Rectangle(Point.Empty, bitmap.Size), ImageLockMode.ReadWrite, PixelFormat.Format32bppPArgb);
            try
            {
                var pixels = new int[Width * Height];
                Marshal.Copy(data.Scan0, pixels, 0, pixels.Length);
                var radius = Scale(18);
                for (var y = 0; y < Height; y++)
                for (var x = 0; x < Width; x++)
                {
                    var dx = Math.Max(Math.Max(radius - (x + 0.5), x + 0.5 - (Width - radius)), 0);
                    var dy = Math.Max(Math.Max(radius - (y + 0.5), y + 0.5 - (Height - radius)), 0);
                    var alpha = (uint)(Math.Clamp(radius + 0.5 - Math.Sqrt(dx * dx + dy * dy), 0, 1) * 255 + 0.5);
                    var pixel = (uint)pixels[y * Width + x];
                    pixels[y * Width + x] = (int)((alpha << 24) | (((pixel >> 16 & 255) * alpha / 255) << 16)
                        | (((pixel >> 8 & 255) * alpha / 255) << 8) | ((pixel & 255) * alpha / 255));
                }
                Marshal.Copy(pixels, 0, data.Scan0, pixels.Length);
            }
            finally { bitmap.UnlockBits(data); }
            var screen = GetDC(0);
            var dc = CreateCompatibleDC(screen);
            var native = bitmap.GetHbitmap(Color.FromArgb(0));
            var previous = SelectObject(dc, native);
            try
            {
                var location = Location; var size = Size; var origin = Point.Empty;
                var blend = new Blend { Alpha = 255, Format = 1 };
                if (!UpdateLayeredWindow(Handle, screen, ref location, ref size, dc, ref origin, 0, ref blend, 2))
                    throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
            }
            finally { SelectObject(dc, previous); DeleteObject(native); DeleteDC(dc); ReleaseDC(0, screen); }
        }
        finally { painting = false; }
    }

    protected override void Dispose(bool disposing)
    {
        base.Dispose(disposing);
        if (disposing) menuFont?.Dispose();
    }

    // The layered surface paints every row. Native child controls retain their
    // keyboard, invoke and toggle accessibility patterns without opaque corners.
    private sealed class MenuLabel : Label
    {
        protected override void OnPaint(PaintEventArgs e) { }
        protected override void OnPaintBackground(PaintEventArgs e) { }
    }
    private sealed class MenuButton : Button
    {
        public MenuButton() => SetStyle(ControlStyles.UserPaint, true);
        protected override void OnPaint(PaintEventArgs e) { }
        protected override void OnPaintBackground(PaintEventArgs e) { }
    }
    private sealed class MenuCheckBox : CheckBox
    {
        public MenuCheckBox() { Appearance = Appearance.Button; SetStyle(ControlStyles.UserPaint, true); }
        protected override void OnPaint(PaintEventArgs e) { }
        protected override void OnPaintBackground(PaintEventArgs e) { }
    }

    [StructLayout(LayoutKind.Sequential)] private struct Blend { public byte Operation, Flags, Alpha, Format; }
    [DllImport("user32.dll")] private static extern uint GetDpiForWindow(nint window);
    [DllImport("user32.dll")] private static extern nint GetDC(nint window);
    [DllImport("user32.dll")] private static extern int ReleaseDC(nint window, nint dc);
    [DllImport("gdi32.dll")] private static extern nint CreateCompatibleDC(nint dc);
    [DllImport("gdi32.dll")] private static extern bool DeleteDC(nint dc);
    [DllImport("gdi32.dll")] private static extern nint SelectObject(nint dc, nint value);
    [DllImport("gdi32.dll")] private static extern bool DeleteObject(nint value);
    [DllImport("user32.dll", SetLastError = true)] private static extern bool UpdateLayeredWindow(nint window, nint screen,
        ref Point location, ref Size size, nint dc, ref Point origin, uint color, ref Blend blend, uint flags);
}
