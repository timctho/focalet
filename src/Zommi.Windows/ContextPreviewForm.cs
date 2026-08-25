using System.IO;
using System.Runtime.InteropServices;

namespace Zommi.Windows;

internal sealed class ContextPreviewForm : Form
{
    private readonly RichTextBox text = new();
    private readonly PictureBox image = new();

    public ContextPreviewForm()
    {
        Text = "Zommi context preview";
        ClientSize = new Size(440, 280);
        FormBorderStyle = FormBorderStyle.None;
        StartPosition = FormStartPosition.Manual;
        ShowInTaskbar = false;
        TopMost = true;
        BackColor = Color.FromArgb(42, 42, 43);
        ForeColor = Color.White;
        Opacity = 0.97;
        Padding = new Padding(12);

        text.Dock = DockStyle.Fill;
        text.ReadOnly = true;
        text.BorderStyle = BorderStyle.None;
        text.BackColor = BackColor;
        text.ForeColor = Color.FromArgb(240, 240, 240);
        text.Font = new Font("Segoe UI", 9.5f);
        text.ScrollBars = RichTextBoxScrollBars.Vertical;
        text.Name = "ContextPreviewText";
        text.AccessibleName = "Attached context preview";

        image.Dock = DockStyle.Top;
        image.Height = 150;
        image.SizeMode = PictureBoxSizeMode.Zoom;
        image.BackColor = Color.FromArgb(28, 28, 29);
        image.Name = "ContextPreviewImage";
        image.AccessibleName = "Attached visual context preview";
        image.Visible = false;

        Controls.Add(text);
        Controls.Add(image);
        TrackPointer(this);
        Resize += (_, _) => ApplyRoundedRegion();
        HandleCreated += (_, _) => ApplyRoundedRegion();
    }

    public event EventHandler? PointerEntered;

    public event EventHandler? PointerExited;

    protected override bool ShowWithoutActivation => true;

    protected override CreateParams CreateParams
    {
        get
        {
            const int wsExNoActivate = 0x08000000;
            const int wsExToolWindow = 0x00000080;
            var parameters = base.CreateParams;
            parameters.ExStyle |= wsExNoActivate | wsExToolWindow;
            return parameters;
        }
    }

    public void ShowContext(ContextAttachment attachment, Point pointer)
    {
        text.Text = attachment.PreviewText;
        image.Image?.Dispose();
        image.Image = null;
        image.Visible = attachment.ImagePng is not null;
        if (attachment.ImagePng is not null)
        {
            using var stream = new MemoryStream(attachment.ImagePng);
            using var source = Image.FromStream(stream);
            image.Image = new Bitmap(source);
        }

        var workArea = Screen.FromPoint(pointer).WorkingArea;
        var x = pointer.X + 18;
        var y = pointer.Y + 18;
        if (x + Width > workArea.Right)
        {
            x = pointer.X - Width - 18;
        }

        if (y + Height > workArea.Bottom)
        {
            y = pointer.Y - Height - 18;
        }

        Location = new Point(
            Math.Clamp(x, workArea.Left, Math.Max(workArea.Left, workArea.Right - Width)),
            Math.Clamp(y, workArea.Top, Math.Max(workArea.Top, workArea.Bottom - Height)));
        if (!Visible)
        {
            Show();
        }
        else
        {
            Invalidate();
        }
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            image.Image?.Dispose();
        }

        base.Dispose(disposing);
    }

    private void ApplyRoundedRegion()
    {
        if (Width <= 0 || Height <= 0)
        {
            return;
        }

        var handle = NativeMethods.CreateRoundRectRgn(0, 0, Width + 1, Height + 1, 20, 20);
        if (handle == IntPtr.Zero)
        {
            return;
        }

        var replacement = System.Drawing.Region.FromHrgn(handle);
        _ = NativeMethods.DeleteObject(handle);
        var previous = Region;
        Region = replacement;
        previous?.Dispose();
    }

    private void TrackPointer(Control control)
    {
        control.MouseEnter += (_, eventArgs) => PointerEntered?.Invoke(this, eventArgs);
        control.MouseLeave += (_, _) => ReportPointerExitIfOutside();
        foreach (Control child in control.Controls)
        {
            TrackPointer(child);
        }
    }

    private void ReportPointerExitIfOutside()
    {
        if (IsDisposed || !IsHandleCreated)
        {
            return;
        }

        BeginInvoke(() =>
        {
            if (!IsDisposed && Visible && !Bounds.Contains(Cursor.Position))
            {
                PointerExited?.Invoke(this, EventArgs.Empty);
            }
        });
    }

    private static class NativeMethods
    {
        [DllImport("gdi32.dll")]
        internal static extern IntPtr CreateRoundRectRgn(
            int left,
            int top,
            int right,
            int bottom,
            int widthEllipse,
            int heightEllipse);

        [DllImport("gdi32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool DeleteObject(IntPtr graphicsObject);
    }
}
