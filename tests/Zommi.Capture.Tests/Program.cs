using Zommi.Capture;
using System.Text;
using System.Text.RegularExpressions;

var tests = new (string Name, Action Body)[]
{
    ("Browser discovery keeps Edge and Chrome profiles separate", BrowserProfiles),
    ("Selection stays primary and sanitized", SelectionStaysPrimaryAndSanitized),
    ("Internal capture metadata stays hidden", InternalMetadataStaysHidden),
    ("Accessibility preview stays compact", AccessibilityPreviewStaysCompact),
    ("Visible text stays bounded", VisibleTextStaysBounded),
    ("Browser enrichment preserves native object selections", BrowserEnrichmentPreservesObjectSelections),
    ("DOM text remains exact and explicit picks discard ambient selection", DomSelectionPriority),
    ("Image links remain readable in the context preview", ImageLinkPreview),
    ("Card previews show each URL once and retain every caption", CardLinkPreview),
    ("Image-only previews explain retained screen location", ImageLocationPreview),
    ("Partial cell previews show the verified data row and column", CellLocationPreview),
    ("Region pixels map across negative screen origins and scaling", RegionPixelGeometry),
    ("Region previews retain state and partial metadata without ambient selection", RegionPreview),
    ("Annotation undo and redo stay scoped to a region and retain immutable strokes", AnnotationHistory),
    ("Annotation budgets and invalid drawing data are rejected", AnnotationLimits),
    ("Clipboard text retains every region in order when images are unavailable", ClipboardTextFallback),
    ("Clipboard HTML preserves Unicode byte boundaries and escapes captured markup", ClipboardHtml),
    ("Clipboard batches reject overflow without silently dropping selections", ClipboardBatchLimits),
};

var failures = new List<string>();
foreach (var test in tests)
{
    try
    {
        test.Body();
        Console.WriteLine($"PASS {test.Name}");
    }
    catch (Exception exception)
    {
        failures.Add($"FAIL {test.Name}: {exception.Message}");
        Console.Error.WriteLine(failures[^1]);
    }
}

Console.WriteLine($"{tests.Length - failures.Count}/{tests.Length} capture contracts passed");
return failures.Count == 0 ? 0 : 1;

static CaptureClipboardItem ClipboardItem(string text) => new([1, 2, 3], 100, 80,
    Snapshot() with { RegionContext = new CapturedRegionContext
    {
        Elements = [new CapturedElement { Id = "fixture", Provider = "test", Role = "Text", Text = text,
            Bounds = new(0, 0, 100, 80), VisibleBounds = new(0, 0, 100, 80), Relation = "inside" }],
    } });

static void ClipboardTextFallback()
{
    var batch = CaptureClipboardBatch.Create([ClipboardItem("第一個 selection"), ClipboardItem("second {literal} \\ path"),
        new([4], 20, 10, null, "The source changed; newer text was omitted.")]);
    Contains(batch.Text, "3 selected regions");
    Contains(batch.Text, "第一個 selection"); Contains(batch.Text, "second {literal} \\ path");
    Contains(batch.Text, "The source changed; newer text was omitted.");
    True(batch.Text.IndexOf("[A]", StringComparison.Ordinal) < batch.Text.IndexOf("[B]", StringComparison.Ordinal) &&
        batch.Text.IndexOf("[B]", StringComparison.Ordinal) < batch.Text.IndexOf("[C]", StringComparison.Ordinal), "Regions were reordered.");
    True(!batch.Text.Contains("base64", StringComparison.Ordinal) && !batch.Text.Contains("data:image", StringComparison.Ordinal), "Image bytes leaked into text fallback.");
    True(!batch.Text.Replace("\r\n", "", StringComparison.Ordinal).Contains('\n'), "Windows clipboard text contains bare line feeds.");
    True(Regex.Matches(batch.Html, "<img ").Count == 3 && Regex.Matches(batch.Rtf, @"\\pict").Count == 3, "The rich batch lost images.");
}

static void ClipboardHtml()
{
    var text = "你好 🖼 <script>alert('x')</script> & \\ {literal}";
    var batch = CaptureClipboardBatch.Create([ClipboardItem(text)]);
    var bytes = Encoding.UTF8.GetBytes(batch.Html);
    int Offset(string key) => int.Parse(Regex.Match(batch.Html, key + @":(\d+)").Groups[1].Value,
        System.Globalization.CultureInfo.InvariantCulture);
    True(Offset("EndHTML") == bytes.Length, "HTML length counts characters instead of UTF-8 bytes.");
    var fragment = Encoding.UTF8.GetString(bytes[Offset("StartFragment")..Offset("EndFragment")]);
    True(fragment.StartsWith("<div>", StringComparison.Ordinal) && fragment.EndsWith("</div>", StringComparison.Ordinal), "Fragment boundaries are invalid.");
    Contains(System.Net.WebUtility.HtmlDecode(fragment), "你好 🖼"); Contains(fragment, "&lt;script&gt;");
    True(!fragment.Contains("<script>", StringComparison.Ordinal), "Captured text became executable HTML.");
    Contains(batch.Text, text); Contains(batch.Rtf, @"\{literal\}"); Contains(batch.Rtf, @"\\");
}

static void ClipboardBatchLimits()
{
    var eight = Enumerable.Range(0, 8).Select(index => ClipboardItem($"item-{index}")).ToArray();
    Contains(CaptureClipboardBatch.Create(eight).Text, "[H]");
    foreach (var invalid in new[] { Array.Empty<CaptureClipboardItem>(), eight.Append(ClipboardItem("ninth")).ToArray() })
    {
        var rejected = false;
        try { CaptureClipboardBatch.Create(invalid); } catch (ArgumentException) { rejected = true; }
        True(rejected, "Invalid batch size was silently accepted.");
    }
}

static void AnnotationHistory()
{
    var a = new AnnotationDocument(); var b = new AnnotationDocument();
    var points = new List<AnnotationPoint> { new(2, 3), new(20, 30) };
    var stroke = new ImageAnnotation(AnnotationTool.Pen, "#FF686B", 4, points);
    True(a.Add(stroke) && b.Add(stroke), "Valid stroke was rejected.");
    points.Clear();
    True(a.Strokes[0].Points.Count == 2, "Stored strokes share mutable input.");
    True(a.Undo() && a.Strokes.Count == 0 && b.Strokes.Count == 1, "Undo affected another region.");
    True(a.Redo() && !a.CanRedo && a.Strokes.Count == 1, "Redo did not restore the stroke.");
    a.Undo();
    True(a.Add(new(AnnotationTool.Arrow, "#70B8FF", 2, [new(0, 0), new(30, 20)])) && !a.CanRedo, "New drawing retained an obsolete redo branch.");
    Contains(ContextPreviewFormatter.Format(Snapshot() with
    {
        ImageAnnotations = new ImageAnnotationInfo { StrokeCount = 1, Tools = ["arrow"] },
    }), "1 user-added marks (arrow)");
}

static void AnnotationLimits()
{
    var document = new AnnotationDocument();
    var stroke = new ImageAnnotation(AnnotationTool.Pen, "#FF686B", 4, [new(2, 3)]);
    True(!document.Add(stroke with { Width = float.NaN }), "Nonfinite width accepted.");
    True(!document.Add(stroke with { Color = "not a color" }), "Invalid color accepted.");
    True(!document.Add(stroke with { Points = [new(float.PositiveInfinity, 0)] }), "Nonfinite point accepted.");
    True(!document.Add(stroke with { Tool = AnnotationTool.Arrow }), "Incomplete arrow accepted.");
    True(!document.Add(stroke with { Points = Enumerable.Repeat(new AnnotationPoint(0, 0), AnnotationDocument.MaximumPointsPerStroke + 1).ToArray() }), "Point budget exceeded.");
    for (var i = 0; i < AnnotationDocument.MaximumStrokes; i++) True(document.Add(stroke), "Valid bounded stroke rejected.");
    True(!document.Add(stroke), "Stroke budget exceeded.");
    True(document.Undo() && document.Add(stroke), "Undo did not free space for editing.");
}

static void CellLocationPreview()
{
    var preview = ContextPreviewFormatter.Format(Snapshot() with
    {
        SpatialContext = new RegionSpatialContext { Cells = [new RegionCellContext
        {
            Bounds = new(402, 479, 306, 73), TableBounds = new(341, 395, 1799, 373),
            Relation = "contains-selection-center", RowIndex = 1, ColumnIndex = 1,
            DataRowNumber = 1, FirstDataRowIndex = 1, ColumnHeaders = ["Database Alias"],
        }] },
        RegionContext = new CapturedRegionContext(),
    });
    Contains(preview, "Location: Database Alias · data row 1");
    Contains(preview, "cell surrounding the selection");
}

static void RegionPixelGeometry()
{
    var screen = new CaptureRectangle(-600, 200, 300, 160);
    var element = new CaptureRectangle(-650, 220, 100, 50);
    var intersection = RegionContextGeometry.Intersect(element, screen)!;
    True(intersection == new CaptureRectangle(-600, 220, 50, 50), "Incorrect partial intersection.");
    True(RegionContextGeometry.ToImage(element, screen, 600, 320) == new CaptureRectangle(-100, 40, 200, 100), "Full element bounds lost the crop offset or scale.");
    True(RegionContextGeometry.ToImage(intersection, screen, 600, 320) == new CaptureRectangle(0, 40, 100, 100), "Intersection pixels were not clipped to the image.");
    True(RegionContextGeometry.Intersect(new(-700, 200, 100, 20), screen) is null, "Touching edges are not an intersection.");
}

static void RegionPreview()
{
    var preview = ContextPreviewFormatter.Format(Snapshot() with
    {
        Selection = ["unrelated application selection"],
        RegionContext = new CapturedRegionContext
        {
            Truncated = true,
            Elements = [new CapturedElement
            {
                Id = "e1", Provider = "windows-uia", Role = "Edit", Name = "Comment", Value = "Draft text",
                Bounds = new(-10, 0, 50, 20), VisibleBounds = new(0, 0, 40, 20), Relation = "intersects",
                NativeIds = new Dictionary<string, string> { ["uiaAutomationId"] = "provider-id" },
                State = new CapturedElementState { Enabled = false, Editable = false, Focused = true, Toggle = "off" },
            }],
        },
    });
    foreach (var text in new[] { "User-selected rectangle", "Comment", "Draft text", "partly inside", "disabled", "read only", "focused", "toggle: off", "capture limit" }) Contains(preview, text);
    NotContains(preview, "unrelated application selection");
    NotContains(preview, "provider-id");
}

static void ImageLocationPreview()
{
    var bounds = new CaptureRectangle(-400, 100, 180, 65);
    var preview = ContextPreviewFormatter.Format(Snapshot() with
    {
        SurfaceKind = "Image region", Application = "Redis Insight", WindowTitle = "Redis databases",
        IndicatedTarget = null, VisibleText = [],
        Region = new RegionAlignment
        {
            Status = "image-only", Reason = "No accessible text", ScreenBounds = bounds,
            Mapping = new CaptureMapping { CoordinateSpace = "desktop-physical-pixels", ScreenBounds = bounds,
                ViewportBounds = bounds, ImageBounds = new CaptureRectangle(0, 0, 180, 65) },
        },
    });
    Contains(preview, "Image with screen location");
    Contains(preview, "Redis databases");
    NotContains(preview, "Mouse pointer:");
}

static void CardLinkPreview()
{
    var preview = ContextPreviewFormatter.Format(Snapshot() with
    {
        Dom = new DomContext
        {
            Mode = "region", Elements = Enumerable.Range(1, 12).SelectMany(index => new[]
            {
                new DomElementContext { Role = "img", Text = "", Href = $"https://cards.example/{index}", Bounds = new CaptureRectangle(0, 0, 40, 40) },
                new DomElementContext { Role = "text", Text = $"Card {index} caption", Href = $"https://cards.example/{index}", Bounds = new CaptureRectangle(0, 40, 40, 20) },
            }).ToArray(),
        },
    });
    var links = preview.Split('\n').Where(line => line.StartsWith("Link: ", StringComparison.Ordinal)).ToArray();
    True(links.Length == 12 && links.Distinct().Count() == 12, "Repeated card elements hid or duplicated a card URL.");
    foreach (var index in Enumerable.Range(1, 12)) Contains(preview, $"Card {index} caption");
}

static void ImageLinkPreview()
{
    var preview = ContextPreviewFormatter.Format(Snapshot() with
    {
        Dom = new DomContext
        {
            Mode = "region", Elements = [new DomElementContext
            {
                Role = "img", Text = "", Href = "https://shop.example/product?color=blue\u202e",
                Bounds = new CaptureRectangle(1, 2, 30, 40),
            }],
        },
    });
    Contains(preview, "Link: https://shop.example/product?color=blue");
    NotContains(preview, "\u202e");
}

static void SelectionStaysPrimaryAndSanitized()
{
    var snapshot = Snapshot() with
    {
        Application = "Edge\u202E",
        Selection = ["selected cell"],
        SelectionElements =
        [
            new SelectedElementInfo
            {
                ControlType = "Cell",
                Name = "A1",
                Value = "42",
                Formula = "=SUM(B2:B8)",
                Bounds = "1,2 30x20",
                Row = 1,
                Column = 1,
            },
        ],
        SelectionElementCount = 4,
    };

    var preview = ContextPreviewFormatter.Format(snapshot);
    Contains(preview, "PRIMARY SURFACE SELECTION");
    Contains(preview, "selected cell");
    Contains(preview, "showing 1 of 4");
    Contains(preview, "\"role\": \"Cell\"");
    Contains(preview, "\"formula\": \"=SUM(B2:B8)\"");
    True(preview.IndexOf("selected cell", StringComparison.Ordinal) <
         preview.IndexOf("Mouse pointer:", StringComparison.Ordinal),
        "Selected content no longer precedes pointer context.");
    True(!preview.Contains('\u202E'), "Bidirectional control leaked into capture preview.");
}

static void InternalMetadataStaysHidden()
{
    var preview = ContextPreviewFormatter.Format(Snapshot());
    Contains(preview, "Mouse pointer: Button named \"Run\"");
    NotContains(preview, "confidence medium");
    NotContains(preview, "Snapshot confidence");
    NotContains(preview, "automationId");
    NotContains(preview, "Safety:");
}

static void AccessibilityPreviewStaysCompact()
{
    var tree = new AccessibilityTreeInfo
    {
        Source = "windows-uia-control-view",
        NodeCount = 3,
        Truncated = false,
        Roots =
        [
            new AccessibilityNodeInfo
            {
                Role = "Table",
                Name = "My Accounts",
                Bounds = "10,20,600,240",
                RowCount = 2,
                ColumnCount = 3,
                Children =
                [
                    new AccessibilityNodeInfo
                    {
                        Role = "Custom",
                        Name = "example-user",
                        Row = 1,
                        Column = 0,
                    },
                    new AccessibilityNodeInfo
                    {
                        Role = "Group",
                        Children =
                        [
                            new AccessibilityNodeInfo { Role = "Text", Name = "Necessary label" },
                        ],
                    },
                ],
            },
        ],
    };
    var snapshot = Snapshot() with
    {
        AccessibilityTree = tree,
        VisibleText = ["flat fallback that should not be duplicated"],
    };

    var preview = ContextPreviewFormatter.Format(snapshot);
    Contains(preview, "Nearby accessibility structure");
    Contains(preview, "\"role\": \"Table\"");
    Contains(preview, "\"row\": 1");
    Contains(preview, "Necessary label");
    NotContains(preview, "\"role\": \"Group\"");
    NotContains(preview, "windows-uia-control-view");
    NotContains(preview, "nodeCount");
    NotContains(preview, "bounds");
    NotContains(preview, "flat fallback that should not be duplicated");

    var truncated = ContextPreviewFormatter.Format(snapshot with
    {
        AccessibilityTree = tree with { Truncated = true },
    });
    Contains(truncated, "Additional visible text omitted by the truncated accessibility structure");
    Contains(truncated, "flat fallback that should not be duplicated");
}

static void VisibleTextStaysBounded()
{
    var visibleText = Enumerable.Range(1, 150)
        .Select(index => $"Paragraph {index}: {new string('x', 2_100)}")
        .ToArray();
    var preview = ContextPreviewFormatter.Format(Snapshot() with { VisibleText = visibleText });

    Contains(preview, "Paragraph 1:");
    True(preview.Length < 31_500, "Visible-text preview exceeded its output budget.");
    NotContains(preview, "Paragraph 150:");
}

static void BrowserEnrichmentPreservesObjectSelections()
{
    var native = Snapshot() with
    {
        Selection = ["B2:E5"],
        SelectionElements = [new SelectedElementInfo { ControlType = "GoogleSheetsRange", Name = "B2:E5" }],
        SelectionElementCount = 1,
    };
    var selection = ContextSelection.ForBrowser(new DomContext { Mode = "capture" }, native);
    True(selection.Text.Single() == "B2:E5", "DOM without a text selection discarded the user's native range.");
    True(selection.Elements.Single().Name == "B2:E5" && selection.IncludesNativeSelection,
        "The explicit native object selection lost its provenance.");
}

static void DomSelectionPriority()
{
    const string original = " first  line\n  第二行\tvalue ";
    var native = Snapshot() with { Selection = ["normalized other text"] };
    var selection = ContextSelection.ForBrowser(new DomContext { Mode = "capture", SelectedText = [original] }, native);
    True(selection.Text.Single() == original, "The exact DOM selection was replaced by normalized accessibility text.");
    var preview = ContextPreviewFormatter.Format(native with
    {
        Selection = [original], Dom = new DomContext
        {
            Mode = "capture", SelectedText = [original],
            Nearby = new DomElementContext { Role = "article", Text = "Nearby background", Bounds = new CaptureRectangle(0, 0, 10, 10) },
        },
    });
    Contains(preview, original);
    True(preview.IndexOf(original, StringComparison.Ordinal) < preview.IndexOf("Nearby background", StringComparison.Ordinal),
        "Nearby DOM content displaced the user's original selection in the preview.");
    foreach (var mode in new[] { "element", "region" })
    {
        var picked = ContextSelection.ForBrowser(new DomContext { Mode = mode }, native);
        True(picked.Text.Count == 0 && picked.Elements.Count == 0,
            "A newly picked element/image inherited an unrelated prior selection.");
    }
}

static ContextSnapshot Snapshot()
{
    var now = new DateTimeOffset(2026, 8, 30, 0, 0, 0, TimeSpan.Zero);
    return new ContextSnapshot
    {
        SnapshotId = "capture-test",
        ObservedAtUtc = now,
        ExpiresAtUtc = now.AddSeconds(30),
        SurfaceKind = "Browser",
        Application = "Edge",
        ProcessName = "msedge",
        WindowTitle = "Example",
        Locator = new LocatorInfo { Kind = "URL", Value = "https://example.com" },
        VisibleText = ["nearby value"],
        IndicatedTarget = new IndicatedTargetInfo
        {
            ControlType = "Button",
            Name = "Run",
            AutomationId = "internal-save-id",
            Bounds = "1,2 30x20",
            Confidence = "medium",
        },
        Confidence = "high",
    };
}

static void Contains(string value, string expected)
{
    if (!value.Contains(expected, StringComparison.Ordinal))
    {
        throw new InvalidOperationException($"Expected preview to contain: {expected}");
    }
}

static void NotContains(string value, string expected)
{
    if (value.Contains(expected, StringComparison.OrdinalIgnoreCase))
    {
        throw new InvalidOperationException($"Preview unexpectedly contained: {expected}");
    }
}

static void True(bool condition, string message)
{
    if (!condition)
    {
        throw new InvalidOperationException(message);
    }
}

static void BrowserProfiles()
{
    True(BrowserDiscovery.IsLocalEndpoint(new Uri("http://127.0.0.1:9222")) &&
        BrowserDiscovery.IsLocalEndpoint(new Uri("ws://[::1]:9223/devtools/browser/example")), "Local endpoints were rejected.");
    True(!BrowserDiscovery.IsLocalEndpoint(new Uri("https://example.com")) &&
        !BrowserDiscovery.IsLocalEndpoint(new Uri("ws://user:password@localhost:9222")) &&
        !BrowserDiscovery.IsLocalEndpoint(new Uri("file:///tmp/browser")), "Invalid connection configuration was accepted.");
    foreach (var platform in new[] { "windows", "macos", "linux" })
    {
        var edge = BrowserDiscovery.ProfileDirectory("edge", platform);
        var chrome = BrowserDiscovery.ProfileDirectory("chrome", platform);
        True(edge is not null && chrome is not null && edge != chrome, "Browser profiles overlap on " + platform);
    }
    True(BrowserDiscovery.Family("msedge.exe") == "edge" && BrowserDiscovery.Family("Microsoft Edge") == "edge", "Edge process identity was lost.");
    True(BrowserDiscovery.Family("chrome.exe") == "chrome" && BrowserDiscovery.Family("Google Chrome") == "chrome", "Chrome process identity was lost.");
    True(BrowserDiscovery.ProfileDirectory("unknown", "windows") is null && BrowserDiscovery.Family("firefox") is null, "Unknown browser received another browser's profile.");
}
