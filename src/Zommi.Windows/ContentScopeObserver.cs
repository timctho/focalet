using System.Diagnostics;
using System.Runtime.InteropServices;
using FlaUI.Core;
using FlaUI.Core.AutomationElements;
using FlaUI.Core.Definitions;
using FlaUI.UIA3;
using FlaUI.UIA3.Extensions;
using Zommi.Capture;
using UIA = Interop.UIAutomationClient;

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
            // Cache geometry, but obtain the target from the application's hit
            // test. Accessibility child order is not the visual stacking order.
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
            var root = automation.FromHandle(window);
            var element = HitTest(automation, cache, window, point) ?? UnambiguousElement(root, point);
            var walker = automation.TreeWalkerFactory.GetControlViewWalker();
            var started = Stopwatch.GetTimestamp();
            var belongsToWindow = false;
            for (var depth = 0; element is not null && depth < 32 && IsCurrent(version) &&
                 Stopwatch.GetElapsedTime(started).TotalMilliseconds < 250; depth++)
            {
                if (element.Properties.IsPassword.ValueOrDefault) { outlines.Clear(); break; }
                if (element.Equals(root)) { belongsToWindow = true; break; }
                var rectangle = element.Properties.BoundingRectangle.ValueOrDefault;
                if (!element.Properties.IsOffscreen.ValueOrDefault && rectangle.Contains(point) &&
                    rectangle.Width > 3 && rectangle.Height > 3 &&
                    BrowserObservationBridge.ToRectangle(rectangle) != area &&
                    area.Contains(BrowserObservationBridge.ToRectangle(rectangle)) &&
                    !outlines.Any(outline => outline.Bounds == rectangle))
                {
                    var name = element.Properties.Name.ValueOrDefault ?? "";
                    if (name.Length > 90) name = name[..90] + "…";
                    outlines.Add(new(rectangle, $"{element.Properties.ControlType.ValueOrDefault}: {name}"));
                }
                element = walker.GetParent(element);
            }
            // A provider returning an object from another window must not move
            // this outline to that other surface, even if their bounds overlap.
            if (!belongsToWindow) outlines.Clear();
        }
        catch (Exception exception) when (BrowserObservationBridge.IsUnavailable(exception)) { outlines.Clear(); }
        return new(version, point, window, bounds, title, outlines);
    }

    private static AutomationElement? HitTest(UIA3Automation automation, CacheRequest cache, nint window, Point point)
    {
        try
        {
            var accessibleId = typeof(UIA.IAccessible).GUID;
            if (AccessibleObjectFromWindow(window, 0xFFFFFFFC, ref accessibleId, out var accessible) < 0 || accessible is null)
                return null;
            // accHitTest is relative to this source window. Unlike desktop
            // ElementFromPoint it can see through Zommi's input-owning overlay.
            for (var depth = 0; depth < 32; depth++)
            {
                var hit = accessible.accHitTest(point.X, point.Y);
                if (hit is UIA.IAccessible child && !ReferenceEquals(child, accessible))
                {
                    accessible = child;
                    continue;
                }
                if (hit is not int && hit is not UIA.IAccessible) return null;
                var childId = hit is int id ? id : 0;
                return automation.WrapNativeElement(automation.NativeAutomation.ElementFromIAccessibleBuildCache(
                    accessible, childId, cache.ToNative(automation)));
            }
        }
        catch (Exception exception) when (BrowserObservationBridge.IsUnavailable(exception)) { }
        return null;
    }

    private static AutomationElement UnambiguousElement(AutomationElement root, Point point)
    {
        // Some UIA-only providers do not implement native hit testing. Descend
        // only when there is one candidate; never guess the front object from
        // the order of overlapping accessibility siblings.
        var element = root;
        var started = Stopwatch.GetTimestamp();
        for (var depth = 0; depth < 32 && Stopwatch.GetElapsedTime(started).TotalMilliseconds < 120; depth++)
        {
            var candidates = element.FindAllChildren().Take(512).Where(candidate =>
                !candidate.Properties.IsOffscreen.ValueOrDefault &&
                candidate.Properties.BoundingRectangle.ValueOrDefault.Contains(point)).Take(2).ToArray();
            if (candidates.Length != 1) break;
            element = candidates[0];
            if (element.Properties.IsPassword.ValueOrDefault) break;
        }
        return element;
    }

    [DllImport("oleacc.dll")]
    private static extern int AccessibleObjectFromWindow(nint window, uint objectId, ref Guid interfaceId,
        [MarshalAs(UnmanagedType.Interface)] out UIA.IAccessible? accessible);

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
