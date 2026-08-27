using System.Diagnostics;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Text;
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
    private const int MaximumDocumentTextCharacters = 30_000;
    private const int MaximumAccessibilityNodes = 256;
    private const int MaximumAccessibilityCharacters = 20_000;
    private const int MaximumAccessibilityDepth = 24;
    internal sealed record CaptureResult(ContextSnapshot? Snapshot, bool PreservePrevious);

    private static readonly HashSet<string> BrowserProcesses = new(StringComparer.OrdinalIgnoreCase)
    {
        "brave", "chrome", "firefox", "msedge", "opera",
    };

    private readonly UIA3Automation automation = new()
    {
        ConnectionTimeout = TimeSpan.FromMilliseconds(1500),
        TransactionTimeout = TimeSpan.FromMilliseconds(3000),
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
        if (!NativeMethods.GetCursorPos(out var pointer))
        {
            return new CaptureResult(null, PreservePrevious: true);
        }

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
            return new CaptureResult(null, PreservePrevious: true);
        }

        _ = NativeMethods.GetWindowThreadProcessId(windowHandle, out var processId);
        if (processId == 0 || processId == Environment.ProcessId)
        {
            return new CaptureResult(null, PreservePrevious: true);
        }

        Process process;
        try
        {
            process = Process.GetProcessById(unchecked((int)processId));
        }
        catch (ArgumentException)
        {
            return new CaptureResult(null, PreservePrevious: true);
        }

        using (process)
        {
            var processName = process.ProcessName;
            var title = ReadWindowText(windowHandle);
            string surfaceKind;
            LocatorInfo? locator = null;
            IReadOnlyList<string> selection = TryReadSelectedText(windowHandle);
            string? limitation;
            string application;

            if (BrowserProcesses.Contains(processName))
            {
                surfaceKind = "Browser";
                application = FriendlyBrowserName(processName);
                locator = TryReadBrowserUrl(windowHandle);
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
            else
            {
                surfaceKind = "Window";
                application = CultureInfo.InvariantCulture.TextInfo.ToTitleCase(processName);
                limitation = null;
            }

            if (surfaceKind == "File Explorer" && locator is null && string.IsNullOrWhiteSpace(title))
            {
                return new CaptureResult(null, PreservePrevious: false);
            }

            var browserAccessibility = surfaceKind == "Browser"
                ? TryReadBrowserAccessibility(windowHandle, pointer)
                : null;
            var indicatedTarget = TryReadPointerTarget(windowHandle, pointer);
            var visibleText = TryReadVisibleText(windowHandle, pointer);
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
                VisibleText = visibleText,
                AccessibilityTree = browserAccessibility,
                IndicatedTarget = indicatedTarget,
                Confidence = locator is not null || visibleText.Count > 0 ? "high" : indicatedTarget is not null ? "medium" : "limited",
                Limitation = limitation,
            };
            return new CaptureResult(snapshot, PreservePrevious: false);
        }
    }

    private LocatorInfo? TryReadBrowserUrl(IntPtr windowHandle)
    {
        try
        {
            var root = automation.FromHandle(windowHandle);
            var editCondition = automation.ConditionFactory.ByControlType(ControlType.Edit);
            var edits = root.FindAll(TreeScope.Descendants, editCondition);
            foreach (var edit in edits.Take(80))
            {
                if (edit.Properties.IsPassword.ValueOrDefault)
                {
                    continue;
                }

                var value = edit.Patterns.Value.PatternOrDefault?.Value.ValueOrDefault?.Trim();
                var uri = ParseBrowserUrl(value);
                if (uri is not null)
                {
                    return new LocatorInfo { Kind = "URL", Value = uri.AbsoluteUri };
                }
            }
        }
        catch (Exception exception) when (exception is ElementNotAvailableException or InvalidOperationException or COMException)
        {
            return null;
        }

        return null;
    }

    internal IReadOnlyList<string> TryReadSelectedText(IntPtr windowHandle)
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
            candidates.AddRange(root
                .FindAll(TreeScope.Descendants, documentCondition)
                .Take(12));

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

            return selected.Items;
        }
        catch (Exception exception) when (exception is ElementNotAvailableException or InvalidOperationException or COMException)
        {
            return [];
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
            return new IndicatedTargetInfo
            {
                Name = Limit(name, 240),
                ControlType = FormatControlType(element.Properties.ControlType.ValueOrDefault),
                AutomationId = Limit(element.Properties.AutomationId.ValueOrDefault, 120),
                Bounds = FormatBounds(bounds),
                Confidence = string.IsNullOrWhiteSpace(name) ? "limited" : "medium",
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

            if (!collector.IsFull)
            {
                var documentCondition = automation.ConditionFactory.ByControlType(ControlType.Document);
                foreach (var document in root
                    .FindAll(TreeScope.Descendants, documentCondition)
                    .Take(8))
                {
                    CollectElementText(document, collector, includeDocumentText: true);
                    if (collector.IsFull)
                    {
                        break;
                    }
                }
            }

            var queue = new Queue<AutomationElement>();
            queue.Enqueue(root);
            for (var visited = 0; queue.Count > 0 && visited < 800 && !collector.IsFull; visited++)
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

    private AccessibilityTreeInfo? TryReadBrowserAccessibility(
        IntPtr windowHandle,
        NativeMethods.Point point)
    {
        try
        {
            var root = automation.FromHandle(windowHandle);
            var document = FindDocumentUnderPointer(root, point) ?? FindFirstDocument(root);
            if (document is null)
            {
                return null;
            }

            var budget = new AccessibilityCaptureBudget(
                MaximumAccessibilityNodes,
                MaximumAccessibilityCharacters,
                MaximumAccessibilityDepth);
            var capturedRoot = CaptureAccessibilityNode(document, budget, depth: 0);
            return capturedRoot is null
                ? null
                : new AccessibilityTreeInfo
                {
                    Source = "windows-uia-control-view",
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
        int maximumDepth)
    {
        private int characters;

        public int NodeCount { get; private set; }

        public bool Truncated { get; private set; }

        public bool IsFull => NodeCount >= maximumNodes || characters >= maximumCharacters;

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

        [StructLayout(LayoutKind.Sequential)]
        internal struct Point
        {
            internal int X;
            internal int Y;
        }
    }
}
