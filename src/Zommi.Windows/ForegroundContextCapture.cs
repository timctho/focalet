using System.Diagnostics;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Automation;
using Zommi.Core;

namespace Zommi.Windows;

internal sealed class ForegroundContextCapture
{
    internal sealed record CaptureResult(ContextSnapshot? Snapshot, bool PreservePrevious);

    private static readonly HashSet<string> BrowserProcesses = new(StringComparer.OrdinalIgnoreCase)
    {
        "brave", "chrome", "firefox", "msedge", "opera",
    };

    private static readonly HashSet<string> IgnoredProcesses = new(StringComparer.OrdinalIgnoreCase)
    {
        "cmd", "code", "conhost", "cursor", "devenv", "idea64", "openconsole", "powershell", "pwsh", "rider64", "windowsterminal", "wt", "zommi",
    };

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
            if (IgnoredProcesses.Contains(processName))
            {
                return new CaptureResult(null, PreservePrevious: true);
            }

            var title = ReadWindowText(windowHandle);
            string surfaceKind;
            LocatorInfo? locator = null;
            IReadOnlyList<string> selection = [];
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
                (locator, selection) = TryReadExplorer(windowHandle);
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

            var indicatedTarget = TryReadPointerTarget(windowHandle, pointer);
            var visibleText = TryReadVisibleText(windowHandle, pointer);
            return new CaptureResult(new ContextSnapshot
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
                IndicatedTarget = indicatedTarget,
                Confidence = locator is not null || visibleText.Count > 0 ? "high" : indicatedTarget is not null ? "medium" : "limited",
                Limitation = limitation,
            }, PreservePrevious: false);
        }
    }

    private static LocatorInfo? TryReadBrowserUrl(IntPtr windowHandle)
    {
        try
        {
            var root = AutomationElement.FromHandle(windowHandle);
            var editCondition = new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.Edit);
            var edits = root.FindAll(TreeScope.Descendants, editCondition);
            foreach (AutomationElement edit in edits.Cast<AutomationElement>().Take(80))
            {
                if (edit.Current.IsPassword || !edit.TryGetCurrentPattern(ValuePattern.Pattern, out var patternObject))
                {
                    continue;
                }

                var value = ((ValuePattern)patternObject).Current.Value?.Trim();
                if (Uri.TryCreate(value, UriKind.Absolute, out var uri) &&
                    (uri.Scheme.Equals(Uri.UriSchemeHttp, StringComparison.OrdinalIgnoreCase) ||
                     uri.Scheme.Equals(Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase) ||
                     uri.Scheme.Equals(Uri.UriSchemeFile, StringComparison.OrdinalIgnoreCase)))
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

    private static IndicatedTargetInfo? TryReadPointerTarget(IntPtr windowHandle, NativeMethods.Point point)
    {
        try
        {
            var root = AutomationElement.FromHandle(windowHandle);
            var element = AutomationElement.FromPoint(new System.Windows.Point(point.X, point.Y));
            if (!IsWithinWindow(element, root) || element.Current.IsPassword)
            {
                return null;
            }

            var bounds = element.Current.BoundingRectangle;
            return new IndicatedTargetInfo
            {
                Name = Limit(element.Current.Name, 240),
                ControlType = element.Current.ControlType?.ProgrammaticName?.Replace("ControlType.", string.Empty, StringComparison.Ordinal),
                AutomationId = Limit(element.Current.AutomationId, 120),
                Bounds = string.Create(CultureInfo.InvariantCulture, $"{bounds.X:0},{bounds.Y:0},{bounds.Width:0},{bounds.Height:0}"),
                Confidence = string.IsNullOrWhiteSpace(element.Current.Name) ? "limited" : "medium",
            };
        }
        catch (Exception exception) when (exception is ElementNotAvailableException or InvalidOperationException or COMException)
        {
            return null;
        }
    }

    private static IReadOnlyList<string> TryReadVisibleText(IntPtr windowHandle, NativeMethods.Point point)
    {
        try
        {
            var collector = new VisibleTextCollector(maximumItems: 32, maximumCharacters: 6000);
            var root = AutomationElement.FromHandle(windowHandle);

            var hovered = AutomationElement.FromPoint(new System.Windows.Point(point.X, point.Y));
            if (IsWithinWindow(hovered, root) && !hovered.Current.IsPassword)
            {
                var current = hovered;
                for (var depth = 0; depth < 16 && current is not null; depth++)
                {
                    CollectElementText(current, collector, includeDocumentText: true);
                    if (current.Equals(root))
                    {
                        break;
                    }

                    current = TreeWalker.ControlViewWalker.GetParent(current);
                }
            }

            var queue = new Queue<AutomationElement>();
            queue.Enqueue(root);
            for (var visited = 0; queue.Count > 0 && visited < 240 && !collector.IsFull; visited++)
            {
                var element = queue.Dequeue();
                CollectElementText(
                    element,
                    collector,
                    includeDocumentText: element.Current.ControlType == ControlType.Document);

                var child = TreeWalker.ControlViewWalker.GetFirstChild(element);
                for (var siblings = 0; child is not null && siblings < 80; siblings++)
                {
                    queue.Enqueue(child);
                    child = TreeWalker.ControlViewWalker.GetNextSibling(child);
                }
            }

            return collector.Items;
        }
        catch (Exception exception) when (exception is ElementNotAvailableException or InvalidOperationException or COMException)
        {
            return [];
        }
    }

    private static bool IsWithinWindow(AutomationElement element, AutomationElement root)
    {
        try
        {
            if (element.Current.ProcessId == root.Current.ProcessId)
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

                current = TreeWalker.RawViewWalker.GetParent(current);
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
            if (element.Current.IsPassword)
            {
                return;
            }

            collector.Add(element.Current.Name);
            if (element.TryGetCurrentPattern(ValuePattern.Pattern, out var valuePattern))
            {
                collector.Add(((ValuePattern)valuePattern).Current.Value);
            }

            if (includeDocumentText && element.TryGetCurrentPattern(TextPattern.Pattern, out var textPattern))
            {
                collector.Add(((TextPattern)textPattern).DocumentRange.GetText(4000));
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

    private sealed class VisibleTextCollector(int maximumItems, int maximumCharacters)
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

                var allowed = Math.Min(400, remaining);
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
