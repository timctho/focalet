using System.Diagnostics;
using System.Drawing;
using System.Windows.Forms;
using Zommi.Capture;
using Zommi.Windows;

internal static class ForegroundRoutingAcceptance
{
    // Called with an earlier, real Chromium input focused. That browser must
    // not remain the destination after visiting a custom chat or console.
    public static async Task RunAsync(CaptureClipboardBatch batch, Func<Task> focusBrowser, Func<Task> focusBrowserSource)
    {
        await focusBrowser();
        using var tracker = new CaptureInputTracker(includeOwnProcess: true);
        var browser = await tracker.PauseAsync() ?? throw new InvalidOperationException("Could not bookmark the earlier browser.");
        tracker.Resume();
        using var chat = new Form { Text = "Synthetic custom chat", Size = new Size(650, 450), TopMost = true };
        using var input = new OpaqueInput { Dock = DockStyle.Fill };
        chat.Controls.Add(input);
        chat.Show(); chat.Activate(); input.Focus();
        await WaitFor(() => input.Focused, "Custom chat did not acquire native focus.");
        var direct = await tracker.PauseAsync();
        if (direct?.Window != chat.Handle || direct.Focus != input.Handle)
            throw new InvalidOperationException("Direct capture in a custom input selected the earlier browser.");
        tracker.Resume();
        await Task.Delay(100);
        await focusBrowserSource();
        var target = await tracker.PauseAsync();
        if (target?.Window != chat.Handle || target.Focus != input.Handle)
            throw new InvalidOperationException("A non-Edit custom chat was forgotten after switching to the source.");
        if (!await target.RestoreInputAsync()) throw new InvalidOperationException("Custom chat focus could not be restored.");
        var result = await CapturePasteSequence.PasteAsync(batch, target, textOnly: true);
        if (result.StoppedBecause is not null || input.Draft != "chat-before " + string.Concat(batch.TextParts) + "chat-after" || input.EnterCount != 0)
            throw new InvalidOperationException("Custom chat paste changed its draft/caret or sent Enter: " + result);
        chat.Close();
        await focusBrowser();
        tracker.Resume();
        await Task.Delay(200);
        await ConsoleRoutingAcceptance.RunAsync(tracker, focusBrowserSource);
        Console.WriteLine("PASS Foreground routing returns to custom non-Edit chat and the real Windows console, never the earlier browser.");
    }

    internal static async Task WaitFor(Func<bool> predicate, string failure, int milliseconds = 5000)
    {
        var wait = Stopwatch.StartNew();
        while (!predicate())
        {
            if (wait.ElapsedMilliseconds > milliseconds) throw new InvalidOperationException(failure);
            await Task.Delay(50);
        }
    }

    // A native keyboard input with no UIA Edit, ValuePattern or text selection
    // provider, like custom chat surfaces. Only the synthetic fixture reads text.
    private sealed class OpaqueInput : Control
    {
        public string Draft { get; private set; } = "chat-before chat-after";
        private int caret = "chat-before ".Length;
        public int EnterCount { get; private set; }
        public OpaqueInput()
        {
            SetStyle(ControlStyles.Selectable, true);
            TabStop = true;
            AccessibleRole = AccessibleRole.Grouping;
            AccessibleName = "Synthetic custom keyboard input";
        }
        protected override bool ProcessCmdKey(ref Message message, Keys keys)
        {
            if (keys == (Keys.Control | Keys.V))
            {
                var text = Clipboard.GetText();
                Draft = Draft.Insert(caret, text);
                caret += text.Length;
                Invalidate();
                return true;
            }
            if (keys == Keys.Enter) EnterCount++;
            return base.ProcessCmdKey(ref message, keys);
        }
        protected override void OnPaint(PaintEventArgs e)
        {
            base.OnPaint(e);
            TextRenderer.DrawText(e.Graphics, Draft, Font, ClientRectangle, ForeColor, TextFormatFlags.WordBreak);
        }
    }
}
