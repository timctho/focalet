using System.Diagnostics;
using System.Globalization;
using System.Net.WebSockets;
using System.Runtime.InteropServices;
using System.Text;
using FlaUI.Core.Definitions;
using FlaUI.UIA3;
using Focalet.Capture;

namespace Focalet.Windows;

internal sealed class BrowserObservationBridge : IDisposable
{
    private static BrowserConnectionPool Connections = new();
    private static readonly object ConnectionSettings = new();
    private static bool pageDetailsEnabled = true;
    internal static void SetPageDetailsEnabled(bool enabled)
    {
        lock (ConnectionSettings)
        {
            if (enabled == pageDetailsEnabled) return;
            pageDetailsEnabled = enabled;
            if (!enabled) { Connections.Dispose(); Connections = new(); }
        }
    }
    internal static void CloseConnections() { lock (ConnectionSettings) Connections.Dispose(); }

    private readonly nint window;
    private readonly int processId;
    private readonly BrowserDomSession session;
    private readonly CaptureRectangle viewport;
    private readonly string nativeTitle;

    private BrowserObservationBridge(nint window, int processId, BrowserDomSession session, CaptureRectangle viewport)
    {
        this.window = window;
        this.processId = processId;
        this.session = session;
        this.viewport = viewport;
        nativeTitle = NativeCaptureWindow.Title(window);
    }

    internal CaptureRectangle Viewport => viewport;

    public static BrowserObservationBridge? TryOpen(nint window, Action<string>? diagnostic = null,
        Action<string>? unavailable = null)
    {
        BrowserConnectionPool connections;
        bool enabled;
        lock (ConnectionSettings)
        {
            enabled = pageDetailsEnabled;
            connections = Connections;
        }
        var processId = NativeCaptureWindow.ProcessId(window);
        if (processId == 0) return null;
        string processName;
        try
        {
            using var process = Process.GetProcessById(processId);
            processName = process.ProcessName.ToLowerInvariant();
            if (processName is not ("chrome" or "msedge" or "brave" or "opera")) return null;
        }
        catch (ArgumentException) { return null; }
        if (!enabled)
        {
            unavailable?.Invoke("Full webpage details is turned off.");
            return null;
        }
        // Leave time for the first Chrome authorization; subsequent captures reuse the socket.
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(20));
        var attempted = false;
        foreach (var endpoint in Endpoints(processName))
        {
            attempted = true;
            BrowserDomSession? session = null;
            try
            {
                session = connections.OpenAsync(endpoint, processId,
                    title => NativeCaptureWindow.IsUniqueBrowserWindow(window, processId, title), timeout.Token).GetAwaiter().GetResult();
                if (session is null)
                {
                    diagnostic?.Invoke($"No unique visible tab matched native HWND {window}, PID {processId}, title {NativeCaptureWindow.Title(window)}.");
                    unavailable?.Invoke("The browser tab could not be matched unambiguously to this window.");
                    continue;
                }
                var stamp = session.StampAsync(timeout.Token).GetAwaiter().GetResult();
                var viewport = ReadViewport(window, stamp, diagnostic);
                if (viewport is null || !GeometryMatches(viewport, stamp))
                {
                    diagnostic?.Invoke($"Viewport mismatch: native={viewport}; CSS={stamp.Width}x{stamp.Height}; scale={stamp.ViewportScale}.");
                    unavailable?.Invoke("The browser's page coordinates could not be aligned with this window.");
                    session.Dispose();
                    continue;
                }
                return new BrowserObservationBridge(window, processId, session, viewport);
            }
            catch (Exception exception) when (IsUnavailable(exception))
            {
                diagnostic?.Invoke(exception.Message);
                unavailable?.Invoke(exception is OperationCanceledException
                    ? "The browser connection timed out. Check browser authorization before retrying."
                    : "The browser DOM connection is temporarily unavailable.");
                session?.Dispose();
            }
        }
        if (!attempted) unavailable?.Invoke("No authorized browser debugging connection was found.");
        return null;
    }

    public BrowserDomObservation Read(Point point, Rectangle? region = null)
    {
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(2));
        var stamp = Validate(timeout.Token);
        var x = (point.X - viewport.X) * stamp.Width / viewport.Width;
        var y = (point.Y - viewport.Y) * stamp.Height / viewport.Height;
        if (x < 0 || y < 0 || x >= stamp.Width || y >= stamp.Height)
        {
            // A shortcut over browser chrome can still carry a page selection
            // and URL, but it must not invent a point inside the page.
            x = -1;
            y = -1;
        }
        CaptureRectangle? rect = null;
        if (region is { } area)
        {
            var screenRegion = ToRectangle(area);
            if (!viewport.Contains(screenRegion)) throw new InvalidOperationException("The selected region crosses the browser content boundary.");
            rect = new CaptureRectangle((area.X - viewport.X) * stamp.Width / viewport.Width,
                (area.Y - viewport.Y) * stamp.Height / viewport.Height,
                area.Width * stamp.Width / viewport.Width, area.Height * stamp.Height / viewport.Height);
        }
        var result = session.ReadAsync(region is null ? "capture" : "region", x, y, rect, timeout.Token).GetAwaiter().GetResult();
        Validate(timeout.Token);
        return result;
    }

    public BrowserDomObservation? Pick(Point point)
    {
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(65));
        var stamp = Validate(timeout.Token);
        NativeCaptureWindow.Activate(window);
        session.BeginPickerAsync((point.X - viewport.X) * stamp.Width / viewport.Width,
            (point.Y - viewport.Y) * stamp.Height / viewport.Height, timeout.Token).GetAwaiter().GetResult();
        try
        {
            while (true)
            {
                Thread.Sleep(80);
                Application.DoEvents();
                var result = session.PollPickerAsync(timeout.Token).GetAwaiter().GetResult();
                if (!result.Done) continue;
                Validate(timeout.Token);
                return result.Observation;
            }
        }
        finally
        {
            try
            {
                using var cleanup = new CancellationTokenSource(TimeSpan.FromMilliseconds(400));
                session.CancelPickerAsync(cleanup.Token).GetAwaiter().GetResult();
            }
            catch (Exception exception) when (IsUnavailable(exception)) { }
        }
    }

    public bool StillMatches(BrowserDomObservation observation)
    {
        try
        {
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(1));
            var current = Validate(timeout.Token);
            return observation.Mode == "region"
                ? current.SameViewportAndDocument(observation.Stamp)
                : current == observation.Stamp;
        }
        catch (Exception exception) when (IsUnavailable(exception)) { return false; }
    }

    public BrowserRegionImage CaptureImage(Rectangle region)
    {
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(3));
        var stamp = Validate(timeout.Token);
        if (!viewport.Contains(ToRectangle(region))) throw new InvalidOperationException("The region crosses the browser viewport.");
        // The picker has left the desktop. Copy the visible physical pixels
        // without Chrome's screenshot command temporarily changing its surface.
        if (NativeCaptureWindow.ForRegion(region) != window)
            throw new InvalidOperationException("The selected browser region is covered.");
        var pixels = ScreenCapture.CapturePng(region);
        if (!Validate(timeout.Token).SameViewportAndDocument(stamp) || NativeCaptureWindow.ForRegion(region) != window)
            throw new InvalidOperationException("The page changed while capturing the image.");
        return new BrowserRegionImage(pixels, region.Width, region.Height, stamp);
    }

    public ContextSnapshot Snapshot(BrowserDomObservation observation, ContextSnapshot? fallback = null, Rectangle? region = null)
    {
        var now = DateTimeOffset.UtcNow;
        var selected = observation.Mode == "element" ? observation.Elements : [];
        var selection = ContextSelection.ForBrowser(observation.Context, fallback);
        var target = observation.Elements.FirstOrDefault();
        var nativeTarget = fallback?.IndicatedTarget;
        var useNativeTarget = observation.Mode == "capture" && nativeTarget is not null &&
            (target is null || string.IsNullOrWhiteSpace(target.Text) && string.IsNullOrWhiteSpace(target.Label) && string.IsNullOrWhiteSpace(target.Value));
        return (fallback ?? new ContextSnapshot
        {
            SnapshotId = Guid.NewGuid().ToString("D"), ObservedAtUtc = now, ExpiresAtUtc = now.AddSeconds(30),
            SurfaceKind = "Browser", Application = "Browser", ProcessName = "browser", Confidence = "high",
        }) with
        {
            WindowTitle = nativeTitle,
            Locator = new LocatorInfo { Kind = "URL", Value = observation.Stamp.Url },
            Selection = selection.Text,
            SelectionElements = selected.Count == 0 ? selection.Elements : selected.Select(element => new SelectedElementInfo
            {
                ControlType = element.Role, Name = element.Label, Value = element.Text,
                Bounds = FormatBounds(ToScreen(element.Bounds, observation.Stamp)),
            }).ToArray(),
            SelectionElementCount = selected.Count > 0 ? selected.Count : selection.ElementCount,
            VisibleText = [], AccessibilityTree = null,
            IndicatedTarget = useNativeTarget ? nativeTarget : target is null || region is not null ? null : new IndicatedTargetInfo
            {
                Name = target.Label ?? target.Text[..Math.Min(240, target.Text.Length)], ControlType = target.Role,
                Bounds = FormatBounds(ToScreen(target.Bounds, observation.Stamp)), Confidence = "high",
            },
            Source = NativeCaptureWindow.Source(window, selection.IncludesNativeSelection || useNativeTarget ? "browser-dom+windows-uia" : "browser-dom") with
            {
                Provider = selection.IncludesNativeSelection || useNativeTarget ? "browser-dom+windows-uia" : "browser-dom", NativeWindowId = window.ToString(CultureInfo.InvariantCulture),
                ProcessId = processId, BrowserWindowId = session.WindowId, TabId = session.TabId,
                WindowBounds = NativeCaptureWindow.Bounds(window),
                FrameId = session.FrameId, DocumentId = $"{session.LoaderId}:{observation.Stamp.DocumentId}",
            },
            Dom = observation.Context, Confidence = "high", Limitation = observation.Limitation,
            Region = region is not { } area ? null : new RegionAlignment
            {
                Status = "aligned", ScreenBounds = ToRectangle(area),
                Mapping = new CaptureMapping
                {
                    CoordinateSpace = "browser-viewport-css-pixels",
                    ScreenBounds = viewport,
                    ViewportBounds = new CaptureRectangle(0, 0, observation.Stamp.Width, observation.Stamp.Height),
                    ImageBounds = new CaptureRectangle(0, 0, area.Width, area.Height),
                },
            },
        };
    }

    public CapturedElement RegionElement(DomElementContext element, BrowserDocumentStamp stamp, Rectangle region, int imageWidth, int imageHeight)
    {
        var screen = ToRectangle(region);
        CaptureRectangle Map(CaptureRectangle bounds) => RegionContextGeometry.ToImage(ToScreen(bounds, stamp), screen, imageWidth, imageHeight);
        return new CapturedElement
        {
            Id = element.Id!, ParentId = element.ParentId, Provider = "browser-dom", NativeIds = element.NativeIds,
            Role = element.Role, Name = element.Label, Text = element.Text, Value = element.Value,
            Description = element.Description, Href = element.Href, State = element.State,
            Bounds = Map(element.Bounds), VisibleBounds = Map(element.VisibleBounds ?? element.Bounds),
            Relation = element.Relation ?? "inside", Truncated = element.Truncated,
        };
    }

    private BrowserDocumentStamp Validate(CancellationToken cancellationToken)
    {
        session.ValidateAsync(cancellationToken).GetAwaiter().GetResult();
        var stamp = session.StampAsync(cancellationToken).GetAwaiter().GetResult();
        if (NativeCaptureWindow.Title(window) != nativeTitle || NativeCaptureWindow.ProcessId(window) != processId ||
            ReadViewport(window, stamp) != viewport || !GeometryMatches(viewport, stamp))
            throw new InvalidOperationException("The browser viewport changed. Select the content again.");
        return stamp;
    }

    private CaptureRectangle ToScreen(CaptureRectangle bounds, BrowserDocumentStamp stamp) => new(
        viewport.X + bounds.X * viewport.Width / stamp.Width, viewport.Y + bounds.Y * viewport.Height / stamp.Height,
        bounds.Width * viewport.Width / stamp.Width, bounds.Height * viewport.Height / stamp.Height);

    private static bool GeometryMatches(CaptureRectangle viewport, BrowserDocumentStamp stamp) =>
        viewport.IsValid && stamp.Width > 0 && stamp.Height > 0 && stamp.ViewportScale == 1 &&
        stamp.ViewportX == 0 && stamp.ViewportY == 0 &&
        Math.Abs(viewport.Width / stamp.Width - viewport.Height / stamp.Height) * Math.Max(stamp.Width, stamp.Height) <= 2.5;

    private static CaptureRectangle? ReadViewport(nint window, BrowserDocumentStamp stamp, Action<string>? diagnostic = null)
    {
        var windowBounds = NativeCaptureWindow.Bounds(window);
        var renderViews = NativeCaptureWindow.RenderViewBounds(window)
            .Where(rect => windowBounds.Contains(rect) && GeometryMatches(rect, stamp)).ToArray();
        if (renderViews.Length == 1) return renderViews[0];
        using var automation = new UIA3Automation
        {
            ConnectionTimeout = TimeSpan.FromMilliseconds(300), TransactionTimeout = TimeSpan.FromMilliseconds(400),
        };
        var root = automation.FromHandle(window);
        var exposed = root.FindAllDescendants(automation.ConditionFactory.ByControlType(ControlType.Document));
        var documents = exposed
            .Where(element => element.Properties.Name.ValueOrDefault == stamp.Title)
            .Select(element => ToRectangle(element.Properties.BoundingRectangle.ValueOrDefault))
            .Where(rect => rect.IsValid && windowBounds.Contains(rect)).Distinct().ToArray();
        if (documents.Length != 1)
            diagnostic?.Invoke($"Native render views={renderViews.Length}; UIA documents={exposed.Length}; exact document rectangles={documents.Length}; native window={windowBounds}.");
        return documents.Length == 1 ? documents[0] : null;
    }

    internal static IEnumerable<Uri> Endpoints(string processName) => BrowserDiscovery.Endpoints(processName);

    internal static object ConnectionStatus(bool enabled, string? reconnectBrowser = null)
    {
        SetPageDetailsEnabled(enabled);
        BrowserConnectionPool connections;
        lock (ConnectionSettings) connections = Connections;
        var manager = new BrowserConnections(connections);
        if (reconnectBrowser is not null)
        {
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(20));
            return manager.ReconnectAsync(reconnectBrowser, enabled, timeout.Token).GetAwaiter().GetResult();
        }
        return new { browsers = manager.StatusAsync(enabled).GetAwaiter().GetResult() };
    }

    internal static bool IsUnavailable(Exception exception) => exception is OperationCanceledException or TimeoutException or IOException or
        WebSocketException or HttpRequestException or InvalidOperationException or System.Text.Json.JsonException or
        COMException or FlaUI.Core.Exceptions.ElementNotAvailableException or ArgumentException or KeyNotFoundException or FormatException;
    internal static CaptureRectangle ToRectangle(Rectangle rectangle) => new(rectangle.X, rectangle.Y, rectangle.Width, rectangle.Height);
    internal static string FormatBounds(CaptureRectangle bounds) => FormattableString.Invariant($"{bounds.X:0.##},{bounds.Y:0.##} {bounds.Width:0.##}x{bounds.Height:0.##}");
    public void Dispose() => session.Dispose();
}

internal static class NativeCaptureWindow
{
    public static ObservationSource Source(nint window, string provider)
    {
        var processId = ProcessId(window);
        string? processPath = null;
        DateTimeOffset? startedAt = null;
        try
        {
            using var process = System.Diagnostics.Process.GetProcessById(processId);
            processPath = process.MainModule?.FileName;
            startedAt = process.StartTime.ToUniversalTime();
        }
        catch (Exception exception) when (exception is ArgumentException or InvalidOperationException or System.ComponentModel.Win32Exception) { }
        return new ObservationSource
        {
            Provider = provider, Platform = "windows", HostName = Environment.MachineName,
            NativeWindowId = window.ToString(CultureInfo.InvariantCulture), ProcessId = processId,
            ProcessPath = processPath, ProcessStartedAtUtc = startedAt, WindowBounds = Bounds(window),
        };
    }

    public static nint BeneathOverlay(Point point, uint excludedProcessId)
    {
        nint result = 0;
        EnumWindows((window, _) =>
        {
            var process = ProcessId(window);
            if (!IsWindowVisible(window) || IsIconic(window) || process == Environment.ProcessId || process == excludedProcessId)
                return true;
            if (DwmGetWindowAttribute(window, 14, out int cloaked, sizeof(int)) == 0 && cloaked != 0) return true;
            var bounds = VisibleBounds(window);
            if (point.X < bounds.X || point.X >= bounds.Right || point.Y < bounds.Y || point.Y >= bounds.Bottom) return true;
            result = window;
            return false;
        }, 0);
        return result;
    }
    public static int ProcessId(nint window) { GetWindowThreadProcessId(window, out var id); return checked((int)id); }
    public static string Title(nint window)
    {
        var buffer = new StringBuilder(4096); GetWindowText(window, buffer, buffer.Capacity); return buffer.ToString();
    }
    public static CaptureRectangle Bounds(nint window) => GetWindowRect(window, out var bounds)
        ? new(bounds.Left, bounds.Top, bounds.Right - bounds.Left, bounds.Bottom - bounds.Top) : new(0, 0, 0, 0);
    public static CaptureRectangle VisibleBounds(nint window) =>
        DwmGetWindowAttribute(window, 9, out WindowRect bounds, Marshal.SizeOf<WindowRect>()) == 0 &&
        bounds.Right > bounds.Left && bounds.Bottom > bounds.Top
            ? new(bounds.Left, bounds.Top, bounds.Right - bounds.Left, bounds.Bottom - bounds.Top)
            : Bounds(window);
    public static Rectangle CaptureBounds(nint window)
    {
        var bounds = VisibleBounds(window);
        var visible = Rectangle.Intersect(Rectangle.FromLTRB((int)bounds.X, (int)bounds.Y,
            (int)bounds.Right, (int)bounds.Bottom), SystemInformation.VirtualScreen);
        // Snapped/maximized frames can extend a few pixels under the taskbar.
        // Preserve multi-monitor windows; coverage is still checked afterwards.
        var screen = Screen.AllScreens.FirstOrDefault(screen => screen.Bounds.Contains(visible));
        return screen is null ? visible : Rectangle.Intersect(visible, screen.WorkingArea);
    }
    public static nint At(Point point) => GetAncestor(WindowFromPoint(point), 2);
    public static void Activate(nint window) { BringWindowToTop(window); SetForegroundWindow(window); }
    public static IReadOnlyList<CaptureRectangle> RenderViewBounds(nint window)
    {
        var rectangles = new List<CaptureRectangle>();
        EnumChildWindows(window, (child, _) =>
        {
            var name = new StringBuilder(128);
            GetClassName(child, name, name.Capacity);
            if (IsWindowVisible(child) && name.ToString() == "Chrome_RenderWidgetHostHWND")
            {
                var bounds = Bounds(child);
                if (bounds.IsValid) rectangles.Add(bounds);
            }
            return true;
        }, 0);
        return rectangles.Distinct().ToArray();
    }
    public static bool IsUniqueBrowserWindow(nint expected, int processId, string documentTitle)
    {
        if (string.IsNullOrWhiteSpace(documentTitle) || ProcessId(expected) != processId) return false;
        bool Matches(string title) => title == documentTitle || title.StartsWith(documentTitle + " - ", StringComparison.Ordinal) ||
            title.StartsWith(documentTitle + " – ", StringComparison.Ordinal);
        if (!Matches(Title(expected))) return false;
        var matches = new List<nint>();
        EnumWindows((window, _) =>
        {
            if (IsWindowVisible(window) && ProcessId(window) == processId && Matches(Title(window))) matches.Add(window);
            return true;
        }, 0);
        return matches.Count == 1 && matches[0] == expected;
    }

    // The region must belong to one unobscured native window, not merely have its center in it.
    public static nint ForRegion(Rectangle region)
    {
        var area = BrowserObservationBridge.ToRectangle(region);
        nint result = 0;
        EnumWindows((window, _) =>
        {
            if (!IsWindowVisible(window) || IsIconic(window) || ProcessId(window) == Environment.ProcessId) return true;
            if (DwmGetWindowAttribute(window, 14, out int cloaked, sizeof(int)) == 0 && cloaked != 0) return true;
            var bounds = VisibleBounds(window);
            if (!bounds.Intersects(area)) return true;
            if (bounds.Contains(area)) result = window;
            else if (Environment.GetEnvironmentVariable("FOCALET_CAPTURE_DIAGNOSTICS") == "1")
                Console.Error.WriteLine($"Region coverage: intersecting HWND={window}, PID={ProcessId(window)}, frame={bounds}, region={area}");
            return false;
        }, 0);
        return result;
    }

    private delegate bool EnumWindowCallback(nint window, nint parameter);
    [StructLayout(LayoutKind.Sequential)] private struct WindowRect { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumWindowCallback callback, nint parameter);
    [DllImport("user32.dll")] private static extern bool EnumChildWindows(nint parent, EnumWindowCallback callback, nint parameter);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetClassName(nint window, StringBuilder text, int count);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(nint window);
    [DllImport("user32.dll")] private static extern bool IsIconic(nint window);
    [DllImport("dwmapi.dll")] private static extern int DwmGetWindowAttribute(nint window, int attribute, out int value, int size);
    [DllImport("dwmapi.dll")] private static extern int DwmGetWindowAttribute(nint window, int attribute, out WindowRect value, int size);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(nint window, out uint processId);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetWindowText(nint window, StringBuilder text, int count);
    [DllImport("user32.dll")] private static extern bool GetWindowRect(nint window, out WindowRect bounds);
    [DllImport("user32.dll")] private static extern nint WindowFromPoint(Point point);
    [DllImport("user32.dll")] private static extern nint GetAncestor(nint window, uint flags);
    [DllImport("user32.dll")] private static extern bool SetForegroundWindow(nint window);
    [DllImport("user32.dll")] private static extern bool BringWindowToTop(nint window);
}
