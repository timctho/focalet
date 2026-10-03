using System.Drawing;
using System.Runtime.InteropServices;
using System.Windows.Forms;
using Zommi.Capture;
using Zommi.Windows;

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
        using var previous = new TextBox { Text = "old destination stays unchanged", Dock = DockStyle.Fill };
        source.Controls.Add(previous);
        source.Show(); source.Activate(); previous.Focus();
        Clipboard.SetText("clipboard before capture");
        var sequence = CapturePasteTarget.GetClipboardSequenceNumber();
        SendHotkey(capture: false);
        await ForegroundRoutingAcceptance.WaitFor(() => notices.Contains("No capture ready"), "Alt+A without a batch did not report its state.");
        if (captured != 0) throw new InvalidOperationException("Alt+A captured instead of pasting.");
        SendHotkey(capture: true);
        await ForegroundRoutingAcceptance.WaitFor(() => context.HasPendingBatch && !context.Busy, "Shift+Alt+A did not prepare the capture.");
        if (captured != 1 || sequence != CapturePasteTarget.GetClipboardSequenceNumber())
            throw new InvalidOperationException("Capture pasted or replaced the clipboard before choosing an input.");
        cancelCapture = true;
        SendHotkey(capture: true);
        await ForegroundRoutingAcceptance.WaitFor(() => captured == 2 && !context.Busy, "Second capture did not finish.");
        if (!context.HasPendingBatch || sequence != CapturePasteTarget.GetClipboardSequenceNumber())
            throw new InvalidOperationException("Cancelling capture discarded the pending batch or clipboard.");
        using var destination = new Form { Text = "Explicit paste destination", Size = new Size(700, 600), TopMost = true };
        using var rich = new RichTextBox { Text = "before after", Dock = DockStyle.Fill };
        destination.Controls.Add(rich);
        destination.Show(); destination.Activate(); rich.Focus(); rich.Select(7, 0);
        var enters = 0;
        destination.KeyPreview = true;
        destination.KeyDown += (_, args) => { if (args.KeyCode == Keys.Enter) enters++; };
        SendHotkey(capture: false);
        await ForegroundRoutingAcceptance.WaitFor(() => notices.Contains("Batch pasted") && !context.Busy, "Alt+A did not paste the pending batch.", 20000);
        var expected = "before " + string.Concat(batch.TextParts) + "after";
        if (rich.Text.Replace("\r", "").Replace("\ufffc", "") != expected.Replace("\r", "") || enters != 0 ||
            previous.Text != "old destination stays unchanged" || context.HasPendingBatch)
            throw new InvalidOperationException("Explicit paste used the earlier input, lost context/caret, or sent Enter: " +
                System.Text.Json.JsonSerializer.Serialize(new { actual = rich.Text, expected, enters, previous = previous.Text, context.HasPendingBatch }));
        var rtf = rich.Rtf!;
        var a = rtf.IndexOf(@"\pict", StringComparison.Ordinal);
        var aText = rtf.IndexOf("[A]", StringComparison.Ordinal);
        var b = rtf.IndexOf(@"\pict", a + 5, StringComparison.Ordinal);
        var bText = rtf.IndexOf("[B]", StringComparison.Ordinal);
        if (!(a >= 0 && a < aText && aText < b && b < bText)) throw new InvalidOperationException("Hotkey paste lost image/context order.");
        notices.Clear();
        SendHotkey(capture: false);
        await ForegroundRoutingAcceptance.WaitFor(() => notices.Contains("No capture ready"), "A repeated Alt+A replayed a finished batch.");
        if (rich.Rtf != rtf) throw new InvalidOperationException("A completed batch was replayed.");
        Console.WriteLine("PASS Shift+Alt+A captures without clipboard changes; Alt+A pastes ordered images/context at the current input once; cancellation retains the batch.");
    }

    private static void SendHotkey(bool capture)
    {
        var keys = new List<Input> { Key(0x12) };
        if (capture) keys.Add(Key(0x10));
        keys.Add(Key(0x41)); keys.Add(Key(0x41, true));
        if (capture) keys.Add(Key(0x10, true));
        keys.Add(Key(0x12, true));
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
