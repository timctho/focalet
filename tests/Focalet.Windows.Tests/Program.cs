using Focalet.CaptureTool;
using System.Drawing;
using System.Text.Json;
using Focalet.Capture;
using Focalet.Windows;

if (args.Length == 2 && args[0] == "--console-receiver") return ConsoleRoutingAcceptance.Receive(args[1]);
if (args.Contains("--paste-acceptance", StringComparer.Ordinal)) return ClipboardAcceptance.Run();
if (args.Contains("--tray-menu-acceptance", StringComparer.Ordinal)) return CaptureTrayMenuAcceptance.Run();
if (args.Contains("--browser-focus-acceptance", StringComparer.Ordinal)) return ClipboardAcceptance.Run(focusOnly: true);

var tests = new (string Name, Action Run)[]
{
    ("All drawing tools change exported pixels without changing image geometry", AllToolsRender),
    ("Annotations are clipped to the selected image", ClipAnnotations),
    ("Unchanged pixels preserve source context and identify user marks", PreserveContext),
    ("Changed source drops live metadata and preserves the frozen annotated image", FrozenFallback),
    ("Unmarked images preserve their original bytes", Unmarked),
    ("Capture palette uses the requested theme and rejects malformed colors", ThemePalette),
    ("Native rich text imports every image and Unicode context in one batch", ClipboardRichImport),
    ("Each native clipboard image retains selected pixels without merging or scaling", ClipboardNativeImage),
    ("Console identity does not require an Edit role or child HWND", ConsoleIdentity),
};
var failed = 0;
foreach (var test in tests)
{
    try { test.Run(); Console.WriteLine($"PASS {test.Name}"); }
    catch (Exception error) { failed++; Console.Error.WriteLine($"FAIL {test.Name}: {error}"); }
}
return failed == 0 ? 0 : 1;

static void ConsoleIdentity()
{
    Assert(CapturePasteTarget.IsTerminalControl("CASCADIA_HOSTING_WINDOW_CLASS", "TermControl"), "Observed Windows Terminal Text/TermControl input was rejected.");
    Assert(CapturePasteTarget.IsTerminalControl("ConsoleWindowClass", ""), "Classic console input was rejected.");
}

static void ClipboardRichImport()
{
    Exception? failure = null;
    var thread = new Thread(() =>
    {
        try
        {
            var batch = CaptureClipboardBatch.Create([
                new(Image(Color.Coral), 100, 80, Captured(Image(Color.Coral)).Snapshot),
                new(Image(Color.Blue), 100, 80, Captured(Image(Color.Blue)).Snapshot! with { WindowTitle = "中文 🖼 {B} \\ second" }),
            ]);
            var data = CapturePasteTool.ClipboardData(batch, false);
            Assert((string?)data.GetData(System.Windows.Forms.DataFormats.UnicodeText, false) == batch.Text, "Rich export dropped text fallback.");
            Assert(!data.GetDataPresent(System.Windows.Forms.DataFormats.Bitmap, false), "A standalone image could replace the rest of the batch.");
            Assert(!data.GetDataPresent("PNG", false) && !data.GetDataPresent(System.Windows.Forms.DataFormats.Dib, false), "Manual batch copy must not merge the images.");
            using var editor = new System.Windows.Forms.RichTextBox { Text = "before after" };
            editor.Select(7, 0);
            editor.SelectedRtf = (string)data.GetData(System.Windows.Forms.DataFormats.Rtf, false)!;
            Assert(editor.Text.StartsWith("before ", StringComparison.Ordinal) && editor.Text.EndsWith("after", StringComparison.Ordinal), "Rich paste replaced the draft.");
            Assert(editor.Text.Contains("[A]", StringComparison.Ordinal) && editor.Text.Contains("[B]", StringComparison.Ordinal) &&
                editor.Text.Contains("中文 🖼 {B} \\ second", StringComparison.Ordinal), "Native rich text lost a region or Unicode text.");
            Assert(System.Text.RegularExpressions.Regex.Matches(editor.Rtf ?? "", @"\\pict").Count == 2, "Native rich text did not retain both images.");
            var plain = CapturePasteTool.ClipboardData(batch, true);
            Assert(plain.GetFormats(false).SequenceEqual([System.Windows.Forms.DataFormats.UnicodeText]), "Text-only mode included competing formats.");
        }
        catch (Exception error) { failure = error; }
    });
    thread.SetApartmentState(ApartmentState.STA);
    thread.Start(); thread.Join();
    if (failure is not null) throw failure;
}

static void ClipboardNativeImage()
{
    var items = new[] { new CaptureClipboardItem(Image(Color.Coral), 100, 80, null), new CaptureClipboardItem(Image(Color.Blue), 100, 80, null) };
    using var first = CaptureClipboardImage.Create(items[0]);
    using var second = CaptureClipboardImage.Create(items[1]);
    Assert(first.Size == new Size(100, 80) && second.Size == first.Size, "Individual image dimensions changed.");
    for (var y = 0; y < 80; y++)
        for (var x = 0; x < 100; x++)
        {
            Assert(first.GetPixel(x, y).ToArgb() == Color.Coral.ToArgb(), "First region pixels changed.");
            Assert(second.GetPixel(x, y).ToArgb() == Color.Blue.ToArgb(), "Second region pixels changed.");
        }
    var rejected = false;
    try { using var oversized = CaptureClipboardImage.Create(items[0] with { Width = 32768 }); }
    catch (ArgumentException) { rejected = true; }
    Assert(rejected, "Unsafe native bitmap dimensions were accepted.");
}

static void ThemePalette()
{
    using var input = JsonDocument.Parse("{\"theme\":{\"accent\":4281892264,\"surface\":4294967295,\"onAccent\":4278190080}}");
    var theme = CaptureTheme.FromParameters(input.RootElement);
    Assert(theme.Accent.ToArgb() == Color.FromArgb(56, 125, 168).ToArgb(), "Theme accent was ignored.");
    Assert(theme.Surface.ToArgb() == Color.White.ToArgb(), "Light theme surface was ignored.");
    using var invalid = JsonDocument.Parse("{\"theme\":{\"accent\":\"bad\",\"surface\":-1}}");
    Assert(CaptureTheme.FromParameters(invalid.RootElement) == CaptureTheme.Default, "Invalid palette must use defaults.");
}

static byte[] Image(Color color)
{
    using var bitmap = new Bitmap(100, 80);
    using (var g = Graphics.FromImage(bitmap)) g.Clear(color);
    return ScreenCapture.EncodePng(bitmap);
}

static ImageAnnotation Stroke(AnnotationTool tool) => new(tool, "#FF686B", 4, [new(15, 15), new(75, 55)]);
static ContentSelection Selection(byte[] png) => new(new Rectangle(-240, 30, 100, 80), 0, null, null, 0,
    png, DateTimeOffset.UtcNow.AddMinutes(-1), [Stroke(AnnotationTool.Pen)]);
static RegionSelectionResult Captured(byte[] png) => new(new Rectangle(-240, 30, 100, 80), png, new ContextSnapshot
{
    SnapshotId = "source", Application = "Fixture", ProcessName = "fixture", SurfaceKind = "Image region",
    Confidence = "medium", WindowTitle = "Actual source", RegionContext = new CapturedRegionContext
    {
        Elements = [new CapturedElement { Id = "e1", Provider = "test", Role = "Text", Text = "Original app text",
            Bounds = new(0, 0, 80, 30), VisibleBounds = new(0, 0, 80, 30), Relation = "inside" }],
    },
});
static void Assert(bool condition, string error) { if (!condition) throw new InvalidOperationException(error); }

static void AllToolsRender()
{
    var original = Image(Color.White);
    foreach (var tool in Enum.GetValues<AnnotationTool>())
    {
        var annotated = AnnotationRenderer.Apply(original, [Stroke(tool)]);
        Assert(!AnnotationRenderer.SamePixels(original, annotated), $"{tool} is missing from exported image.");
        using var stream = new System.IO.MemoryStream(annotated);
        using var bitmap = new Bitmap(stream);
        Assert(bitmap.Size == new Size(100, 80), "Image mapping changed.");
        Assert(bitmap.GetPixel(0, 0).ToArgb() == Color.White.ToArgb(), "Drawing touched unrelated pixels.");
    }
}

static void ClipAnnotations()
{
    var original = Image(Color.White);
    var annotated = AnnotationRenderer.Apply(original, [new(AnnotationTool.Pen, "#FF686B", 6, [new(-30, 10), new(140, 10)])]);
    using var stream = new System.IO.MemoryStream(annotated);
    using var bitmap = new Bitmap(stream);
    Assert(bitmap.Size == new Size(100, 80), "Clipped drawing resized the image.");
    Assert(bitmap.GetPixel(0, 10).G < 180 && bitmap.GetPixel(99, 10).G < 180, "Stroke was lost at image edges.");
}

static void PreserveContext()
{
    var original = Image(Color.White);
    var source = Captured(original);
    var result = AnnotatedCapture.Complete(Selection(original), source);
    Assert(result.Snapshot?.RegionContext == source.Snapshot!.RegionContext, "Source context was lost.");
    Assert(result.Snapshot?.ImageAnnotations?.StrokeCount == 1, "User annotation provenance missing.");
    Assert(result.Snapshot!.SnapshotId == "source", "Source identity changed.");
    Assert(!AnnotationRenderer.SamePixels(original, result.Png), "Annotation was not baked in.");
}

static void FrozenFallback()
{
    var selected = Selection(Image(Color.White));
    var result = AnnotatedCapture.Complete(selected, Captured(Image(Color.Black)));
    Assert(result.Snapshot?.RegionContext is null && result.Snapshot?.Source is null, "Stale source metadata leaked.");
    Assert(result.Snapshot?.ObservedAtUtc == selected.FrozenAtUtc, "Frozen frame was relabelled as fresh.");
    Assert(result.Alignment?.Status == "image-only" && result.Alignment.Mapping?.ScreenBounds.X == -240, "Fallback lost physical geometry.");
    Assert(result.Snapshot?.ImageAnnotations?.StrokeCount == 1, "Fallback lost user marks.");
    Assert(AnnotationRenderer.SamePixels(result.Png, AnnotationRenderer.Apply(selected.FrozenPng, selected.Annotations)), "Fallback used newer pixels.");
}

static void Unmarked()
{
    var original = Image(Color.White);
    Assert(ReferenceEquals(original, AnnotationRenderer.Apply(original, [])), "Unmarked PNG was needlessly reencoded.");
    var result = AnnotatedCapture.Complete(Selection(original) with { Annotations = [] }, Captured(original));
    Assert(result.Snapshot?.ImageAnnotations is null, "Unmarked image claims user marks.");
}
