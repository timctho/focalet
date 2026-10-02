using System.Drawing;
using System.Windows.Forms;
using Zommi.Capture;
using Zommi.Windows;

internal static class ClipboardAcceptance
{
    // Explicit desktop acceptance: uses only synthetic editors and clipboard content.
    // Run on a disposable CI desktop, not against an agent's actual draft.
    public static int Run()
    {
        Exception? failure = null;
        var thread = new Thread(() =>
        {
            try { Exercise(); }
            catch (Exception error) { failure = error; }
        });
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start(); thread.Join();
        if (failure is not null) { Console.Error.WriteLine(failure); return 1; }
        Console.WriteLine("PASS One paste preserves all regions, plain-text fallback, rich images, draft and focus; no Enter is sent.");
        return 0;
    }

    private static void Exercise()
    {
        Application.SetHighDpiMode(HighDpiMode.PerMonitorV2);
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        using var form = new Form { Text = "Zommi paste acceptance fixture", Size = new Size(700, 700), TopMost = true };
        using var text = new TextBox { Multiline = true, Dock = DockStyle.Top, Height = 200, Text = "draft-before draft-after" };
        using var rich = new RichTextBox { Dock = DockStyle.Fill, Text = "rich-before rich-after" };
        form.Controls.Add(rich); form.Controls.Add(text);
        var enterCount = 0;
        form.KeyPreview = true;
        form.KeyDown += (_, e) => { if (e.KeyCode == Keys.Enter) enterCount++; };
        Exception? failure = null;
        uint ownedSequence = 0;
        form.Shown += async (_, _) =>
        {
            try
            {
                var items = new[] { Item("FIRST 中文 🖼", Color.Coral), Item("SECOND {B} \\ literal", Color.Blue) };
                var batch = CaptureClipboardBatch.Create(items);
                text.Focus(); text.Select("draft-before ".Length, 0);
                await Task.Delay(150);
                var target = CapturePasteTarget.Remember() ?? throw new InvalidOperationException("Fixture input was not focused.");
                using (var overlay = new Form { Text = "Synthetic capture overlay", TopMost = true })
                {
                    overlay.Show(); overlay.Activate(); await Task.Delay(100);
                    overlay.Close();
                }
                if (!target.Restore()) throw new InvalidOperationException("Original editor focus was not restored.");
                Clipboard.SetDataObject(CapturePasteTool.ClipboardData(batch, false), true);
                ownedSequence = CapturePasteTarget.GetClipboardSequenceNumber();
                if (!target.Paste(ownedSequence)) throw new InvalidOperationException("Paste was not dispatched to the fixture.");
                await Task.Delay(250);
                var expected = "draft-before " + batch.Text + "draft-after";
                if (text.Text.Replace("\r", "", StringComparison.Ordinal) != expected.Replace("\r", "", StringComparison.Ordinal))
                    throw new InvalidOperationException("Plain editor did not receive the whole batch at the original caret. " +
                        $"Expected fixture: {System.Text.Json.JsonSerializer.Serialize(expected)}; actual fixture: {System.Text.Json.JsonSerializer.Serialize(text.Text)}");

                rich.Focus(); rich.Select("rich-before ".Length, 0); await Task.Delay(100);
                var richTarget = CapturePasteTarget.Remember() ?? throw new InvalidOperationException("Rich editor was not focused.");
                if (target.Paste(ownedSequence)) throw new InvalidOperationException("Changed focus accepted a stale destination.");
                if (!richTarget.Paste(ownedSequence)) throw new InvalidOperationException("Rich paste was not dispatched.");
                await Task.Delay(250);
                if (!rich.Text.StartsWith("rich-before ", StringComparison.Ordinal) || !rich.Text.EndsWith("rich-after", StringComparison.Ordinal) ||
                    !rich.Text.Contains("FIRST 中文 🖼", StringComparison.Ordinal) || !rich.Text.Contains("SECOND {B} \\ literal", StringComparison.Ordinal) ||
                    System.Text.RegularExpressions.Regex.Matches(rich.Rtf ?? "", @"\\pict").Count != 2)
                    throw new InvalidOperationException("One rich paste did not preserve two images, their text and the existing draft.");
                if (enterCount != 0) throw new InvalidOperationException("Paste sent Enter.");
                // Native edits can update their document before the hosted desktop
                // compositor paints it. Show the start of both documents and allow
                // that frame to render before recording visible acceptance evidence.
                text.Select(0, 0); text.ScrollToCaret();
                rich.Select(0, 0); rich.ScrollToCaret();
                form.Refresh();
                await Task.Delay(1000);
                Directory.CreateDirectory("artifacts");
                File.WriteAllBytes("artifacts/capture-paste-acceptance.png", ScreenCapture.CapturePng(form.Bounds));
                Clipboard.SetText("replacement fixture");
                if (richTarget.Paste(ownedSequence)) throw new InvalidOperationException("Changed clipboard was pasted.");
                ownedSequence = CapturePasteTarget.GetClipboardSequenceNumber();
            }
            catch (Exception error) { failure = error; }
            finally { form.Close(); }
        };
        Application.Run(form);
        if (ownedSequence != 0 && CapturePasteTarget.GetClipboardSequenceNumber() == ownedSequence) Clipboard.Clear();
        if (failure is not null) throw failure;
    }

    private static CaptureClipboardItem Item(string label, Color color)
    {
        using var bitmap = new Bitmap(100, 60);
        using (var graphics = Graphics.FromImage(bitmap)) graphics.Clear(color);
        return new(ScreenCapture.EncodePng(bitmap), 100, 60, new ContextSnapshot
        {
            SnapshotId = label, SurfaceKind = "Image region", Application = "Synthetic fixture", ProcessName = "fixture",
            Confidence = "medium", RegionContext = new CapturedRegionContext
            {
                Elements = [new CapturedElement { Id = "label", Provider = "fixture", Role = "Text", Text = label,
                    Bounds = new(0, 0, 100, 60), VisibleBounds = new(0, 0, 100, 60), Relation = "inside" }],
            },
        });
    }
}
