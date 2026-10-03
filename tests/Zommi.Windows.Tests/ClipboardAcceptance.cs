using System.Drawing;
using System.Windows.Forms;
using Zommi.Capture;
using Zommi.Windows;

internal static class ClipboardAcceptance
{
    // Explicit desktop acceptance: uses only synthetic editors and clipboard content.
    // Run on a disposable CI desktop, not against an agent's actual draft.
    public static int Run(bool focusOnly = false)
    {
        var previousTarget = focusOnly ? CapturePasteTarget.Remember() : null;
        var previousPointer = Cursor.Position;
        Exception? failure = null;
        var thread = new Thread(() =>
        {
            try { Exercise(focusOnly); }
            catch (Exception error) { failure = error; }
        });
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start(); thread.Join();
        if (focusOnly) { previousTarget?.Restore(); Cursor.Position = previousPointer; }
        if (failure is not null) { Console.Error.WriteLine(failure); return 1; }
        if (!focusOnly) Console.WriteLine("PASS Sequential paste preserves separate images, context, explicit input and draft; interruption stops and no Enter is sent.");
        return 0;
    }

    private static void Exercise(bool focusOnly)
    {
        Application.SetHighDpiMode(HighDpiMode.PerMonitorV2);
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        using var form = new Form { Text = "Zommi paste acceptance fixture", Size = new Size(1000, 900), TopMost = true };
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
                if (focusOnly)
                {
                    form.Hide();
                    await ChromiumClipboardAcceptance.RunAsync(batch, focusOnly: true);
                    return;
                }
                text.Focus(); text.Select("draft-before ".Length, 0);
                var target = CapturePasteTarget.RememberWindow() ?? throw new InvalidOperationException("Text fixture was not focused.");
                var result = await CapturePasteSequence.PasteAsync(batch, target, false);
                ownedSequence = CapturePasteTarget.GetClipboardSequenceNumber();
                if (result.StoppedBecause is not null || result.StepsSent != 4)
                    throw new InvalidOperationException("Plain editor sequence failed: " + result);
                var expected = "draft-before " + string.Concat(batch.TextParts) + "draft-after";
                if (text.Text.Replace("\r", "", StringComparison.Ordinal) != expected.Replace("\r", "", StringComparison.Ordinal))
                    throw new InvalidOperationException("Plain editor lost context or the original caret: " + System.Text.Json.JsonSerializer.Serialize(text.Text));

                rich.Focus(); rich.Select("rich-before ".Length, 0); await Task.Delay(100);
                var richTarget = CapturePasteTarget.Remember() ?? throw new InvalidOperationException("Rich editor was not focused.");
                if (target.Paste(ownedSequence)) throw new InvalidOperationException("Changed focus accepted a stale destination.");
                result = await CapturePasteSequence.PasteAsync(batch, richTarget, false);
                if (result.StoppedBecause is not null || result.StepsSent != 4)
                    throw new InvalidOperationException("Rich editor sequence failed: " + result);
                if (!rich.Text.StartsWith("rich-before ", StringComparison.Ordinal) || !rich.Text.EndsWith("rich-after", StringComparison.Ordinal) ||
                    !rich.Text.Contains("FIRST 中文 🖼", StringComparison.Ordinal) || !rich.Text.Contains("SECOND {B} \\ literal", StringComparison.Ordinal) ||
                    System.Text.RegularExpressions.Regex.Matches(rich.Rtf ?? "", @"\\pict").Count != 2)
                    throw new InvalidOperationException("Sequential rich paste did not preserve two images, their text and the draft.");
                var rtf = rich.Rtf!;
                var firstPicture = rtf.IndexOf(@"\pict", StringComparison.Ordinal);
                var firstText = rtf.IndexOf("[A]", StringComparison.Ordinal);
                var secondPicture = rtf.IndexOf(@"\pict", firstPicture + 5, StringComparison.Ordinal);
                var secondText = rtf.IndexOf("[B]", StringComparison.Ordinal);
                if (!(firstPicture < firstText && firstText < secondPicture && secondPicture < secondText))
                    throw new InvalidOperationException("Rich editor changed image/text ordering.");
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
                form.TopMost = false;
                await ChromiumClipboardAcceptance.RunAsync(batch);
                await ElectronClipboardAcceptance.RunAsync(batch);
                await CaptureHotkeyAcceptance.RunAsync(batch);
                if (!richTarget.Restore()) throw new InvalidOperationException("Rich editor was not restored after browser acceptance.");
                using var interrupt = new System.Windows.Forms.Timer { Interval = 150 };
                interrupt.Tick += (_, _) => { interrupt.Stop(); text.Focus(); };
                interrupt.Start();
                result = await CapturePasteSequence.PasteAsync(batch, richTarget, false);
                if (result.StoppedBecause is null || result.StepsSent != 1)
                    throw new InvalidOperationException("Sequence continued after focus changed: " + result);
                using var replace = new System.Windows.Forms.Timer { Interval = 150 };
                replace.Tick += (_, _) => { replace.Stop(); Clipboard.SetText("replacement fixture"); };
                replace.Start();
                var textTarget = CapturePasteTarget.Remember() ?? throw new InvalidOperationException("Text fixture lost focus.");
                result = await CapturePasteSequence.PasteAsync(batch, textTarget, false);
                if (result.StoppedBecause is null || result.StepsSent != 1 || Clipboard.GetText() != "replacement fixture")
                    throw new InvalidOperationException("Sequence overwrote an intervening clipboard change: " + result);
                ownedSequence = CapturePasteTarget.GetClipboardSequenceNumber();
            }
            catch (Exception error) { failure = error; }
            finally { form.Close(); }
        };
        Application.Run(form);
        if (ownedSequence != 0 && CapturePasteTarget.GetClipboardSequenceNumber() == ownedSequence) Clipboard.Clear();
        if (failure is not null) System.Runtime.ExceptionServices.ExceptionDispatchInfo.Capture(failure).Throw();
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
