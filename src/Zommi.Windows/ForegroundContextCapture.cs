using System.Diagnostics;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using FlaUI.Core;
using FlaUI.Core.AutomationElements;
using FlaUI.Core.Definitions;
using FlaUI.Core.Exceptions;
using FlaUI.UIA3;
using Zommi.Core;

namespace Zommi.Windows;

internal sealed class ForegroundContextCapture : IDisposable
{
    private const int MaximumVisibleTextItems = 128;
    private const int MaximumVisibleTextCharacters = 30_000;
    private const int MaximumVisibleTextItemCharacters = 2_000;
    private const int MaximumVisibleTextMilliseconds = 120;
    private const int MaximumDocumentTextCharacters = 30_000;
    private const int MaximumAccessibilityNodes = 128;
    private const int MaximumAccessibilityCharacters = 20_000;
    private const int MaximumAccessibilityDepth = 24;
    private const int MaximumAccessibilityMilliseconds = 200;
    private const int MaximumSelectionElements = 16;
    internal sealed record CaptureResult(
        ContextSnapshot? Snapshot,
        bool PreservePrevious,
        long ElapsedMilliseconds,
        IReadOnlyDictionary<string, long> Timings);
    private sealed record SurfaceSelectionCapture(
        IReadOnlyList<string> Text,
        IReadOnlyList<SelectedElementInfo> Items,
        int TotalItemCount,
        IReadOnlyList<AutomationElement> Elements);
    private sealed record BrowserContextCapture(
        LocatorInfo? Locator,
        SelectedElementInfo? SheetsRange);
    private sealed record PowerPointSelectionCapture(
        LocatorInfo? Locator,
        IReadOnlyList<string> Text,
        IReadOnlyList<SelectedElementInfo> Items,
        int TotalItemCount);

    private static readonly HashSet<string> BrowserProcesses = new(StringComparer.OrdinalIgnoreCase)
    {
        "brave", "chrome", "firefox", "msedge", "opera",
    };

    private readonly UIA3Automation automation = new()
    {
        ConnectionTimeout = TimeSpan.FromMilliseconds(750),
        TransactionTimeout = TimeSpan.FromMilliseconds(1000),
    };
    private readonly ITreeWalker controlViewWalker;
    private readonly ITreeWalker rawViewWalker;

    public ForegroundContextCapture()
    {
        controlViewWalker = automation.TreeWalkerFactory.GetControlViewWalker();
        rawViewWalker = automation.TreeWalkerFactory.GetRawViewWalker();
    }

    public void Dispose() => automation.Dispose();

    public CaptureResult Capture(DateTimeOffset nowUtc)
    {
        var startedAt = Stopwatch.GetTimestamp();
        if (!NativeMethods.GetCursorPos(out var pointer))
        {
            return new CaptureResult(
                null,
                PreservePrevious: true,
                (long)Stopwatch.GetElapsedTime(startedAt).TotalMilliseconds,
                new Dictionary<string, long>(StringComparer.Ordinal));
        }

        return CaptureAt(nowUtc, pointer.X, pointer.Y);
    }

    public CaptureResult CaptureAt(DateTimeOffset nowUtc, int pointerX, int pointerY)
    {
        var startedAt = Stopwatch.GetTimestamp();
        var stageStartedAt = startedAt;
        var timings = new Dictionary<string, long>(StringComparer.Ordinal);
        var pointer = new NativeMethods.Point { X = pointerX, Y = pointerY };
        void Mark(string stage)
        {
            var completedAt = Stopwatch.GetTimestamp();
            timings[stage] = (long)Stopwatch.GetElapsedTime(stageStartedAt, completedAt).TotalMilliseconds;
            stageStartedAt = completedAt;
        }
        CaptureResult Complete(ContextSnapshot? snapshot, bool preservePrevious) => new(
            snapshot,
            preservePrevious,
            (long)Stopwatch.GetElapsedTime(startedAt).TotalMilliseconds,
            timings);

        var hitWindow = NativeMethods.WindowFromPoint(pointer);
        var windowHandle = hitWindow == IntPtr.Zero
            ? IntPtr.Zero
            : NativeMethods.GetAncestor(hitWindow, NativeMethods.GetRoot);
        if (windowHandle == IntPtr.Zero)
        {
            windowHandle = hitWindow;
        }

        if (windowHandle == IntPtr.Zero)
        {
            return Complete(null, preservePrevious: true);
        }

        _ = NativeMethods.GetWindowThreadProcessId(windowHandle, out var processId);
        if (processId == 0 || processId == Environment.ProcessId)
        {
            return Complete(null, preservePrevious: true);
        }

        Process process;
        try
        {
            process = Process.GetProcessById(unchecked((int)processId));
        }
        catch (ArgumentException)
        {
            return Complete(null, preservePrevious: true);
        }

        using (process)
        {
            var processName = process.ProcessName;
            var title = ReadWindowText(windowHandle);
            Mark("window");
            string surfaceKind;
            LocatorInfo? locator = null;
            var surfaceSelection = TryReadSurfaceSelection(windowHandle);
            Mark("selection");
            var powerPointSelection = processName.Equals("POWERPNT", StringComparison.OrdinalIgnoreCase)
                ? TryReadPowerPointSelection(windowHandle)
                : null;
            Mark("powerpoint");
            if (powerPointSelection is not null)
            {
                surfaceSelection = MergeSurfaceSelection(surfaceSelection, powerPointSelection);
            }

            IReadOnlyList<string> selection = surfaceSelection.Text;
            string? limitation;
            string application;

            if (BrowserProcesses.Contains(processName))
            {
                surfaceKind = "Browser";
                application = FriendlyBrowserName(processName);
                var browserContext = TryReadBrowserContext(windowHandle);
                locator = browserContext.Locator;
                if (browserContext.SheetsRange is { } sheetsRange)
                {
                    surfaceSelection = AddSelectionItems(surfaceSelection, [sheetsRange], 1);
                }

                limitation = locator is null
                    ? "The browser address bar was not exposed through Windows UI Automation. No URL was inferred."
                    : null;
            }
            else if (processName.Equals("explorer", StringComparison.OrdinalIgnoreCase))
            {
                surfaceKind = "File Explorer";
                application = "File Explorer";
                var explorer = TryReadExplorer(windowHandle);
                locator = explorer.Locator;
                selection = selection
                    .Concat(explorer.Selection)
                    .Distinct(StringComparer.Ordinal)
                    .Take(8)
                    .ToArray();
                limitation = locator is null
                    ? "Explorer did not expose a filesystem path for this window."
                    : null;
            }
            else if (processName.Equals("POWERPNT", StringComparison.OrdinalIgnoreCase))
            {
                surfaceKind = "Presentation";
                application = "Microsoft PowerPoint";
                locator = powerPointSelection?.Locator;
                limitation = locator is null
                    ? "PowerPoint did not expose the active slide through its running application object."
                    : null;
            }
            else
            {
                surfaceKind = "Window";
                application = CultureInfo.InvariantCulture.TextInfo.ToTitleCase(processName);
                limitation = null;
            }
            Mark("surface");

            if (surfaceKind == "File Explorer" && locator is null && string.IsNullOrWhiteSpace(title))
            {
                return Complete(null, preservePrevious: false);
            }

            var accessibilityContext = TryReadAccessibilityContext(
                windowHandle,
                pointer,
                surfaceSelection.Elements,
                surfaceKind == "Browser");
            Mark("accessibility");
            var indicatedTarget = TryReadPointerTarget(windowHandle, pointer);
            Mark("pointer");
            var visibleText = accessibilityContext is { Truncated: false }
                ? []
                : TryReadVisibleText(windowHandle, pointer);
            Mark("visibleText");
            var hasSurfaceSelection = selection.Count > 0 || surfaceSelection.Items.Count > 0;
            var hasSpecificPointerTarget = IsSpecificPointerTarget(indicatedTarget);
            if (!hasSurfaceSelection && !hasSpecificPointerTarget)
            {
                limitation = AppendLimitation(
                    limitation,
                    "No selected object was exposed and the pointer resolved only to a broad canvas, document, pane, or unknown target. " +
                    "Use Alt+Shift+A to attach an explicit image region when visual precision is required.");
            }

            var snapshot = new ContextSnapshot
            {
                SnapshotId = Guid.NewGuid().ToString("D"),
                ObservedAtUtc = nowUtc,
                ExpiresAtUtc = nowUtc.AddSeconds(30),
                SurfaceKind = surfaceKind,
                Application = application,
                ProcessName = processName,
                WindowTitle = title,
                Locator = locator,
                Selection = selection,
                SelectionElements = surfaceSelection.Items,
                SelectionElementCount = surfaceSelection.TotalItemCount > 0
                    ? surfaceSelection.TotalItemCount
                    : null,
                VisibleText = visibleText,
                AccessibilityTree = accessibilityContext,
                IndicatedTarget = indicatedTarget,
                Confidence = hasSurfaceSelection
                    ? "high"
                    : hasSpecificPointerTarget || locator is not null || visibleText.Count > 0
                        ? "medium"
                        : "limited",
                Limitation = limitation,
            };
            return Complete(snapshot, preservePrevious: false);
        }
    }

    private BrowserContextCapture TryReadBrowserContext(IntPtr windowHandle)
    {
        try
        {
            var root = automation.FromHandle(windowHandle);
            var editCondition = automation.ConditionFactory.ByControlType(ControlType.Edit);
            var edits = root.FindAll(TreeScope.Descendants, editCondition);
            LocatorInfo? locator = null;
            SelectedElementInfo? range = null;
            foreach (var edit in edits.Take(80))
            {
                if (edit.Properties.IsPassword.ValueOrDefault)
                {
                    continue;
                }

                var value = edit.Patterns.Value.PatternOrDefault?.Value.ValueOrDefault?.Trim();
                if (locator is null && ParseBrowserUrl(value) is { } uri)
                {
                    locator = new LocatorInfo { Kind = "URL", Value = uri.AbsoluteUri };
                    continue;
                }

                if (range is null && !string.IsNullOrWhiteSpace(value))
                {
                    var name = edit.Properties.Name.ValueOrDefault;
                    var isNameBox = name?.Contains("name box", StringComparison.OrdinalIgnoreCase) is true;
                    var bounds = edit.Properties.BoundingRectangle.ValueOrDefault;
                    var looksLikeCompactRangeBox = LooksLikeGoogleSheetsRange(value) &&
                        bounds.Width is >= 30 and <= 360;
                    if (isNameBox || looksLikeCompactRangeBox)
                    {
                        range = new SelectedElementInfo
                        {
                            ControlType = "GoogleSheetsRange",
                            Name = Limit(value, 240),
                            Bounds = FormatBounds(bounds),
                        };
                    }
                }
            }

            if (!IsGoogleSheetsLocator(locator))
            {
                range = null;
            }

            return new BrowserContextCapture(locator, range);
        }
        catch (Exception exception) when (exception is ElementNotAvailableException or InvalidOperationException or COMException)
        {
            return new BrowserContextCapture(null, null);
        }
    }

    private SurfaceSelectionCapture TryReadSurfaceSelection(IntPtr windowHandle)
    {
        try
        {
            var root = automation.FromHandle(windowHandle);
            var candidates = new List<AutomationElement>();
            var focused = automation.FocusedElement();
            if (focused is not null && IsWithinWindow(focused, root))
            {
                var current = focused;
                for (var depth = 0; current is not null && depth < 12; depth++)
                {
                    candidates.Add(current);
                    if (current.Equals(root))
                    {
                        break;
                    }

                    current = controlViewWalker.GetParent(current);
                }
            }

            var documentCondition = automation.ConditionFactory.ByControlType(ControlType.Document);
            var documents = root
                .FindAll(TreeScope.Descendants, documentCondition)
                .Take(12)
                .ToArray();
            candidates.AddRange(documents);

            var selected = new VisibleTextCollector(maximumItems: 8, maximumCharacters: 6000);
            foreach (var candidate in candidates.Distinct())
            {
                if (candidate.Properties.IsPassword.ValueOrDefault ||
                    candidate.Patterns.Text.PatternOrDefault is not { } textPattern)
                {
                    continue;
                }

                foreach (var range in textPattern.GetSelection())
                {
                    selected.Add(range.GetText(4000));
                }

                if (selected.IsFull)
                {
                    break;
                }
            }

            var selectedElements = new List<AutomationElement>();
            var totalItemCount = 0;
            foreach (var candidate in candidates.Distinct())
            {
                CollectSelectedElements(candidate, selectedElements, ref totalItemCount);
            }

            if (selectedElements.Count == 0)
            {
                var selectionContainerCondition = new FlaUI.Core.Conditions.PropertyCondition(
                    automation.PropertyLibrary.PatternAvailability.IsSelectionPatternAvailable,
                    true);
                foreach (var document in documents)
                {
                    foreach (var container in document
                        .FindAll(TreeScope.Descendants, selectionContainerCondition)
                        .Take(32))
                    {
                        CollectSelectedElements(container, selectedElements, ref totalItemCount);
                        if (selectedElements.Count >= MaximumSelectionElements)
                        {
                            break;
                        }
                    }

                    if (selectedElements.Count >= MaximumSelectionElements)
                    {
                        break;
                    }
                }
            }

            var resolvedItems = selectedElements
                .Take(MaximumSelectionElements)
                .Select(element => (Element: element, Item: TryCreateSelectedElement(element)))
                .Where(entry => entry.Item is not null)
                .ToArray();
            var items = resolvedItems.Select(entry => entry.Item!).ToArray();
            if (items.Length == 0)
            {
                totalItemCount = 0;
            }

            totalItemCount = Math.Max(totalItemCount, items.Length);
            return new SurfaceSelectionCapture(
                selected.Items,
                items,
                totalItemCount,
                resolvedItems.Select(entry => entry.Element).ToArray());
        }
        catch (Exception exception) when (exception is ElementNotAvailableException or InvalidOperationException or COMException)
        {
            return new SurfaceSelectionCapture([], [], 0, []);
        }
    }

    internal IReadOnlyList<string> TryReadSelectedText(IntPtr windowHandle) =>
        TryReadSurfaceSelection(windowHandle).Text;

    private static SurfaceSelectionCapture MergeSurfaceSelection(
        SurfaceSelectionCapture uiaSelection,
        PowerPointSelectionCapture powerPointSelection)
        => AddSelectionItems(
            uiaSelection with
            {
                Text = powerPointSelection.Text
                    .Concat(uiaSelection.Text)
                    .Where(value => !string.IsNullOrWhiteSpace(value))
                    .Distinct(StringComparer.Ordinal)
                    .Take(8)
                    .ToArray(),
            },
            powerPointSelection.Items,
            powerPointSelection.TotalItemCount);

    private static SurfaceSelectionCapture AddSelectionItems(
        SurfaceSelectionCapture selection,
        IReadOnlyList<SelectedElementInfo> additionalItems,
        int additionalTotalItemCount)
    {
        var items = additionalItems
            .Concat(selection.Items)
            .DistinctBy(item => new
            {
                item.ControlType,
                item.Name,
                item.Value,
                item.Bounds,
                item.Row,
                item.Column,
            })
            .Take(MaximumSelectionElements)
            .ToArray();
        return new SurfaceSelectionCapture(
            selection.Text,
            items,
            Math.Max(Math.Max(additionalTotalItemCount, selection.TotalItemCount), items.Length),
            selection.Elements);
    }

    private static bool IsGoogleSheetsLocator(LocatorInfo? locator) =>
        locator is not null &&
        Uri.TryCreate(locator.Value, UriKind.Absolute, out var uri) &&
        uri.Host.Equals("docs.google.com", StringComparison.OrdinalIgnoreCase) &&
        uri.AbsolutePath.StartsWith("/spreadsheets/", StringComparison.OrdinalIgnoreCase);

    private static bool LooksLikeGoogleSheetsRange(string value) => Regex.IsMatch(
        value,
        "^(?:'[^']+'!|[A-Za-z0-9_ ]+!)?(?:\\$?[A-Z]{1,3}\\$?\\d+(?::\\$?[A-Z]{1,3}\\$?\\d+)?|[A-Z]{1,3}:[A-Z]{1,3}|\\d+:\\d+)$",
        RegexOptions.CultureInvariant | RegexOptions.IgnoreCase,
        TimeSpan.FromMilliseconds(50));

    private static PowerPointSelectionCapture? TryReadPowerPointSelection(IntPtr windowHandle)
    {
        object? application = null;
        object? activeWindow = null;
        object? selection = null;
        object? view = null;
        object? activeSlide = null;
        try
        {
            application = NativeMethods.GetActiveComObject("PowerPoint.Application");
            if (application is null)
            {
                return null;
            }

            dynamic powerPoint = application;
            activeWindow = powerPoint.ActiveWindow;
            if (activeWindow is null)
            {
                return null;
            }

            dynamic window = activeWindow;
            var activeWindowHandle = new IntPtr(Convert.ToInt64((object)window.HWND, CultureInfo.InvariantCulture));
            var activeRoot = NativeMethods.GetAncestor(activeWindowHandle, NativeMethods.GetRoot);
            if (activeWindowHandle != windowHandle && activeRoot != windowHandle)
            {
                return null;
            }

            LocatorInfo? locator = null;
            try
            {
                view = window.View;
                dynamic dynamicView = view;
                activeSlide = dynamicView.Slide;
                if (activeSlide is not null)
                {
                    dynamic slide = activeSlide;
                    var slideIndex = Convert.ToInt32((object)slide.SlideIndex, CultureInfo.InvariantCulture);
                    var slideName = Convert.ToString((object)slide.Name, CultureInfo.InvariantCulture);
                    locator = new LocatorInfo
                    {
                        Kind = "Slide",
                        Value = string.IsNullOrWhiteSpace(slideName)
                            ? slideIndex.ToString(CultureInfo.InvariantCulture)
                            : $"{slideIndex}: {slideName}",
                    };
                }
            }
            catch (Exception exception) when (IsRecoverableComException(exception))
            {
                // Slide sorter and master views do not always expose View.Slide.
            }

            selection = window.Selection;
            if (selection is null)
            {
                return new PowerPointSelectionCapture(locator, [], [], 0);
            }

            dynamic dynamicSelection = selection;
            var selectionType = Convert.ToInt32((object)dynamicSelection.Type, CultureInfo.InvariantCulture);
            var text = new List<string>();
            var items = new List<SelectedElementInfo>();
            var totalItemCount = 0;

            if (selectionType == 3)
            {
                TryReadPowerPointSelectedText(selection, text);
            }

            if (selectionType is 2 or 3)
            {
                TryReadPowerPointShapes(activeWindow, selection, items, ref totalItemCount);
            }
            else if (selectionType == 1)
            {
                TryReadPowerPointSlides(selection, items, ref totalItemCount);
            }

            return new PowerPointSelectionCapture(locator, text, items, totalItemCount);
        }
        catch (Exception exception) when (IsRecoverableComException(exception))
        {
            return null;
        }
        finally
        {
            ReleaseComObject(activeSlide);
            ReleaseComObject(view);
            ReleaseComObject(selection);
            ReleaseComObject(activeWindow);
            ReleaseComObject(application);
        }
    }

    private static void TryReadPowerPointSelectedText(object selection, List<string> text)
    {
        object? textRange = null;
        try
        {
            dynamic dynamicSelection = selection;
            textRange = dynamicSelection.TextRange;
            if (textRange is not null)
            {
                dynamic range = textRange;
                var value = Limit(Convert.ToString((object)range.Text, CultureInfo.InvariantCulture), 6_000);
                if (value is not null)
                {
                    text.Add(value);
                }
            }
        }
        catch (Exception exception) when (IsRecoverableComException(exception))
        {
            // A shape can remain selected while its text range is unavailable.
        }
        finally
        {
            ReleaseComObject(textRange);
        }
    }

    private static void TryReadPowerPointShapes(
        object activeWindow,
        object selection,
        List<SelectedElementInfo> items,
        ref int totalItemCount)
    {
        object? shapeRange = null;
        try
        {
            dynamic dynamicSelection = selection;
            shapeRange = dynamicSelection.ShapeRange;
            dynamic shapes = shapeRange;
            totalItemCount = Convert.ToInt32((object)shapes.Count, CultureInfo.InvariantCulture);
            for (var index = 1; index <= Math.Min(totalItemCount, MaximumSelectionElements); index++)
            {
                object? shape = null;
                try
                {
                    shape = shapes.Item(index);
                    dynamic dynamicShape = shape;
                    var left = Convert.ToSingle((object)dynamicShape.Left, CultureInfo.InvariantCulture);
                    var top = Convert.ToSingle((object)dynamicShape.Top, CultureInfo.InvariantCulture);
                    var width = Convert.ToSingle((object)dynamicShape.Width, CultureInfo.InvariantCulture);
                    var height = Convert.ToSingle((object)dynamicShape.Height, CultureInfo.InvariantCulture);
                    dynamic window = activeWindow;
                    var screenLeft = Convert.ToInt32((object)window.PointsToScreenPixelsX(left), CultureInfo.InvariantCulture);
                    var screenTop = Convert.ToInt32((object)window.PointsToScreenPixelsY(top), CultureInfo.InvariantCulture);
                    var screenRight = Convert.ToInt32((object)window.PointsToScreenPixelsX(left + width), CultureInfo.InvariantCulture);
                    var screenBottom = Convert.ToInt32((object)window.PointsToScreenPixelsY(top + height), CultureInfo.InvariantCulture);
                    items.Add(new SelectedElementInfo
                    {
                        ControlType = "PowerPointShape",
                        Name = Limit(Convert.ToString((object)dynamicShape.Name, CultureInfo.InvariantCulture), 1_000),
                        Value = TryReadPowerPointShapeText(shape),
                        Bounds = string.Create(
                            CultureInfo.InvariantCulture,
                            $"{screenLeft},{screenTop},{Math.Max(0, screenRight - screenLeft)},{Math.Max(0, screenBottom - screenTop)}"),
                    });
                }
                catch (Exception exception) when (IsRecoverableComException(exception))
                {
                    // Keep the remaining selected shapes if one COM proxy is stale.
                }
                finally
                {
                    ReleaseComObject(shape);
                }
            }
        }
        catch (Exception exception) when (IsRecoverableComException(exception))
        {
            // Some selection types expose TextRange but not ShapeRange.
        }
        finally
        {
            ReleaseComObject(shapeRange);
        }
    }

    private static string? TryReadPowerPointShapeText(object shape)
    {
        object? textFrame = null;
        object? textRange = null;
        try
        {
            dynamic dynamicShape = shape;
            if (Convert.ToInt32((object)dynamicShape.HasTextFrame, CultureInfo.InvariantCulture) == 0)
            {
                return null;
            }

            textFrame = dynamicShape.TextFrame;
            dynamic frame = textFrame;
            if (Convert.ToInt32((object)frame.HasText, CultureInfo.InvariantCulture) == 0)
            {
                return null;
            }

            textRange = frame.TextRange;
            dynamic range = textRange;
            return Limit(Convert.ToString((object)range.Text, CultureInfo.InvariantCulture), 2_000);
        }
        catch (Exception exception) when (IsRecoverableComException(exception))
        {
            return null;
        }
        finally
        {
            ReleaseComObject(textRange);
            ReleaseComObject(textFrame);
        }
    }

    private static void TryReadPowerPointSlides(
        object selection,
        List<SelectedElementInfo> items,
        ref int totalItemCount)
    {
        object? slideRange = null;
        try
        {
            dynamic dynamicSelection = selection;
            slideRange = dynamicSelection.SlideRange;
            dynamic slides = slideRange;
            totalItemCount = Convert.ToInt32((object)slides.Count, CultureInfo.InvariantCulture);
            for (var index = 1; index <= Math.Min(totalItemCount, MaximumSelectionElements); index++)
            {
                object? slide = null;
                try
                {
                    slide = slides.Item(index);
                    dynamic dynamicSlide = slide;
                    var slideIndex = Convert.ToInt32((object)dynamicSlide.SlideIndex, CultureInfo.InvariantCulture);
                    var name = Convert.ToString((object)dynamicSlide.Name, CultureInfo.InvariantCulture);
                    items.Add(new SelectedElementInfo
                    {
                        ControlType = "PowerPointSlide",
                        Name = string.IsNullOrWhiteSpace(name) ? $"Slide {slideIndex}" : $"Slide {slideIndex}: {name}",
                    });
                }
                catch (Exception exception) when (IsRecoverableComException(exception))
                {
                    // Keep other selected slides if one proxy becomes unavailable.
                }
                finally
                {
                    ReleaseComObject(slide);
                }
            }
        }
        catch (Exception exception) when (IsRecoverableComException(exception))
        {
            // Non-slide selection types do not expose SlideRange.
        }
        finally
        {
            ReleaseComObject(slideRange);
        }
    }

    private static bool IsRecoverableComException(Exception exception) => exception is
        COMException or InvalidCastException or InvalidOperationException or
        Microsoft.CSharp.RuntimeBinder.RuntimeBinderException;

    private static void CollectSelectedElements(
        AutomationElement candidate,
        List<AutomationElement> selectedElements,
        ref int totalItemCount)
    {
        try
        {
            if (candidate.Patterns.Selection.PatternOrDefault is { } selectionPattern)
            {
                var selection = selectionPattern.Selection.ValueOrDefault ?? [];
                totalItemCount = Math.Max(totalItemCount, selection.Length);
                foreach (var element in selection.Take(MaximumSelectionElements))
                {
                    AddSelectedElement(selectedElements, element);
                }
            }

            if (candidate.Patterns.Selection2.PatternOrDefault is { } selection2Pattern)
            {
                totalItemCount = Math.Max(totalItemCount, selection2Pattern.ItemCount.ValueOrDefault);
                AddSelectedElement(selectedElements, selection2Pattern.FirstSelectedItem.ValueOrDefault);
                AddSelectedElement(selectedElements, selection2Pattern.CurrentSelectedItem.ValueOrDefault);
                AddSelectedElement(selectedElements, selection2Pattern.LastSelectedItem.ValueOrDefault);
            }

            if (candidate.Patterns.SelectionItem.PatternOrDefault is { } selectionItemPattern &&
                selectionItemPattern.IsSelected.ValueOrDefault)
            {
                totalItemCount = Math.Max(totalItemCount, 1);
                AddSelectedElement(selectedElements, candidate);
            }
        }
        catch (Exception exception) when (exception is ElementNotAvailableException or InvalidOperationException or COMException)
        {
            // Selection providers can disappear while a document rerenders.
            // Preserve any selection items collected from the remaining providers.
        }
    }

    private static void AddSelectedElement(
        List<AutomationElement> selectedElements,
        AutomationElement? element)
    {
        if (element is null || selectedElements.Count >= MaximumSelectionElements || selectedElements.Contains(element))
        {
            return;
        }

        selectedElements.Add(element);
    }

    private static SelectedElementInfo? TryCreateSelectedElement(AutomationElement element)
    {
        try
        {
            if (element.Properties.IsPassword.ValueOrDefault)
            {
                return null;
            }

            var controlType = element.Properties.ControlType.ValueOrDefault;
            if (controlType == ControlType.TabItem)
            {
                return null;
            }

            var gridItem = element.Patterns.GridItem.PatternOrDefault;
            var value = element.Patterns.Value.PatternOrDefault?.Value.ValueOrDefault;
            if (string.IsNullOrWhiteSpace(value) && element.Patterns.Text.PatternOrDefault is { } textPattern)
            {
                value = textPattern.DocumentRange.GetText(2_000);
            }

            return new SelectedElementInfo
            {
                ControlType = FormatControlType(controlType) ?? "Unknown",
                Name = Limit(element.Properties.Name.ValueOrDefault, 1_000),
                Value = Limit(value, 2_000),
                Formula = Limit(element.Patterns.SpreadsheetItem.PatternOrDefault?.Formula.ValueOrDefault, 1_000),
                Bounds = FormatBounds(element.Properties.BoundingRectangle.ValueOrDefault),
                Row = gridItem?.Row.ValueOrDefault,
                Column = gridItem?.Column.ValueOrDefault,
                RowSpan = gridItem?.RowSpan.ValueOrDefault,
                ColumnSpan = gridItem?.ColumnSpan.ValueOrDefault,
            };
        }
        catch (Exception exception) when (exception is ElementNotAvailableException or InvalidOperationException or COMException)
        {
            return null;
        }
    }

    private static Uri? ParseBrowserUrl(string? value)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            return null;
        }

        if (Uri.TryCreate(value, UriKind.Absolute, out var absolute) && IsSupportedBrowserUri(absolute))
        {
            return absolute;
        }

        if (!value.Contains(' ') &&
            value.Contains('.') &&
            Uri.TryCreate($"https://{value}", UriKind.Absolute, out var normalized) &&
            IsSupportedBrowserUri(normalized))
        {
            return normalized;
        }

        return null;
    }

    private static bool IsSupportedBrowserUri(Uri uri) =>
        uri.Scheme.Equals(Uri.UriSchemeHttp, StringComparison.OrdinalIgnoreCase) ||
        uri.Scheme.Equals(Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase) ||
        uri.Scheme.Equals(Uri.UriSchemeFile, StringComparison.OrdinalIgnoreCase);

    private static (LocatorInfo? Locator, IReadOnlyList<string> Selection) TryReadExplorer(IntPtr windowHandle)
    {
        object? shell = null;
        object? shellWindows = null;
        try
        {
            var shellType = Type.GetTypeFromProgID("Shell.Application");
            if (shellType is null)
            {
                return (null, []);
            }

            shell = Activator.CreateInstance(shellType);
            if (shell is null)
            {
                return (null, []);
            }

            dynamic dynamicShell = shell;
            shellWindows = dynamicShell.Windows();
            dynamic windows = shellWindows;
            var count = Convert.ToInt32(windows.Count, CultureInfo.InvariantCulture);
            for (var index = 0; index < count; index++)
            {
                dynamic candidate = windows.Item(index);
                if (new IntPtr(Convert.ToInt64(candidate.HWND, CultureInfo.InvariantCulture)) != windowHandle)
                {
                    Marshal.FinalReleaseComObject(candidate);
                    continue;
                }

                var path = Convert.ToString(candidate.Document.Folder.Self.Path, CultureInfo.InvariantCulture);
                var selectedNames = new List<string>();
                dynamic selectedItems = candidate.Document.SelectedItems();
                var selectedCount = Math.Min(8, Convert.ToInt32(selectedItems.Count, CultureInfo.InvariantCulture));
                for (var selectedIndex = 0; selectedIndex < selectedCount; selectedIndex++)
                {
                    dynamic selected = selectedItems.Item(selectedIndex);
                    var selectedPath = Convert.ToString(selected.Path, CultureInfo.InvariantCulture);
                    if (!string.IsNullOrWhiteSpace(selectedPath))
                    {
                        selectedNames.Add(selectedPath);
                    }

                    Marshal.FinalReleaseComObject(selected);
                }

                Marshal.FinalReleaseComObject(selectedItems);
                Marshal.FinalReleaseComObject(candidate);
                var locator = string.IsNullOrWhiteSpace(path) ? null : new LocatorInfo { Kind = "Folder path", Value = path };
                return (locator, selectedNames);
            }
        }
        catch (Exception exception) when (exception is COMException or InvalidCastException or InvalidOperationException)
        {
            return (null, []);
        }
        finally
        {
            ReleaseComObject(shellWindows);
            ReleaseComObject(shell);
        }

        return (null, []);
    }

    private IndicatedTargetInfo? TryReadPointerTarget(IntPtr windowHandle, NativeMethods.Point point)
    {
        try
        {
            var root = automation.FromHandle(windowHandle);
            var element = automation.FromPoint(new Point(point.X, point.Y));
            if (!IsWithinWindow(element, root) || element.Properties.IsPassword.ValueOrDefault)
            {
                return null;
            }

            var name = element.Properties.Name.ValueOrDefault;
            var bounds = element.Properties.BoundingRectangle.ValueOrDefault;
            var gridItem = element.Patterns.GridItem.PatternOrDefault;
            var controlType = FormatControlType(element.Properties.ControlType.ValueOrDefault);
            return new IndicatedTargetInfo
            {
                Name = Limit(name, 240),
                ControlType = controlType,
                AutomationId = Limit(element.Properties.AutomationId.ValueOrDefault, 120),
                Bounds = FormatBounds(bounds),
                Row = gridItem?.Row.ValueOrDefault,
                Column = gridItem?.Column.ValueOrDefault,
                RowSpan = gridItem?.RowSpan.ValueOrDefault,
                ColumnSpan = gridItem?.ColumnSpan.ValueOrDefault,
                Confidence = IsBroadControlType(controlType) ||
                    string.IsNullOrWhiteSpace(name) && gridItem is null
                        ? "limited"
                        : "medium",
            };
        }
        catch (Exception exception) when (exception is ElementNotAvailableException or InvalidOperationException or COMException)
        {
            return null;
        }
    }

    private IReadOnlyList<string> TryReadVisibleText(IntPtr windowHandle, NativeMethods.Point point)
    {
        try
        {
            var startedAt = Stopwatch.GetTimestamp();
            bool HasTime() => Stopwatch.GetElapsedTime(startedAt).TotalMilliseconds < MaximumVisibleTextMilliseconds;
            var collector = new VisibleTextCollector(
                MaximumVisibleTextItems,
                MaximumVisibleTextCharacters,
                MaximumVisibleTextItemCharacters);
            var root = automation.FromHandle(windowHandle);

            var hovered = automation.FromPoint(new Point(point.X, point.Y));
            if (IsWithinWindow(hovered, root) && !hovered.Properties.IsPassword.ValueOrDefault)
            {
                var current = hovered;
                for (var depth = 0; depth < 16 && current is not null; depth++)
                {
                    CollectElementText(current, collector, includeDocumentText: true);
                    if (current.Equals(root))
                    {
                        break;
                    }

                    current = controlViewWalker.GetParent(current);
                }
            }

            if (!collector.IsFull && HasTime())
            {
                var documentCondition = automation.ConditionFactory.ByControlType(ControlType.Document);
                foreach (var document in root
                    .FindAll(TreeScope.Descendants, documentCondition)
                    .Take(8))
                {
                    if (!HasTime()) break;
                    CollectElementText(document, collector, includeDocumentText: true);
                    if (collector.IsFull)
                    {
                        break;
                    }
                }

                // The hovered ancestor walk may already have read the same
                // document range. Once either path produced usable text, a
                // full control-tree scan only adds latency and duplicates.
                if (collector.Items.Count > 0)
                {
                    return collector.Items;
                }
            }

            var queue = new Queue<AutomationElement>();
            queue.Enqueue(root);
            for (var visited = 0;
                 queue.Count > 0 && visited < 800 && !collector.IsFull && HasTime();
                 visited++)
            {
                var element = queue.Dequeue();
                CollectElementText(
                    element,
                    collector,
                    includeDocumentText: element.Properties.ControlType.ValueOrDefault == ControlType.Document);

                var child = controlViewWalker.GetFirstChild(element);
                for (var siblings = 0; child is not null && siblings < 80; siblings++)
                {
                    queue.Enqueue(child);
                    child = controlViewWalker.GetNextSibling(child);
                }
            }

            return collector.Items;
        }
        catch (Exception exception) when (exception is ElementNotAvailableException or InvalidOperationException or COMException)
        {
            return [];
        }
    }

    private AccessibilityTreeInfo? TryReadAccessibilityContext(
        IntPtr windowHandle,
        NativeMethods.Point point,
        IReadOnlyList<AutomationElement> selectionElements,
        bool isBrowser)
    {
        try
        {
            var root = automation.FromHandle(windowHandle);
            AutomationElement? contextRoot = null;
            if (selectionElements.FirstOrDefault(element => IsWithinWindow(element, root)) is { } selectedElement)
            {
                contextRoot = FindNearbyContextRoot(root, selectedElement);
            }
            else if (isBrowser)
            {
                contextRoot = FindDocumentUnderPointer(root, point) ?? FindFirstDocument(root);
            }
            else
            {
                var hovered = automation.FromPoint(new Point(point.X, point.Y));
                if (IsWithinWindow(hovered, root))
                {
                    contextRoot = FindNearbyContextRoot(root, hovered);
                }
            }

            if (contextRoot is null)
            {
                return null;
            }

            var budget = new AccessibilityCaptureBudget(
                MaximumAccessibilityNodes,
                MaximumAccessibilityCharacters,
                MaximumAccessibilityDepth,
                TimeSpan.FromMilliseconds(MaximumAccessibilityMilliseconds));
            var capturedRoot = CaptureAccessibilityNode(contextRoot, budget, depth: 0);
            return capturedRoot is null
                ? null
                : new AccessibilityTreeInfo
                {
                    Source = "windows-uia-selection-first-control-view",
                    NodeCount = budget.NodeCount,
                    Truncated = budget.Truncated,
                    Roots = [capturedRoot],
                };
        }
        catch (Exception exception) when (exception is ElementNotAvailableException or InvalidOperationException or COMException)
        {
            return null;
        }
    }

    private AutomationElement FindNearbyContextRoot(AutomationElement root, AutomationElement element)
    {
        var current = element;
        for (var depth = 0; depth < 2; depth++)
        {
            var parent = controlViewWalker.GetParent(current);
            if (parent is null || parent.Equals(root))
            {
                break;
            }

            current = parent;
        }

        return current;
    }

    private AutomationElement? FindDocumentUnderPointer(
        AutomationElement root,
        NativeMethods.Point point)
    {
        var current = automation.FromPoint(new Point(point.X, point.Y));
        for (var depth = 0; current is not null && depth < 48; depth++)
        {
            if (current.Properties.ControlType.ValueOrDefault == ControlType.Document && IsWithinWindow(current, root))
            {
                return current;
            }

            current = controlViewWalker.GetParent(current);
        }

        return null;
    }

    private AutomationElement? FindFirstDocument(AutomationElement root)
    {
        var documentCondition = automation.ConditionFactory.ByControlType(ControlType.Document);
        return root.FindFirst(TreeScope.Descendants, documentCondition);
    }

    private AccessibilityNodeInfo? CaptureAccessibilityNode(
        AutomationElement element,
        AccessibilityCaptureBudget budget,
        int depth)
    {
        if (!budget.TryTakeNode(depth))
        {
            return null;
        }

        try
        {
            if (element.Properties.IsPassword.ValueOrDefault)
            {
                return new AccessibilityNodeInfo { Role = "Password" };
            }

            int? rowCount = null;
            int? columnCount = null;
            int? row = null;
            int? column = null;
            int? rowSpan = null;
            int? columnSpan = null;
            IReadOnlyList<string>? rowHeaders = null;
            IReadOnlyList<string>? columnHeaders = null;
            if (element.Patterns.Grid.PatternOrDefault is { } grid)
            {
                rowCount = grid.RowCount.ValueOrDefault;
                columnCount = grid.ColumnCount.ValueOrDefault;
            }

            if (element.Patterns.GridItem.PatternOrDefault is { } gridItem)
            {
                row = gridItem.Row.ValueOrDefault;
                column = gridItem.Column.ValueOrDefault;
                rowSpan = gridItem.RowSpan.ValueOrDefault;
                columnSpan = gridItem.ColumnSpan.ValueOrDefault;
            }

            if (element.Patterns.TableItem.PatternOrDefault is { } tableItem)
            {
                rowHeaders = ReadHeaderNames(tableItem.RowHeaderItems.ValueOrDefault ?? [], budget);
                columnHeaders = ReadHeaderNames(tableItem.ColumnHeaderItems.ValueOrDefault ?? [], budget);
            }

            string? value = null;
            if (element.Patterns.Value.PatternOrDefault is { } valuePattern)
            {
                value = budget.TakeText(valuePattern.Value.ValueOrDefault, 2_000);
            }

            bool? isSelected = null;
            if (element.Patterns.SelectionItem.PatternOrDefault is { } selectionItemPattern &&
                selectionItemPattern.IsSelected.ValueOrDefault)
            {
                isSelected = true;
            }

            var children = new List<AccessibilityNodeInfo>();
            if (depth < MaximumAccessibilityDepth && !budget.IsFull)
            {
                var child = controlViewWalker.GetFirstChild(element);
                for (var sibling = 0; child is not null && sibling < 120 && !budget.IsFull; sibling++)
                {
                    var capturedChild = CaptureAccessibilityNode(child, budget, depth + 1);
                    if (capturedChild is not null)
                    {
                        children.Add(capturedChild);
                    }

                    child = controlViewWalker.GetNextSibling(child);
                }

                if (child is not null)
                {
                    budget.MarkTruncated();
                }
            }
            else if (budget.IsFull || controlViewWalker.GetFirstChild(element) is not null)
            {
                budget.MarkTruncated();
            }

            return new AccessibilityNodeInfo
            {
                Role = FormatControlType(element.Properties.ControlType.ValueOrDefault) ?? "Unknown",
                Name = budget.TakeText(element.Properties.Name.ValueOrDefault, 1_000),
                Value = value,
                AutomationId = budget.TakeText(element.Properties.AutomationId.ValueOrDefault, 240),
                Bounds = FormatBounds(element.Properties.BoundingRectangle.ValueOrDefault),
                IsOffscreen = element.Properties.IsOffscreen.ValueOrDefault,
                IsSelected = isSelected,
                RowCount = rowCount,
                ColumnCount = columnCount,
                Row = row,
                Column = column,
                RowSpan = rowSpan,
                ColumnSpan = columnSpan,
                RowHeaders = rowHeaders,
                ColumnHeaders = columnHeaders,
                Children = children.Count == 0 ? null : children,
            };
        }
        catch (Exception exception) when (exception is ElementNotAvailableException or InvalidOperationException or COMException)
        {
            budget.MarkTruncated();
            return null;
        }
    }

    private static IReadOnlyList<string>? ReadHeaderNames(
        IReadOnlyList<AutomationElement> headers,
        AccessibilityCaptureBudget budget)
    {
        var names = headers
            .Take(32)
            .Select(header => budget.TakeText(header.Properties.Name.ValueOrDefault, 500))
            .Where(name => name is not null)
            .Cast<string>()
            .ToArray();
        return names.Length == 0 ? null : names;
    }

    private static Rectangle? ToScreenRectangle(Rectangle bounds)
    {
        if (bounds.IsEmpty || bounds.Width <= 0 || bounds.Height <= 0)
        {
            return null;
        }

        return bounds;
    }

    private static string? FormatBounds(Rectangle bounds)
    {
        var rectangle = ToScreenRectangle(bounds);
        return rectangle is null
            ? null
            : string.Create(
                CultureInfo.InvariantCulture,
                $"{rectangle.Value.X},{rectangle.Value.Y},{rectangle.Value.Width},{rectangle.Value.Height}");
    }

    private bool IsWithinWindow(AutomationElement element, AutomationElement root)
    {
        try
        {
            var elementProcessId = element.Properties.ProcessId.ValueOrDefault;
            var rootProcessId = root.Properties.ProcessId.ValueOrDefault;
            if (elementProcessId != 0 && elementProcessId == rootProcessId)
            {
                return true;
            }

            var current = element;
            for (var depth = 0; depth < 48 && current is not null; depth++)
            {
                if (current.Equals(root))
                {
                    return true;
                }

                current = rawViewWalker.GetParent(current);
            }
        }
        catch (Exception exception) when (exception is ElementNotAvailableException or InvalidOperationException or COMException)
        {
            return false;
        }

        return false;
    }

    private static void CollectElementText(
        AutomationElement element,
        VisibleTextCollector collector,
        bool includeDocumentText)
    {
        try
        {
            if (element.Properties.IsPassword.ValueOrDefault)
            {
                return;
            }

            collector.Add(element.Properties.Name.ValueOrDefault);
            if (element.Patterns.Value.PatternOrDefault is { } valuePattern)
            {
                collector.Add(valuePattern.Value.ValueOrDefault);
            }

            if (includeDocumentText && element.Patterns.Text.PatternOrDefault is { } textPattern)
            {
                collector.Add(textPattern.DocumentRange.GetText(MaximumDocumentTextCharacters));
            }
        }
        catch (Exception exception) when (exception is ElementNotAvailableException or InvalidOperationException or COMException)
        {
            // Accessibility trees change while pages render. Keep the text that
            // was already captured instead of failing the invocation.
        }
    }

    private static string ReadWindowText(IntPtr windowHandle)
    {
        var length = NativeMethods.GetWindowTextLength(windowHandle);
        if (length <= 0)
        {
            return string.Empty;
        }

        var buffer = new StringBuilder(Math.Min(length + 1, 2048));
        _ = NativeMethods.GetWindowText(windowHandle, buffer, buffer.Capacity);
        return Limit(buffer.ToString(), 1000) ?? string.Empty;
    }

    private static string FriendlyBrowserName(string processName) => processName.ToLowerInvariant() switch
    {
        "brave" => "Brave",
        "chrome" => "Google Chrome",
        "firefox" => "Mozilla Firefox",
        "msedge" => "Microsoft Edge",
        "opera" => "Opera",
        _ => processName,
    };

    private static string? FormatControlType(ControlType controlType) =>
        controlType == ControlType.Unknown ? null : controlType.ToString();

    private static bool IsSpecificPointerTarget(IndicatedTargetInfo? target) =>
        target is not null &&
        !IsBroadControlType(target.ControlType) &&
        (!string.IsNullOrWhiteSpace(target.Name) || target.Row is not null || target.Column is not null);

    private static bool IsBroadControlType(string? controlType) => controlType is null or
        "Unknown" or "Window" or "Pane" or "Document" or "Group" or "Custom";

    private static string AppendLimitation(string? existing, string addition) =>
        string.IsNullOrWhiteSpace(existing) ? addition : $"{existing} {addition}";

    private static string? Limit(string? value, int maximumLength)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            return null;
        }

        value = value.Trim();
        return value.Length <= maximumLength ? value : string.Concat(value.AsSpan(0, maximumLength - 1), "…");
    }

    private static void ReleaseComObject(object? value)
    {
        if (value is not null && Marshal.IsComObject(value))
        {
            _ = Marshal.FinalReleaseComObject(value);
        }
    }

    private sealed class VisibleTextCollector(
        int maximumItems,
        int maximumCharacters,
        int maximumItemCharacters = 400)
    {
        private readonly List<string> items = [];
        private readonly HashSet<string> seen = new(StringComparer.Ordinal);
        private int characters;

        public IReadOnlyList<string> Items => items;

        public bool IsFull => items.Count >= maximumItems || characters >= maximumCharacters;

        public void Add(string? value)
        {
            if (string.IsNullOrWhiteSpace(value) || IsFull)
            {
                return;
            }

            foreach (var line in value.Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
            {
                var cleaned = new string(line
                    .Select(character => char.IsControl(character) ? ' ' : character)
                    .ToArray());
                while (cleaned.Contains("  ", StringComparison.Ordinal))
                {
                    cleaned = cleaned.Replace("  ", " ", StringComparison.Ordinal);
                }

                cleaned = cleaned.Trim();
                if (cleaned.Length == 0 || !seen.Add(cleaned))
                {
                    continue;
                }

                var remaining = maximumCharacters - characters;
                if (remaining <= 0)
                {
                    return;
                }

                var allowed = Math.Min(maximumItemCharacters, remaining);
                var bounded = cleaned.Length <= allowed
                    ? cleaned
                    : allowed == 1
                        ? "…"
                        : string.Concat(cleaned.AsSpan(0, allowed - 1), "…");
                items.Add(bounded);
                characters += bounded.Length;
                if (IsFull)
                {
                    return;
                }
            }
        }
    }

    private sealed class AccessibilityCaptureBudget(
        int maximumNodes,
        int maximumCharacters,
        int maximumDepth,
        TimeSpan maximumDuration)
    {
        private int characters;
        private readonly long startedAt = Stopwatch.GetTimestamp();

        public int NodeCount { get; private set; }

        public bool Truncated { get; private set; }

        public bool IsFull => NodeCount >= maximumNodes ||
            characters >= maximumCharacters ||
            Stopwatch.GetElapsedTime(startedAt) >= maximumDuration;

        public bool TryTakeNode(int depth)
        {
            if (depth > maximumDepth || IsFull)
            {
                Truncated = true;
                return false;
            }

            NodeCount++;
            return true;
        }

        public string? TakeText(string? value, int maximumLength)
        {
            if (string.IsNullOrWhiteSpace(value) || characters >= maximumCharacters)
            {
                return null;
            }

            var cleaned = new string(value
                .Select(character => char.IsControl(character) || IsBidirectionalControl(character) ? ' ' : character)
                .ToArray());
            while (cleaned.Contains("  ", StringComparison.Ordinal))
            {
                cleaned = cleaned.Replace("  ", " ", StringComparison.Ordinal);
            }

            cleaned = cleaned.Trim();
            if (cleaned.Length == 0)
            {
                return null;
            }

            var allowed = Math.Min(maximumLength, maximumCharacters - characters);
            if (cleaned.Length > allowed)
            {
                cleaned = allowed == 1
                    ? "…"
                    : string.Concat(cleaned.AsSpan(0, allowed - 1), "…");
                Truncated = true;
            }

            characters += cleaned.Length;
            return cleaned;
        }

        public void MarkTruncated() => Truncated = true;

        private static bool IsBidirectionalControl(char character) =>
            character is >= '\u202A' and <= '\u202E' or >= '\u2066' and <= '\u2069';
    }

    private static class NativeMethods
    {
        internal const uint GetRoot = 2;

        [DllImport("user32.dll")]
        internal static extern IntPtr WindowFromPoint(Point point);

        [DllImport("user32.dll")]
        internal static extern IntPtr GetAncestor(IntPtr windowHandle, uint flags);

        [DllImport("user32.dll", EntryPoint = "GetWindowTextLengthW", CharSet = CharSet.Unicode)]
        internal static extern int GetWindowTextLength(IntPtr windowHandle);

        [DllImport("user32.dll", EntryPoint = "GetWindowTextW", CharSet = CharSet.Unicode)]
        internal static extern int GetWindowText(IntPtr windowHandle, StringBuilder text, int maximumCount);

        [DllImport("user32.dll")]
        internal static extern uint GetWindowThreadProcessId(IntPtr windowHandle, out uint processId);

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool GetCursorPos(out Point point);

        internal static object? GetActiveComObject(string programmaticId)
        {
            if (CLSIDFromProgID(programmaticId, out var classId) < 0 ||
                GetActiveObject(ref classId, IntPtr.Zero, out var instance) < 0)
            {
                return null;
            }

            return instance;
        }

        [DllImport("ole32.dll", CharSet = CharSet.Unicode)]
        private static extern int CLSIDFromProgID(string programmaticId, out Guid classId);

        [DllImport("oleaut32.dll", PreserveSig = true)]
        private static extern int GetActiveObject(
            ref Guid classId,
            IntPtr reserved,
            [MarshalAs(UnmanagedType.IUnknown)] out object? instance);

        [StructLayout(LayoutKind.Sequential)]
        internal struct Point
        {
            internal int X;
            internal int Y;
        }
    }
}
