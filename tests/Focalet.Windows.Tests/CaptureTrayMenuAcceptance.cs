using Focalet.CaptureTool;
using Focalet.Windows;
using FlaUI.UIA3;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Windows.Forms;

internal static class CaptureTrayMenuAcceptance
{
    public static int Run()
    {
        Exception? failure = null;
        var previous = CapturePasteTarget.RememberWindow();
        var thread = new Thread(() =>
        {
            Application.SetHighDpiMode(HighDpiMode.PerMonitorV2);
            using var loop = new Form { ShowInTaskbar = false, Location = new(-30000, -30000), StartPosition = FormStartPosition.Manual };
            loop.Shown += async (_, _) =>
            {
                loop.Hide();
                try { await RunAsync(); }
                catch (Exception error) { failure = error; }
                finally { loop.Close(); }
            };
            Application.Run(loop);
        });
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start(); thread.Join();
        previous?.Restore();
        if (failure is null) return 0;
        Console.Error.WriteLine(failure); return 1;
    }

    public static async Task RunAsync()
    {
        var invoked = 0;
        var textOnly = false;
        var backdrop = Color.FromArgb(16, 88, 128);
        using var background = new Form { Text = "Synthetic Capture menu fixture", Size = new(900, 700),
            BackColor = backdrop, StartPosition = FormStartPosition.CenterScreen, TopMost = true };
        using var menu = new CaptureTrayMenu(new("No capture ready"), new("Capture · Shift+Alt+A", () => invoked++),
            new("Copy last batch", () => invoked++), new("Copy text", () => invoked++),
            new("Text only", () => textOnly = !textOnly, () => textOnly),
            new("Slower image paste", () => { }, () => false), new("Quit", () => invoked++));
        background.Show(); background.Activate();
        var point = new Point(background.Right - 60, background.Bottom - 60);
        menu.ShowAt(point, "2 regions ready · Alt+A to paste");
        await ForegroundRoutingAcceptance.WaitFor(() => menu.Controls[1].Focused, "Menu did not focus its first action.");
        await Task.Delay(150);
        var png = ScreenCapture.CapturePng(menu.Bounds);
        Directory.CreateDirectory("artifacts");
        File.WriteAllBytes("artifacts/capture-tray-menu.png", png);
        using (var stream = new MemoryStream(png))
        using (var bitmap = new Bitmap(stream))
        {
            bool Near(Color a, Color b) => Math.Abs(a.R - b.R) + Math.Abs(a.G - b.G) + Math.Abs(a.B - b.B) < 8;
            foreach (var corner in new[] { new Point(0, 0), new Point(bitmap.Width - 1, 0),
                new Point(0, bitmap.Height - 1), new Point(bitmap.Width - 1, bitmap.Height - 1) })
                if (!Near(bitmap.GetPixel(corner.X, corner.Y), backdrop))
                    throw new InvalidOperationException("Tray menu has opaque square corners.");
            if (!Near(bitmap.GetPixel(bitmap.Width / 2, 2), Color.FromArgb(40, 40, 40)))
                throw new InvalidOperationException("Tray menu did not render Desktop's surface color.");
            var radius = (int)Math.Round(18 * menu.DeviceDpi / 96.0);
            var antialiased = false;
            for (var y = 0; y < radius; y++)
            for (var x = 0; x < radius; x++)
            {
                var pixel = bitmap.GetPixel(x, y);
                if (!Near(pixel, backdrop) && !Near(pixel, Color.FromArgb(40, 40, 40))) antialiased = true;
            }
            if (!antialiased) throw new InvalidOperationException("Tray menu rounded edge is not antialiased.");
        }
        Console.WriteLine("Tray: rendered corners and pixels verified; checking keyboard.");
        PostMessage(menu.Controls[1].Handle, 0x0100, 0x28, 0); // Down
        await ForegroundRoutingAcceptance.WaitFor(() => menu.Controls[2].Focused, "Menu keyboard navigation did not move to Copy.");
        PostMessage(menu.Controls[2].Handle, 0x0100, 0x1B, 0); // Escape
        await ForegroundRoutingAcceptance.WaitFor(() => !menu.Visible, "Escape did not dismiss the menu.");
        Console.WriteLine("Tray: keyboard dismissal verified; checking accessible toggle.");
        menu.ShowAt(point, "2 regions ready · Alt+A to paste");
        var handle = menu.Handle;
        // Query our own native controls from MTA while the UI thread pumps;
        // UIA providers may synchronously call back into those controls.
        await Task.Run(() =>
        {
            using var automation = new UIA3Automation { ConnectionTimeout = TimeSpan.FromSeconds(1), TransactionTimeout = TimeSpan.FromSeconds(1) };
            var toggle = automation.FromHandle(handle).FindFirstDescendant(automation.ConditionFactory.ByName("Text only"));
            if (toggle is null || !toggle.Patterns.Toggle.IsSupported) throw new InvalidOperationException("Text-only preference lost native toggle accessibility.");
            toggle.Patterns.Toggle.Pattern.Toggle();
        }).WaitAsync(TimeSpan.FromSeconds(5));
        await ForegroundRoutingAcceptance.WaitFor(() => textOnly && !menu.Visible, "Accessible toggle did not update the preference and close.");
        Console.WriteLine("Tray: accessible toggle verified; checking reopen and invoke.");
        menu.ShowAt(point, "2 regions ready · Alt+A to paste");
        if (((CheckBox)menu.Controls[4]).CheckState != CheckState.Checked) throw new InvalidOperationException("Menu lost its checked preference when reopened.");
        await Task.Delay(100);
        File.WriteAllBytes("artifacts/capture-tray-menu-checked.png", ScreenCapture.CapturePng(menu.Bounds));
        await Task.Run(() =>
        {
            using var automation = new UIA3Automation { ConnectionTimeout = TimeSpan.FromSeconds(1), TransactionTimeout = TimeSpan.FromSeconds(1) };
            var copy = automation.FromHandle(handle).FindFirstDescendant(automation.ConditionFactory.ByName("Copy text"))!;
            copy.Patterns.Invoke.Pattern.Invoke();
        }).WaitAsync(TimeSpan.FromSeconds(5));
        await ForegroundRoutingAcceptance.WaitFor(() => invoked == 1 && !menu.Visible, "Accessible menu action did not invoke exactly once.");
        menu.ShowAt(point, "2 regions ready · Alt+A to paste");
        background.Activate();
        await ForegroundRoutingAcceptance.WaitFor(() => !menu.Visible, "Menu remained open after focus moved away.");
        Console.WriteLine("PASS Capture tray uses smooth 18-DIP corners, native actions/toggles, keyboard navigation, persistent checks and focus dismissal.");
    }

    [DllImport("user32.dll")] private static extern bool PostMessage(nint window, uint message, nint key, nint value);
}
