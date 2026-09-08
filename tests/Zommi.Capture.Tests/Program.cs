using Zommi.Capture;

var tests = new (string Name, Action Body)[]
{
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
    });
    Contains(preview, "Location: Database Alias · data row 1");
    Contains(preview, "cell surrounding the selection");
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
                        Name = "example",
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
