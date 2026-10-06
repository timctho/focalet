using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using Focalet.Capture;

using Focalet.Windows;

namespace Focalet.CaptureTool;

internal sealed record CapturePasteResult(int StepsSent, int UnreadImages, string? StoppedBecause = null);

/// <summary>Separate image and text pastes so a receiver never has to choose between them.</summary>
internal static class CapturePasteSequence
{
    public static async Task<CapturePasteResult> PasteAsync(CaptureClipboardBatch batch, CapturePasteTarget target, bool textOnly, bool slowerImages = false)
    {
        using var clipboard = new PasteClipboard();
        using var activity = new CapturePasteActivity();
        var sent = 0;
        var unreadImages = 0;
        for (var index = 0; index < batch.Items.Count; index++)
        {
            foreach (var image in textOnly ? new[] { false } : new[] { true, false })
            {
                if (await WaitForInputAsync(target, clipboard, activity, sent > 0) is { } notReady)
                    return new(sent, unreadImages, notReady);
                if (image) clipboard.SetImage(batch.Items[index]);
                else clipboard.SetText(batch.TextParts[index]);
                clipboard.Arm();
                if (await WaitForInputAsync(target, clipboard, activity, true) is { } interrupted)
                    return new(sent, unreadImages, interrupted);
                if (!target.Paste(CapturePasteTarget.GetClipboardSequenceNumber(), clipboard.Handle))
                    return new(sent, unreadImages, "Paste could not be dispatched. It will not be retried.");
                sent++;

                // A DOM preview/thumbnail can read first; Electron may then read
                // the image again through main-process IPC to save/attach it.
                // Use a short settling window by default; slower receivers can
                // opt into the longer preview/save compatibility window.
                // Neither a read nor a timeout is an attachment completion receipt.
                var minimumWait = image ? (slowerImages ? 3000 : 500) : 150;
                var settleAfterRead = image ? (slowerImages ? 600 : 200) : 75;
                var wait = Stopwatch.StartNew();
                Stopwatch? heldKeys = null;
                while (wait.ElapsedMilliseconds < (image ? 5000 : 3000))
                {
                    await Task.Delay(50);
                    if (activity.Changed) return new(sent, unreadImages, "Keyboard or mouse input interrupted paste.");
                    if (!clipboard.OwnsClipboard)
                        return new(sent, unreadImages, "Another application replaced the clipboard.");
                    if (!target.IsCurrent()) return new(sent, unreadImages, "The destination window changed during paste.");
                    if (!CapturePasteTarget.ModifiersReleased)
                    {
                        heldKeys ??= Stopwatch.StartNew();
                        if (heldKeys.ElapsedMilliseconds >= 1500)
                            return new(sent, unreadImages, "The shortcut keys were not released.");
                        continue;
                    }
                    heldKeys = null;
                    if (clipboard.Read && wait.ElapsedMilliseconds >= minimumWait &&
                        clipboard.MillisecondsSinceRead >= settleAfterRead) break;
                }
                if (clipboard.Failure is { } failure) return new(sent, unreadImages, failure);
                if (!clipboard.Read)
                {
                    if (image) unreadImages++; // Plain editors ignore images; still insert their context.
                    else return new(sent, unreadImages, "The input did not read the text. Remaining selections were not pasted.");
                }
            }
        }
        return new(sent, unreadImages);
    }

    private static async Task<string?> WaitForInputAsync(CapturePasteTarget target, PasteClipboard clipboard, CapturePasteActivity activity, bool checkClipboard)
    {
        var wait = Stopwatch.StartNew();
        while (true)
        {
            if (activity.Changed) return "Keyboard or mouse input interrupted paste.";
            if (!target.IsCurrent()) return "The destination window changed during paste.";
            if (checkClipboard && !clipboard.OwnsClipboard) return "Another application replaced the clipboard.";
            var state = await target.InputStateAsync();
            if (activity.Changed) return "Keyboard or mouse input interrupted paste.";
            if (!target.IsCurrent()) return "The destination window changed during paste.";
            if (checkClipboard && !clipboard.OwnsClipboard) return "Another application replaced the clipboard.";
            if (state == CaptureInputState.Changed) return "The focused input changed during paste.";
            if (state == CaptureInputState.Current && CapturePasteTarget.ModifiersReleased) return null;
            if (wait.ElapsedMilliseconds >= 1500)
                return state == CaptureInputState.Settling ? "The selected input did not regain focus." : "The shortcut keys were not released.";
            await Task.Delay(25);
        }
    }

    // Win32 delayed rendering also works with apps using Electron's native
    // clipboard API rather than the browser paste event's DataTransfer object.
    private sealed class PasteClipboard : NativeWindow, IDisposable
    {
        private readonly uint png = RegisterClipboardFormat("PNG");
        private readonly uint rtf = RegisterClipboardFormat("Rich Text Format");
        private Dictionary<uint, byte[]> formats = [];
        private readonly HashSet<uint> rendered = [];
        private bool armed;
        private long lastRead;
        public bool Read => lastRead != 0;
        public long MillisecondsSinceRead => Read ? (long)Stopwatch.GetElapsedTime(lastRead).TotalMilliseconds : 0;
        public string? Failure { get; private set; }
        public bool OwnsClipboard => GetClipboardOwner() == Handle;

        public PasteClipboard() => CreateHandle(new CreateParams { Caption = "Focalet paste clipboard", Parent = new nint(-3) });
        public void Arm() => armed = true;
        public void SetText(string text) => Set(new() { [13] = Encoding.Unicode.GetBytes(text + '\0') });
        public void SetImage(CaptureClipboardItem item)
        {
            using var bitmap = CaptureClipboardImage.Create(item);
            var picture = @"{\rtf1\ansi{\pict\pngblip\picw" + item.Width + @"\pich" + item.Height +
                @"\picwgoal" + (long)item.Width * 15 + @"\pichgoal" + (long)item.Height * 15 + " " + Convert.ToHexString(item.Png) + "}}";
            Set(new() { [png] = item.Png, [8] = CaptureClipboardImage.Dib(bitmap), [rtf] = Encoding.ASCII.GetBytes(picture + '\0') });
        }

        private void Set(Dictionary<uint, byte[]> value)
        {
            if (!OpenClipboard(Handle)) throw new ExternalException("The clipboard is busy. The remaining batch has not been pasted.");
            try
            {
                if (!EmptyClipboard()) throw new ExternalException("Could not prepare the clipboard.");
                formats = value;
                rendered.Clear();
                armed = false;
                lastRead = 0;
                Failure = null;
                foreach (var format in formats.Keys) SetClipboardData(format, 0);
            }
            finally { CloseClipboard(); }
        }

        private void Render(uint format)
        {
            if (!formats.TryGetValue(format, out var bytes)) return;
            var memory = GlobalAlloc(0x0002, (nuint)bytes.Length);
            if (memory == 0) { Failure = "Could not allocate clipboard data."; return; }
            var pointer = GlobalLock(memory);
            if (pointer == 0) { GlobalFree(memory); Failure = "Could not lock clipboard data."; return; }
            try { Marshal.Copy(bytes, 0, pointer, bytes.Length); }
            finally { GlobalUnlock(memory); }
            if (SetClipboardData(format, memory) == 0) { GlobalFree(memory); Failure = "Could not render clipboard data."; return; }
            rendered.Add(format);
            if (armed) lastRead = Stopwatch.GetTimestamp();
        }

        protected override void WndProc(ref Message message)
        {
            if (message.Msg == 0x0305) { Render((uint)message.WParam); return; } // WM_RENDERFORMAT: reader already opened clipboard
            if (message.Msg == 0x0306) { Preserve(); return; }
            base.WndProc(ref message);
        }

        private void Preserve()
        {
            if (!OwnsClipboard || !OpenClipboard(Handle)) return;
            try
            {
                if (OwnsClipboard)
                    foreach (var format in formats.Keys.Where(format => !rendered.Contains(format))) Render(format);
            }
            finally { CloseClipboard(); }
        }

        public void Dispose() { Preserve(); DestroyHandle(); }
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern uint RegisterClipboardFormat(string format);
        [DllImport("user32.dll")] private static extern bool OpenClipboard(nint window);
        [DllImport("user32.dll")] private static extern bool CloseClipboard();
        [DllImport("user32.dll")] private static extern bool EmptyClipboard();
        [DllImport("user32.dll")] private static extern nint GetClipboardOwner();
        [DllImport("user32.dll")] private static extern nint SetClipboardData(uint format, nint data);
        [DllImport("kernel32.dll")] private static extern nint GlobalAlloc(uint flags, nuint size);
        [DllImport("kernel32.dll")] private static extern nint GlobalLock(nint memory);
        [DllImport("kernel32.dll")] private static extern bool GlobalUnlock(nint memory);
        [DllImport("kernel32.dll")] private static extern nint GlobalFree(nint memory);
    }
}
