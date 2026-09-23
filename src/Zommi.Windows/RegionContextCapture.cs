using System.Diagnostics;
using System.Text.Json;
using Zommi.Capture;

namespace Zommi.Windows;

internal static class RegionContextCapture
{
    public static RegionSelectionResult Capture(Rectangle region)
    {
        var source = SourceAt(region);
        var window = source?.Handle ?? 0;
        if (window == 0) return ImageOnly(region, "The region spans windows or its source could not be confirmed.");
        var title = NativeCaptureWindow.Title(window);
        var windowBounds = NativeCaptureWindow.Bounds(window);
        try
        {
            string? browserLimitation = null;
            try
            {
                using var browser = BrowserObservationBridge.TryOpen(window, unavailable: reason => browserLimitation = reason);
                if (browser is not null && browser.Viewport.Contains(BrowserObservationBridge.ToRectangle(region)))
                {
                    var observation = browser.Read(new Point(region.X + region.Width / 2, region.Y + region.Height / 2), region);
                    var image = browser.CaptureImage(region);
                    var png = image.Png;
                    if (NativeCaptureWindow.ForRegion(region) != window || !image.Stamp.SameViewportAndDocument(observation.Stamp) || !browser.StillMatches(observation) ||
                        !observation.SameRegionContent(browser.Read(new Point(region.X, region.Y), region)))
                        return ImageOnly(region, "The page changed while the image was captured.", png, source);
                    var snapshot = browser.Snapshot(observation, region: region);
                    snapshot = snapshot with
                    {
                        RegionContext = new CapturedRegionContext
                        {
                            Elements = observation.Elements.Select(element => browser.RegionElement(element, observation.Stamp, region, image.Width, image.Height)).ToArray(),
                            Truncated = observation.Truncated, Limitation = observation.Limitation,
                        },
                        Region = snapshot.Region! with
                        {
                            Mapping = snapshot.Region.Mapping! with
                            {
                                ImageBounds = new CaptureRectangle(0, 0, image.Width, image.Height),
                            },
                        },
                    };
                    if (observation.Elements.Count == 0)
                    {
                        var reason = observation.Limitation ?? "No text or accessible object was exposed inside this region.";
                        snapshot = snapshot with
                        {
                            Dom = null, RegionContext = null, Confidence = "limited", Limitation = reason,
                            Region = snapshot.Region with { Status = "image-only", Reason = reason },
                        };
                    }
                    return new RegionSelectionResult(region, png, snapshot, snapshot.Region);
                }
            }
            catch (Exception exception) when (BrowserObservationBridge.IsUnavailable(exception))
            {
                if (Environment.GetEnvironmentVariable("ZOMMI_CAPTURE_DIAGNOSTICS") == "1") Console.Error.WriteLine(exception);
                browserLimitation = "Browser DOM capture failed. Windows accessibility was tried instead.";
            }

            var before = UiaRegionCapture.Read(window, region);
            var pixels = ScreenCapture.CapturePng(region);
            var after = UiaRegionCapture.Read(window, region);
            if (NativeCaptureWindow.ForRegion(region) != window ||
                NativeCaptureWindow.Title(window) != title || NativeCaptureWindow.Bounds(window) != windowBounds ||
                JsonSerializer.Serialize(before) != JsonSerializer.Serialize(after))
                return ImageOnly(region, "The window or its accessible content changed while the image was captured.", pixels, source);
            var spatial = before.Cells.Count == 0 ? null : new RegionSpatialContext { Cells = before.Cells };
            if (before.Elements.Count == 0)
                return ImageOnly(region, string.Join(" ", new[] { browserLimitation, "No accessible text or named object was exposed inside this region." }.Where(value => value is not null)), pixels, source, spatial);
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
                Source = NativeCaptureWindow.Source(window, "windows-uia-region"),
                RegionContext = new CapturedRegionContext
                {
                    Elements = before.Elements, Truncated = before.Truncated,
                    Limitation = before.Truncated ? "Accessibility traversal reached its time, node or text budget." : null,
                },
                SpatialContext = spatial,
                Region = alignment, Confidence = "medium",
                Limitation = string.Join(" ", new[] { browserLimitation,
                    "Captured Windows accessibility. Element bounds are in image pixels. Intersecting elements may expose labels or values beyond the crop; the image is the selected content." }.Where(value => value is not null)),
            };
            return new RegionSelectionResult(region, pixels, context, alignment);
        }
        catch (Exception exception) when (BrowserObservationBridge.IsUnavailable(exception))
        {
            if (Environment.GetEnvironmentVariable("ZOMMI_CAPTURE_DIAGNOSTICS") == "1") Console.Error.WriteLine(exception);
            return ImageOnly(region, "The source could not be aligned with this image. The selected image is attached.");
        }
    }

    private sealed record WindowIdentity(nint Handle, int ProcessId, string Title, CaptureRectangle Bounds);

    private static WindowIdentity? SourceAt(Rectangle region)
    {
        var window = NativeCaptureWindow.ForRegion(region);
        return window == 0 ? null : new(window, NativeCaptureWindow.ProcessId(window),
            NativeCaptureWindow.Title(window), NativeCaptureWindow.Bounds(window));
    }

    private static RegionSelectionResult ImageOnly(Rectangle region, string reason, byte[]? png = null,
        WindowIdentity? source = null, RegionSpatialContext? spatial = null)
    {
        // Geometry is useful even when the app exposes no accessibility text.
        // A source identity is retained only across this exact image capture.
        if (png is null)
        {
            source = SourceAt(region);
            png = ScreenCapture.CapturePng(region);
        }
        if (source != SourceAt(region)) source = null;
        var screen = BrowserObservationBridge.ToRectangle(region);
        var width = System.Buffers.Binary.BinaryPrimitives.ReadInt32BigEndian(png.AsSpan(16, 4));
        var height = System.Buffers.Binary.BinaryPrimitives.ReadInt32BigEndian(png.AsSpan(20, 4));
        var alignment = new RegionAlignment
        {
            Status = "image-only", Reason = reason, ScreenBounds = screen,
            Mapping = new CaptureMapping
            {
                CoordinateSpace = "desktop-physical-pixels", ScreenBounds = screen,
                ViewportBounds = screen, ImageBounds = new CaptureRectangle(0, 0, width, height),
            },
        };
        var now = DateTimeOffset.UtcNow;
        var processName = "screen";
        if (source is not null)
        {
            try { using var process = Process.GetProcessById(source.ProcessId); processName = process.ProcessName; }
            catch (ArgumentException) { source = null; }
        }
        var snapshot = new ContextSnapshot
        {
            SnapshotId = Guid.NewGuid().ToString("D"), ObservedAtUtc = now, ExpiresAtUtc = now.AddSeconds(30),
            SurfaceKind = "Image region", Application = source is null ? "Screen" : processName,
            ProcessName = processName, WindowTitle = source?.Title ?? "",
            Source = source is null ? null : NativeCaptureWindow.Source(source.Handle, "windows-screen-region"),
            Region = alignment, SpatialContext = source is null ? null : spatial,
            Confidence = "limited", Limitation = reason,
        };
        return new(region, png, snapshot, alignment);
    }

}
