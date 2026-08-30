using Zommi.Capture;

var tests = new (string Name, Action Body)[]
{
    ("Selection stays primary and sanitized", SelectionStaysPrimaryAndSanitized),
    ("Internal capture metadata stays hidden", InternalMetadataStaysHidden),
    ("Accessibility preview stays compact", AccessibilityPreviewStaysCompact),
    ("Visible text stays bounded", VisibleTextStaysBounded),
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
