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
            MessageBox.Show("Shift+Alt+A or Alt+A is already registered. Quit Zommi or the other capture tool, then open Zommi Capture again.",
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

    internal sealed class CaptureContext : ApplicationContext
    {
        private readonly HotkeyWindow hotkey;
        private readonly NotifyIcon tray;
        private readonly ContextMenuStrip menu;
        private readonly Func<CaptureNativeHost.SelectedBatch> select;
        private readonly Action<string, string>? report;
        private CaptureClipboardBatch? lastBatch;
        private CaptureClipboardBatch? pendingBatch;
        private bool busy;
        private readonly ToolStripMenuItem textOnly;
        private readonly ToolStripMenuItem batchStatus;
        internal bool Busy => busy;
        internal bool HasPendingBatch => pendingBatch is not null;

        public CaptureContext(Func<CaptureNativeHost.SelectedBatch>? select = null, Action<string, string>? report = null)
        {
            this.select = select ?? (() => CaptureNativeHost.SelectBatch(0, CaptureTheme.Default, "Done"));
            this.report = report;
            hotkey = new HotkeyWindow(Capture, Paste);
            menu = new ContextMenuStrip();
            batchStatus = new ToolStripMenuItem("No capture ready") { Enabled = false };
            menu.Items.Add(batchStatus);
            menu.Opening += (_, _) => batchStatus.Text = pendingBatch is { } batch
                ? $"{batch.Items.Count} regions ready · Alt+A to paste" : "No capture ready";
            menu.Items.Add("Capture · Shift+Alt+A", null, (_, _) => Capture());
            menu.Items.Add("Copy last batch", null, (_, _) => CopyLast());
            menu.Items.Add("Copy text", null, (_, _) => CopyLast(forceText: true));
            textOnly = new ToolStripMenuItem("Text only") { CheckOnClick = true };
            menu.Items.Add(textOnly);
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add("Quit", null, (_, _) => { if (!busy) ExitThread(); });
            tray = new NotifyIcon
            {
                Icon = SystemIcons.Application, Text = "Zommi Capture · Shift+Alt+A capture · Alt+A paste", ContextMenuStrip = menu, Visible = true,
            };
            Notify("Ready", "Shift+Alt+A to capture. Then click the destination input and press Alt+A to paste.");
        }

        private static async Task<bool> WaitForKeys()
        {
            var wait = Stopwatch.StartNew();
            while (!CapturePasteTarget.ModifiersReleased && wait.ElapsedMilliseconds < 2000) await Task.Delay(25);
            return CapturePasteTarget.ModifiersReleased;
        }

        private async void Capture()
        {
            if (busy) return;
            busy = true;
            try
            {
                if (!await WaitForKeys()) return;
                ScreenCapture.FlushDesktop();
                var selected = select();
                if (selected.Regions.Count == 0)
                {
                    if (selected.ErrorMessage is { } error) Notify("Capture cancelled", error);
                    return;
                }
                var items = selected.Regions.Select(region =>
                {
                    using var stream = new MemoryStream(region.Png);
                    using var image = Image.FromStream(stream);
                    return new CaptureClipboardItem(region.Png, image.Width, image.Height, region.Snapshot, region.Alignment?.Reason);
                }).ToArray();
                // Capturing never chooses a destination or replaces the clipboard.
                lastBatch = pendingBatch = CaptureClipboardBatch.Create(items);
                Notify("Capture ready", $"{items.Length} regions ready. Click the input you want, then press Alt+A to paste.");
            }
            catch (Exception error) when (error is not OutOfMemoryException) { Notify("Capture unavailable", error.Message); }
            finally { busy = false; }
        }

        private async void Paste()
        {
            if (busy) return;
            if (pendingBatch is not { } batch)
            {
                Notify("No capture ready", "Press Shift+Alt+A to capture first. Copy last batch and Copy text are available for manual recovery.");
                return;
            }
            // Snapshot only this invocation's focus. Never restore or search older windows.
            var target = CapturePasteTarget.RememberWindow();
            busy = true;
            try
            {
                if (target is null || target.ProcessId == Environment.ProcessId || !await WaitForKeys() || !target.IsCurrent())
                { Notify("Paste cancelled", "Focus the destination input and press Alt+A again."); return; }
                using var automation = new FlaUI.UIA3.UIA3Automation
                {
                    ConnectionTimeout = TimeSpan.FromMilliseconds(500), TransactionTimeout = TimeSpan.FromMilliseconds(500),
                };
                var observation = await Task.Run(() => CapturePasteTarget.ObserveInput(automation, target));
                if (observation.Kind == CaptureInputKind.Protected)
                { Notify("Paste cancelled", "The selected input is protected or read-only."); return; }
                target = observation.Target;
                if (!await target.IsInputCurrentAsync()) return;
                // A second press must not replay a completed or uncertain partial batch.
                pendingBatch = null;
                var result = await CapturePasteSequence.PasteAsync(batch, target, textOnly.Checked);
                if (result.StoppedBecause is { } reason)
                    Notify("Paste stopped", reason + " Use Copy text or Copy last batch for manual recovery.");
                else if (result.UnreadImages > 0)
                    Notify("Context pasted", "Some images were not read by this input. Their context text was still pasted.");
                else Notify("Batch pasted", "Image and context steps finished. Shift+Alt+A to capture again.");
            }
            catch (Exception error) when (error is not OutOfMemoryException) { Notify("Paste unavailable", error.Message); }
            finally { busy = false; }
        }

        private void CopyLast(bool forceText = false)
        {
            if (busy || lastBatch is null) return;
            try { Clipboard.SetDataObject(ClipboardData(lastBatch, forceText || textOnly.Checked), true, 5, 80); }
            catch (ExternalException) { Notify("Clipboard busy", "Try Copy last batch again."); }
        }

        private void Notify(string title, string message)
        {
            if (report is not null) report(title, message);
            else tray.ShowBalloonTip(4000, title, message, ToolTipIcon.Info);
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing) { hotkey.Dispose(); tray.Visible = false; tray.Dispose(); menu.Dispose(); lastBatch = pendingBatch = null; }
            base.Dispose(disposing);
        }
    }

    private sealed class HotkeyWindow : NativeWindow, IDisposable
    {
        private readonly Action capture;
        private readonly Action paste;
        public HotkeyWindow(Action capture, Action paste)
        {
            this.capture = capture;
            this.paste = paste;
            CreateHandle(new CreateParams { Caption = "Zommi Capture hotkeys", Parent = new nint(-3) });
            if (!RegisterHotKey(Handle, 1, 0x4005, 0x41) || !RegisterHotKey(Handle, 2, 0x4001, 0x41))
            {
                var error = Marshal.GetLastWin32Error();
                Dispose();
                throw new System.ComponentModel.Win32Exception(error);
            }
        }
        protected override void WndProc(ref Message message)
        {
            if (message.Msg == 0x0312)
            {
                if (message.WParam == 1) capture();
                if (message.WParam == 2) paste();
            }
            base.WndProc(ref message);
        }
        public void Dispose() { UnregisterHotKey(Handle, 1); UnregisterHotKey(Handle, 2); DestroyHandle(); }
        [DllImport("user32.dll", SetLastError = true)] private static extern bool RegisterHotKey(nint window, int id, uint modifiers, uint key);
        [DllImport("user32.dll")] private static extern bool UnregisterHotKey(nint window, int id);
    }
}
