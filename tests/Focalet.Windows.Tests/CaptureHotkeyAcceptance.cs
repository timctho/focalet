using Focalet.CaptureTool;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Windows.Forms;
using Focalet.Capture;
using Focalet.Windows;

internal static class CaptureHotkeyAcceptance
{
    public static async Task RunAsync(CaptureClipboardBatch batch)
    {
        var captured = 0;
        var cancelCapture = false;
        var notices = new List<string>();
        using var context = new CapturePasteTool.CaptureContext(() =>
        {
            captured++;
            return cancelCapture ? new([]) : new(batch.Items.Select(item => new RegionSelectionResult(
                new Rectangle(0, 0, item.Width, item.Height), item.Png, item.Snapshot)).ToArray());
        }, (title, _) => notices.Add(title), includeOwnProcess: true);
        using var source = new Form { Text = "Explicit capture source", Size = new Size(400, 200), TopMost = true };
        using var previous = new RichTextBox { Text = "old destination stays unchanged", Dock = DockStyle.Fill };
        source.Controls.Add(previous);
        source.Show(); source.Activate(); previous.Focus();
        Clipboard.SetText("clipboard before capture");
        var sequence = CapturePasteTarget.GetClipboardSequenceNumber();
        SendHotkey(capture: false);
        await ForegroundRoutingAcceptance.WaitFor(() => notices.Contains("No capture ready"), "Alt+A without a batch did not report its state.");
        if (captured != 0) throw new InvalidOperationException("Alt+A captured instead of pasting.");
        SendHotkey(capture: true);
        await ForegroundRoutingAcceptance.WaitFor(() => context.HasBatch && !context.Busy, "Shift+Alt+A did not prepare the capture.");
        if (captured != 1 || sequence != CapturePasteTarget.GetClipboardSequenceNumber())
            throw new InvalidOperationException("Capture pasted or replaced the clipboard before choosing an input.");
        cancelCapture = true;
        SendHotkey(capture: true);
        await ForegroundRoutingAcceptance.WaitFor(() => captured == 2 && !context.Busy, "Second capture did not finish.");
        if (!context.HasBatch || sequence != CapturePasteTarget.GetClipboardSequenceNumber())
            throw new InvalidOperationException("Cancelling capture discarded the pending batch or clipboard.");
        using var destination = new Form { Text = "Explicit paste destination", Size = new Size(700, 600), TopMost = true };
        using var rich = new RichTextBox { Text = "before after", Dock = DockStyle.Fill };
        destination.Controls.Add(rich);
        destination.Show(); destination.Activate(); rich.Focus(); rich.Select(7, 0);
        var enters = 0;
        destination.KeyPreview = true;
        destination.KeyDown += (_, args) => { if (args.KeyCode == Keys.Enter) enters++; };
        notices.Clear();
        SendHotkey(capture: false);
        await ForegroundRoutingAcceptance.WaitFor(() => context.Busy, "Paste did not start.");
        SendHotkey(capture: false); // A press while busy must not queue another batch.
        await ForegroundRoutingAcceptance.WaitFor(() => Count(rich.Rtf!, @"\pict") >= 1, "The first image was not dispatched.");
        // Real shortcut presses hold Alt across multiple paste-loop ticks.
        // Ignore the busy invocation and wait for release without duplicating
        // or abandoning the already accepted image.
        SendHotkey(capture: false, releaseAlt: false);
        try { await Task.Delay(250); }
        finally { SendInput(1, [Key(0x12, true)], Marshal.SizeOf<Input>()); }
        await ForegroundRoutingAcceptance.WaitFor(() => Count(rich.Rtf!, @"\pict") == 2 && !context.Busy, "Alt+A did not paste the pending batch.", 20000);
        if (notices.Count != 0) throw new InvalidOperationException("Successful paste displayed a notification.");
        // RichEdit represents each pasted image as a space in Text and strips
        // a clipboard part's final paragraph break. Verify complete context
        // sections and original draft around those native object boundaries.
        var actual = rich.Text.Replace("\r", "");
        var contextStart = "before ".Length;
        var completeContext = actual.StartsWith("before ", StringComparison.Ordinal) && actual.EndsWith("after", StringComparison.Ordinal);
        foreach (var part in batch.TextParts)
        {
            var content = part.Replace("\r", "").TrimEnd('\n');
            var index = actual.IndexOf(content, contextStart, StringComparison.Ordinal);
            if (index < 0 || !string.IsNullOrWhiteSpace(actual[contextStart..index])) { completeContext = false; break; }
            contextStart = index + content.Length;
        }
        completeContext &= contextStart <= actual.Length - "after".Length &&
            string.IsNullOrWhiteSpace(actual[contextStart..Math.Max(contextStart, actual.Length - "after".Length)]);
        if (!completeContext || enters != 0 ||
            previous.Text != "old destination stays unchanged" || !context.HasBatch)
            throw new InvalidOperationException("Explicit paste used the earlier input, lost context/caret, or sent Enter: " +
                System.Text.Json.JsonSerializer.Serialize(new { actual, enters, previous = previous.Text, context.HasBatch }));
        var rtf = rich.Rtf!;
        var a = rtf.IndexOf(@"\pict", StringComparison.Ordinal);
        var aText = rtf.IndexOf("[A]", StringComparison.Ordinal);
        var b = rtf.IndexOf(@"\pict", a + 5, StringComparison.Ordinal);
        var bText = rtf.IndexOf("[B]", StringComparison.Ordinal);
        if (!(a >= 0 && a < aText && aText < b && b < bText) || Count(rtf, @"\pict") != 2)
            throw new InvalidOperationException("Hotkey paste lost image/context order or queued a busy invocation.");
        notices.Clear();
        SendHotkey(capture: false);
        await ForegroundRoutingAcceptance.WaitFor(() => Count(rich.Rtf!, @"\pict") == 4 && !context.Busy, "A deliberate Alt+A did not paste the same batch again.", 20000);
        if (notices.Count != 0) throw new InvalidOperationException("Repeated paste displayed a notification.");
        if (!context.HasBatch || Count(rich.Rtf!, @"\pict") != 4 || Count(rich.Text, "[A]") != 2 || Count(rich.Text, "[B]") != 2)
            throw new InvalidOperationException("Repeating paste did not insert exactly one more batch.");
        rtf = rich.Rtf!;
        source.Activate(); previous.Focus(); previous.Select(4, 0);
        notices.Clear();
        SendHotkey(capture: false);
        await ForegroundRoutingAcceptance.WaitFor(() => Count(previous.Rtf!, @"\pict") == 2 && !context.Busy, "Repeating paste at a different input did not finish.", 20000);
        if (notices.Count != 0) throw new InvalidOperationException("Paste at a different input displayed a notification.");
        if (rich.Rtf != rtf || Count(previous.Rtf!, @"\pict") != 2 ||
            !previous.Text.StartsWith("old ", StringComparison.Ordinal) || !previous.Text.EndsWith("destination stays unchanged", StringComparison.Ordinal))
            throw new InvalidOperationException("Repeated paste reused the previous destination or changed the new caret.");
        foreach (var part in batch.TextParts)
            if (!previous.Text.Replace("\r", "").Contains(part.Replace("\r", "").TrimEnd('\n'), StringComparison.Ordinal))
                throw new InvalidOperationException("Repeated paste lost complete context at the new input.");

        // An interrupted attempt retains the batch, but never resumes on its own.
        notices.Clear();
        var picturesBeforeInterruption = Count(previous.Rtf!, @"\pict");
        using var replace = new System.Windows.Forms.Timer { Interval = 25 };
        replace.Tick += (_, _) =>
        {
            if (Count(previous.Rtf!, @"\pict") == picturesBeforeInterruption) return;
            replace.Stop(); Clipboard.SetText("interrupted hotkey fixture");
        };
        replace.Start();
        SendHotkey(capture: false);
        await ForegroundRoutingAcceptance.WaitFor(() => notices.Contains("Paste stopped") && !context.Busy, "Interrupted hotkey paste did not stop.");
        var interrupted = previous.Rtf;
        await Task.Delay(700);
        if (!context.HasBatch || previous.Rtf != interrupted || Clipboard.GetText() != "interrupted hotkey fixture")
            throw new InvalidOperationException("Interrupted paste resumed automatically or discarded the batch.");
        if (enters != 0 || captured != 2) throw new InvalidOperationException("Repeated paste sent Enter or captured again.");
        Console.WriteLine("PASS Shift+Alt+A captures without clipboard changes; deliberate Alt+A repeats silently at the current input; busy presses do not queue; cancellation and interruption retain the batch without automatic retries.");
    }

    private static int Count(string value, string part) => value.Split(part, StringSplitOptions.None).Length - 1;

    private static void SendHotkey(bool capture, bool releaseAlt = true)
    {
        var keys = new List<Input> { Key(0x12) };
        if (capture) keys.Add(Key(0x10));
        keys.Add(Key(0x41)); keys.Add(Key(0x41, true));
        if (capture) keys.Add(Key(0x10, true));
        if (releaseAlt) keys.Add(Key(0x12, true));
        if (SendInput((uint)keys.Count, keys.ToArray(), Marshal.SizeOf<Input>()) != keys.Count)
            throw new InvalidOperationException("Could not dispatch the fixture hotkey.");
    }
    private static Input Key(ushort key, bool up = false) => new() { Type = 1, Data = new() { Keyboard = new() { Key = key, Flags = up ? 2u : 0u } } };
    [StructLayout(LayoutKind.Sequential)] private struct Input { public uint Type; public InputData Data; }
    [StructLayout(LayoutKind.Explicit)] private struct InputData
    {
        [FieldOffset(0)] public KeyboardInput Keyboard;
        [FieldOffset(0)] public MouseInput Mouse;
    }
    [StructLayout(LayoutKind.Sequential)] private struct KeyboardInput { public ushort Key, Scan; public uint Flags, Time; public nuint Extra; }
    [StructLayout(LayoutKind.Sequential)] private struct MouseInput { public int X, Y; public uint Data, Flags, Time; public nuint Extra; }
    [DllImport("user32.dll")] private static extern uint SendInput(uint count, Input[] input, int size);
}
