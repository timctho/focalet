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
        // Manual copy offers a rich document and complete text fallback. Automatic
        // paste sends native images separately, never a merged contact sheet.
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
        private readonly CaptureInputTracker inputs;

        public CaptureContext()
        {
            hotkey = new HotkeyWindow(() => Capture(toDestination: true));
            inputs = new CaptureInputTracker();
            menu = new ContextMenuStrip();
            destinationStatus = new ToolStripMenuItem("Destination: last used input (automatic)") { Enabled = false };
            menu.Items.Add(destinationStatus);
            menu.Opening += (_, _) => destinationStatus.Text = "Destination: " + (inputs.Latest?.Description ?? "focus an input first");
            menu.Items.Add("Clear destination", null, (_, _) =>
            {
                if (busy) return;
                inputs.Clear();
                destinationStatus.Text = "Destination: focus an input first";
            });
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add("Capture to clipboard", null, (_, _) => Capture(toDestination: false));
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
            Notify("Ready", "Your last input is remembered automatically. Switch to the source, then Alt+A to capture and paste back.");
        }

        private async void Capture(bool toDestination)
        {
            if (busy) return;
            busy = true;
            inputs.Pause();
            try
            {
                var target = toDestination ? await inputs.PauseAsync() : null;
                var release = Stopwatch.StartNew();
                while (!CapturePasteTarget.ModifiersReleased && release.ElapsedMilliseconds < 2000) await Task.Delay(25);
                if (!CapturePasteTarget.ModifiersReleased) return;
                ScreenCapture.FlushDesktop();
                var selected = CaptureNativeHost.SelectBatch(target?.ProcessId ?? 0, CaptureTheme.Default,
                    target is null ? "Copy" : "Paste", target?.Description);
                if (selected.Regions.Count == 0)
                {
                    if (target is not null) await target.RestoreInputAsync();
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
                lastBatch = batch;
                if (target is null)
                {
                    Clipboard.SetDataObject(ClipboardData(batch, textOnly.Checked), true, 5, 80);
                    Notify("Copied", $"{items.Length} selections copied. Focus an input before the next capture for automatic paste.");
                    return;
                }

                var wait = Stopwatch.StartNew();
                while (!CapturePasteTarget.ModifiersReleased && wait.ElapsedMilliseconds < 2000) await Task.Delay(25);
                if (!CapturePasteTarget.ModifiersReleased || !await target.RestoreInputAsync())
                {
                    Notify("Batch ready", "The original input could not be restored. Use Copy text or Copy last batch from the tray.");
                    return;
                }
                await Task.Delay(80);
                var result = await CapturePasteSequence.PasteAsync(batch, target, textOnly.Checked);
                if (result.StoppedBecause is { } reason)
                    Notify("Paste stopped", reason + " The complete batch remains in the tray; already dispatched parts were not retried.");
                else if (result.UnreadImages > 0)
                    Notify("Text pasted", "The input did not read some images. Their context text was still pasted.");
            }
            catch (Exception error) when (error is not OutOfMemoryException)
            {
                Notify("Capture unavailable", error.Message);
            }
            finally { busy = false; inputs.Resume(); }
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
            if (disposing) { inputs.Dispose(); hotkey.Dispose(); tray.Visible = false; tray.Dispose(); menu.Dispose(); lastBatch = null; }
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
                UnregisterHotKey(Handle, 1);
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
