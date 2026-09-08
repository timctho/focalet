using System.Diagnostics;
using System.Globalization;
using System.Text.Json;
using FlaUI.Core.AutomationElements;
using FlaUI.Core.Definitions;
using FlaUI.UIA3;
using Zommi.Capture;

namespace Zommi.Windows;

internal static class RegionContextCapture
{
    public static RegionSelectionResult Capture(Rectangle region)
    {
        var window = NativeCaptureWindow.ForRegion(region);
        if (window == 0) return ImageOnly(region, "The region spans windows or its source could not be confirmed.");
        var title = NativeCaptureWindow.Title(window);
        var windowBounds = NativeCaptureWindow.Bounds(window);
        try
        {
            using var browser = BrowserObservationBridge.TryOpen(window);
            if (browser is not null && browser.Viewport.Contains(BrowserObservationBridge.ToRectangle(region)))
            {
                var observation = browser.Read(new Point(region.X + region.Width / 2, region.Y + region.Height / 2), region);
                var image = browser.CaptureImage(region);
                var png = image.Png;
                if (NativeCaptureWindow.ForRegion(region) != window || image.Stamp != observation.Stamp || !browser.StillMatches(observation))
                    return ImageOnly(region, "The page changed while the image was captured.", png);
                var snapshot = browser.Snapshot(observation, region: region);
                snapshot = snapshot with
                {
                    Region = snapshot.Region! with
                    {
                        Mapping = snapshot.Region.Mapping! with
                        {
                            ImageBounds = new CaptureRectangle(0, 0, image.Width, image.Height),
                        },
                    },
                };
                if (!observation.Elements.Any(element => !string.IsNullOrWhiteSpace(element.Text) ||
                    !string.IsNullOrWhiteSpace(element.Value) || !string.IsNullOrWhiteSpace(element.Label) ||
                    !string.IsNullOrWhiteSpace(element.Href)))
                {
                    var reason = observation.Limitation ?? "No complete text or accessible object was exposed inside this region.";
                    snapshot = snapshot with
                    {
                        Dom = null, Confidence = "limited", Limitation = reason,
                        Region = snapshot.Region with { Status = "image-only", Reason = reason },
                    };
                }
                return new RegionSelectionResult(region, png, snapshot, snapshot.Region);
            }

            var before = ReadUiaRegion(window, region);
            var pixels = ScreenCapture.CapturePng(region);
            var after = ReadUiaRegion(window, region);
            if (before.Count == 0)
                return ImageOnly(region, "No complete accessible text or named object was exposed inside this region. Try enclosing the whole item.", pixels);
            if (NativeCaptureWindow.ForRegion(region) != window ||
                NativeCaptureWindow.Title(window) != title || NativeCaptureWindow.Bounds(window) != windowBounds ||
                JsonSerializer.Serialize(before) != JsonSerializer.Serialize(after))
                return ImageOnly(region, "The window or its accessible content changed while the image was captured.", pixels);
            var now = DateTimeOffset.UtcNow;
            var screenBounds = BrowserObservationBridge.ToRectangle(region);
            var alignment = new RegionAlignment
            {
                Status = "aligned", ScreenBounds = screenBounds,
                Mapping = new CaptureMapping
                {
                    CoordinateSpace = "desktop-physical-pixels", ScreenBounds = screenBounds,
                    ViewportBounds = screenBounds, ImageBounds = new CaptureRectangle(0, 0, region.Width, region.Height),
                },
            };
            var context = new ContextSnapshot
            {
                SnapshotId = Guid.NewGuid().ToString("D"), ObservedAtUtc = now, ExpiresAtUtc = now.AddSeconds(30),
                SurfaceKind = "Image region", Application = "Window", ProcessName = "window", WindowTitle = title,
                Source = new ObservationSource
                {
                    Provider = "windows-uia-region", NativeWindowId = window.ToString(CultureInfo.InvariantCulture),
                    ProcessId = NativeCaptureWindow.ProcessId(window),
                },
                AccessibilityTree = new AccessibilityTreeInfo { Source = "windows-uia-region", Roots = before, NodeCount = before.Count },
                Region = alignment, Confidence = "medium",
                Limitation = "Only fully enclosed accessible elements are included; partially clipped text and pixels without accessibility data remain in the image.",
            };
            return new RegionSelectionResult(region, pixels, context, alignment);
        }
        catch (Exception exception) when (BrowserObservationBridge.IsUnavailable(exception))
        {
            return ImageOnly(region, "The source could not be aligned with this image. The selected image is attached.");
        }
    }

    private static RegionSelectionResult ImageOnly(Rectangle region, string reason, byte[]? png = null) => new(
        region, png ?? ScreenCapture.CapturePng(region), Alignment: new RegionAlignment
        {
            Status = "image-only", Reason = reason, ScreenBounds = BrowserObservationBridge.ToRectangle(region),
        });

    private static IReadOnlyList<AccessibilityNodeInfo> ReadUiaRegion(nint window, Rectangle region)
    {
        using var automation = new UIA3Automation
        {
            ConnectionTimeout = TimeSpan.FromMilliseconds(300), TransactionTimeout = TimeSpan.FromMilliseconds(400),
        };
        var root = automation.FromHandle(window);
        var area = BrowserObservationBridge.ToRectangle(region);
        var nodes = new List<AccessibilityNodeInfo>();
        var queue = new Queue<AutomationElement>();
        queue.Enqueue(root);
        var start = Stopwatch.GetTimestamp();
        var visited = 0;
        var characters = 0;
        while (queue.Count > 0 && visited++ < 800 && nodes.Count < 128 && characters < 24000 &&
               Stopwatch.GetElapsedTime(start).TotalMilliseconds < 500)
        {
            var element = queue.Dequeue();
            if (element.Properties.IsPassword.ValueOrDefault || element.Properties.IsOffscreen.ValueOrDefault) continue;
            var bounds = BrowserObservationBridge.ToRectangle(element.Properties.BoundingRectangle.ValueOrDefault);
            if (!bounds.Intersects(area)) continue;
            var type = element.Properties.ControlType.ValueOrDefault;
            if (area.Contains(bounds) && type is ControlType.Text or ControlType.Edit or ControlType.Button or
                ControlType.CheckBox or ControlType.RadioButton or ControlType.Hyperlink or ControlType.Image)
            {
                var name = element.Properties.Name.ValueOrDefault;
                var value = type == ControlType.Edit ? element.Patterns.Value.PatternOrDefault?.Value.ValueOrDefault : null;
                if (!string.IsNullOrWhiteSpace(name) || !string.IsNullOrWhiteSpace(value))
                {
                    var length = (name?.Length ?? 0) + (value?.Length ?? 0);
                    if (length + characters > 24000) break;
                    nodes.Add(new AccessibilityNodeInfo
                    {
                        Role = type.ToString(), Name = name, Value = value,
                        Bounds = BrowserObservationBridge.FormatBounds(bounds),
                    });
                    characters += length;
                }
            }
            foreach (var child in element.FindAllChildren().Take(128)) queue.Enqueue(child);
        }
        return nodes;
    }
}
