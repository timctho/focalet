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
            MessageBox.Show("Alt+A is already registered. Quit Zommi or the other capture tool, then open Zommi Capture again.",
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
        }
        // A separate Bitmap/FileDrop format can win over text and silently lose
        // the other regions. Images belong inside the same rich document.
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

        public CaptureContext()
        {
            hotkey = new HotkeyWindow(() => Capture(CapturePasteTarget.Remember()));
            menu = new ContextMenuStrip();
            menu.Items.Add("Capture to clipboard", null, (_, _) => Capture(null));
            menu.Items.Add("Copy last batch", null, (_, _) => CopyLast());
            textOnly = new ToolStripMenuItem("Text only") { CheckOnClick = true };
            menu.Items.Add(textOnly);
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add("Quit", null, (_, _) => { if (!busy) ExitThread(); });
            tray = new NotifyIcon
            {
                Icon = SystemIcons.Application, Text = "Zommi Capture · Alt+A", ContextMenuStrip = menu, Visible = true,
            };
            Notify("Ready", "Focus an input box, then press Alt+A. Select several regions and choose Paste once.");
        }

        private async void Capture(CapturePasteTarget? target)
        {
            if (busy) return;
            busy = true;
            try
            {
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

        private void CopyLast()
        {
            if (busy || lastBatch is null) return;
            try { Clipboard.SetDataObject(ClipboardData(lastBatch, textOnly.Checked), true, 5, 80); }
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
        public HotkeyWindow(Action capture)
        {
            this.capture = capture;
            CreateHandle(new CreateParams { Caption = "Zommi Capture hotkey", Parent = new nint(-3) });
            if (!RegisterHotKey(Handle, 1, 0x4001, 0x41))
            {
                var error = Marshal.GetLastWin32Error();
                DestroyHandle();
                throw new System.ComponentModel.Win32Exception(error);
            }
        }
        protected override void WndProc(ref Message message)
        {
            if (message.Msg == 0x0312 && message.WParam == 1) capture();
            base.WndProc(ref message);
        }
        public void Dispose() { UnregisterHotKey(Handle, 1); DestroyHandle(); }
        [DllImport("user32.dll", SetLastError = true)] private static extern bool RegisterHotKey(nint window, int id, uint modifiers, uint key);
        [DllImport("user32.dll")] private static extern bool UnregisterHotKey(nint window, int id);
    }
}
