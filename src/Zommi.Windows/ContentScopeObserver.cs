using System.Diagnostics;
using FlaUI.Core;
using FlaUI.Core.Definitions;
using FlaUI.UIA3;
using Zommi.Capture;

namespace Zommi.Windows;

internal sealed record ContentOutline(Rectangle Bounds, string Label);
internal sealed record ContentObservation(long Version, Point Point, nint Window,
    CaptureRectangle? WindowBounds, string WindowTitle, IReadOnlyList<ContentOutline> Outlines);

/// <summary>Owns UIA on one background MTA. Only geometry crosses to the UI;
/// pointer requests replace one another instead of building a work queue.</summary>
internal sealed class ContentScopeObserver : IDisposable
{
    private readonly object gate = new();
    private readonly uint excludedProcessId;
    private readonly Action<ContentObservation> completed;
    private (long Version, Point Point)? pending;
    private long latestVersion;
    private bool stopped;

    public ContentScopeObserver(uint excludedProcessId, Action<ContentObservation> completed)
    {
        this.excludedProcessId = excludedProcessId;
        this.completed = completed;
        var worker = new Thread(Run) { IsBackground = true, Name = "Zommi content outlines" };
        worker.SetApartmentState(ApartmentState.MTA);
        worker.Start();
    }

    public void Request(long version, Point point)
    {
        lock (gate)
        {
            if (stopped) return;
            latestVersion = version;
            pending = (version, point);
            Monitor.Pulse(gate);
        }
    }

    private bool IsCurrent(long version)
    {
        lock (gate) return !stopped && latestVersion == version;
    }

    private void Run()
    {
        // COM initialization, requests, and disposal all stay on this thread.
        using var automation = new UIA3Automation
        {
            ConnectionTimeout = TimeSpan.FromMilliseconds(150),
            TransactionTimeout = TimeSpan.FromMilliseconds(200),
        };
        while (true)
        {
            (long Version, Point Point) request;
            lock (gate)
            {
                while (!stopped && pending is null) Monitor.Wait(gate);
                if (stopped) return;
                request = pending!.Value;
                pending = null;
            }
            var result = Read(automation, request.Version, request.Point);
            if (IsCurrent(request.Version)) completed(result);
        }
    }

    private ContentObservation Read(UIA3Automation automation, long version, Point point)
    {
        var window = NativeCaptureWindow.BeneathOverlay(point, excludedProcessId);
        var bounds = window == 0 ? null : NativeCaptureWindow.Bounds(window);
        var title = window == 0 ? "" : NativeCaptureWindow.Title(window);
        var outlines = new List<ContentOutline>();
        if (bounds is not { IsValid: true } area) return new(version, point, window, bounds, title, outlines);
        try
        {
            // Batch the properties for each level in one provider call. Reading
            // each sibling's rectangle separately costs many cross-process calls.
            var cache = new CacheRequest
            {
                TreeScope = TreeScope.Element,
                // Cached geometry alone cannot perform the next child query.
                AutomationElementMode = AutomationElementMode.Full,
            };
            cache.Add(automation.PropertyLibrary.Element.BoundingRectangle);
            cache.Add(automation.PropertyLibrary.Element.IsOffscreen);
            cache.Add(automation.PropertyLibrary.Element.IsPassword);
            cache.Add(automation.PropertyLibrary.Element.ControlType);
            cache.Add(automation.PropertyLibrary.Element.Name);
            using var active = cache.Activate();
            var element = automation.FromHandle(window);
            var started = Stopwatch.GetTimestamp();
            for (var depth = 0; depth < 32 && IsCurrent(version) &&
                 Stopwatch.GetElapsedTime(started).TotalMilliseconds < 250; depth++)
            {
                if (element.Properties.IsPassword.ValueOrDefault) break;
                var rectangle = element.Properties.BoundingRectangle.ValueOrDefault;
                if (rectangle.Width > 3 && rectangle.Height > 3 &&
                    BrowserObservationBridge.ToRectangle(rectangle) != area &&
                    area.Contains(BrowserObservationBridge.ToRectangle(rectangle)) &&
                    !outlines.Any(outline => outline.Bounds == rectangle))
                {
                    var name = element.Properties.Name.ValueOrDefault ?? "";
                    if (name.Length > 90) name = name[..90] + "…";
                    outlines.Add(new(rectangle, $"{element.Properties.ControlType.ValueOrDefault}: {name}"));
                }
                var child = element.FindAllChildren().Take(512).FirstOrDefault(candidate =>
                    !candidate.Properties.IsOffscreen.ValueOrDefault &&
                    candidate.Properties.BoundingRectangle.ValueOrDefault.Contains(point));
                if (child is null) break;
                element = child;
            }
        }
        catch (Exception exception) when (BrowserObservationBridge.IsUnavailable(exception)) { }
        // The descent already gives the ancestor chain; no second series of
        // remote parent/ownership queries is needed for a preview outline.
        outlines.Reverse();
        return new(version, point, window, bounds, title, outlines);
    }

    public void Dispose()
    {
        lock (gate)
        {
            stopped = true;
            pending = null;
            Monitor.Pulse(gate);
        }
        // Never block closing/dragging on a slow external accessibility provider.
    }
}
