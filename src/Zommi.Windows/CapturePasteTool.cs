using System.Diagnostics;
using System.Runtime.InteropServices;
using Zommi.Capture;

namespace Zommi.Windows;

public static class CapturePasteTool
{
    [STAThread]
    public static int Run()
    {
        ApplicationConfiguration.Initialize();
        using var singleton = new Mutex(true, @"Local\Zommi.CaptureTool", out var first);
        if (!first) return 0;
        try
        {
            using var context = new CaptureContext();
            Application.Run(context);
            return 0;
        }
        catch (System.ComponentModel.Win32Exception)
        {
            MessageBox.Show("Alt+A or Alt+Shift+A is already registered. Quit Zommi or the other capture tool, then open Zommi Capture again.",
                "Zommi Capture", MessageBoxButtons.OK, MessageBoxIcon.Information);
            return 2;
        }
        finally { BrowserObservationBridge.CloseConnections(); singleton.ReleaseMutex(); }
    }

    internal static DataObject ClipboardData(CaptureClipboardBatch batch, bool textOnly)
    {
        var data = new DataObject();
        data.SetData(DataFormats.UnicodeText, false, batch.Text);
        if (!textOnly)
        {
            data.SetData(DataFormats.Html, false, batch.Html);
            data.SetData(DataFormats.Rtf, false, batch.Rtf);
            using var image = CaptureClipboardImage.Create(batch.Items);
            data.SetData("PNG", false, new MemoryStream(ScreenCapture.EncodePng(image)));
            data.SetData(DataFormats.Dib, false, new MemoryStream(CaptureClipboardImage.Dib(image)));
        }
        // Native image handlers cannot consume HTML/RTF or several bitmaps.
        // Their single image includes the whole batch, at original resolution.
        return data;
    }

    private sealed class CaptureContext : ApplicationContext
    {
        private readonly HotkeyWindow hotkey;
        private readonly NotifyIcon tray;
        private readonly ContextMenuStrip menu;
        private CaptureClipboardBatch? lastBatch;
        private bool busy;
        private readonly ToolStripMenuItem textOnly;
        private readonly ToolStripMenuItem destinationStatus;
        private CapturePasteTarget? destination;

        public CaptureContext()
        {
            hotkey = new HotkeyWindow(CaptureToDestination, PinDestination);
            menu = new ContextMenuStrip();
            destinationStatus = new ToolStripMenuItem("Destination: current input on first capture") { Enabled = false };
            menu.Items.Add(destinationStatus);
            menu.Items.Add(new ToolStripMenuItem("Set destination: Alt+Shift+A") { Enabled = false });
            menu.Items.Add("Clear destination", null, (_, _) =>
            {
                if (busy) return;
                destination = null;
                destinationStatus.Text = "Destination: current input on first capture";
            });
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add("Capture to clipboard", null, (_, _) => Capture(null));
            menu.Items.Add("Copy last batch", null, (_, _) => CopyLast());
            menu.Items.Add("Copy text", null, (_, _) => CopyLast(forceText: true));
            textOnly = new ToolStripMenuItem("Text only") { CheckOnClick = true };
            menu.Items.Add(textOnly);
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add("Quit", null, (_, _) => { if (!busy) ExitThread(); });
            tray = new NotifyIcon
            {
                Icon = SystemIcons.Application, Text = "Zommi Capture · Alt+A", ContextMenuStrip = menu, Visible = true,
            };
            Notify("Ready", "Alt+Shift+A remembers your input. Switch to the source, then Alt+A to capture and paste back.");
        }

        private void PinDestination()
        {
            if (busy) return;
            var target = CapturePasteTarget.Remember();
            if (target is null) { Notify("No destination", "Focus an input box, then press Alt+Shift+A."); return; }
            destination = target;
            destinationStatus.Text = "Destination: " + target.Description;
            Notify("Destination remembered", "Switch to the source and press Alt+A. Captures will return to " + target.Description + ".");
        }

        private void CaptureToDestination()
        {
            if (busy) return;
            destination ??= CapturePasteTarget.Remember();
            if (destination is not null) destinationStatus.Text = "Destination: " + destination.Description;
            Capture(destination);
        }

        private async void Capture(CapturePasteTarget? target)
        {
            if (busy) return;
            busy = true;
            try
            {
                var release = Stopwatch.StartNew();
                while (!CapturePasteTarget.ModifiersReleased && release.ElapsedMilliseconds < 2000) await Task.Delay(25);
                if (!CapturePasteTarget.ModifiersReleased) return;
                ScreenCapture.FlushDesktop();
                var selected = CaptureNativeHost.SelectBatch(target?.ProcessId ?? 0, CaptureTheme.Default,
                    target is null ? "Copy" : "Paste");
                if (selected.Regions.Count == 0)
                {
                    target?.Restore();
                    if (selected.ErrorMessage is { } error) Notify("Capture cancelled", error);
                    return;
                }
                var items = selected.Regions.Select(region =>
                {
                    using var stream = new MemoryStream(region.Png);
                    using var image = Image.FromStream(stream);
                    return new CaptureClipboardItem(region.Png, image.Width, image.Height, region.Snapshot, region.Alignment?.Reason);
                }).ToArray();
                var batch = CaptureClipboardBatch.Create(items);
                Clipboard.SetDataObject(ClipboardData(batch, textOnly.Checked), true, 5, 80);
                lastBatch = batch;
                var sequence = CapturePasteTarget.GetClipboardSequenceNumber();
                if (target is null) { Notify("Copied", $"{items.Length} selections copied as one batch."); return; }

                var wait = Stopwatch.StartNew();
                while (!CapturePasteTarget.ModifiersReleased && wait.ElapsedMilliseconds < 2000) await Task.Delay(25);
                if (!CapturePasteTarget.ModifiersReleased || !target.Restore())
                {
                    Notify("Copied", "The original input could not be restored. Focus your input and paste the batch manually.");
                    return;
                }
                await Task.Delay(80);
                if (!target.Paste(sequence))
                    Notify("Batch ready", "Automatic paste was not completed. Use Copy last batch, then paste into your input.");
            }
            catch (Exception error) when (error is not OutOfMemoryException)
            {
                target?.Restore();
                Notify("Capture unavailable", error.Message);
            }
            finally { busy = false; }
        }

        private void CopyLast(bool forceText = false)
        {
            if (busy || lastBatch is null) return;
            try { Clipboard.SetDataObject(ClipboardData(lastBatch, forceText || textOnly.Checked), true, 5, 80); }
            catch (ExternalException) { Notify("Clipboard busy", "Try Copy last batch again."); }
        }

        private void Notify(string title, string message) => tray.ShowBalloonTip(4000, title, message, ToolTipIcon.Info);

        protected override void Dispose(bool disposing)
        {
            if (disposing) { hotkey.Dispose(); tray.Visible = false; tray.Dispose(); menu.Dispose(); lastBatch = null; }
            base.Dispose(disposing);
        }
    }

    private sealed class HotkeyWindow : NativeWindow, IDisposable
    {
        private readonly Action capture;
        private readonly Action pin;
        public HotkeyWindow(Action capture, Action pin)
        {
            this.capture = capture;
            this.pin = pin;
            CreateHandle(new CreateParams { Caption = "Zommi Capture hotkey", Parent = new nint(-3) });
            if (!RegisterHotKey(Handle, 1, 0x4001, 0x41) || !RegisterHotKey(Handle, 2, 0x4005, 0x41))
            {
                var error = Marshal.GetLastWin32Error();
                UnregisterHotKey(Handle, 1);
                DestroyHandle();
                throw new System.ComponentModel.Win32Exception(error);
            }
        }
        protected override void WndProc(ref Message message)
        {
            if (message.Msg == 0x0312 && message.WParam == 1) capture();
            if (message.Msg == 0x0312 && message.WParam == 2) pin();
            base.WndProc(ref message);
        }
        public void Dispose() { UnregisterHotKey(Handle, 1); UnregisterHotKey(Handle, 2); DestroyHandle(); }
        [DllImport("user32.dll", SetLastError = true)] private static extern bool RegisterHotKey(nint window, int id, uint modifiers, uint key);
        [DllImport("user32.dll")] private static extern bool UnregisterHotKey(nint window, int id);
    }
}
