using Zommi.Capture;

namespace Zommi.Windows;

internal static class AnnotatedCapture
{
    public static RegionSelectionResult Complete(ContentSelection selected, RegionSelectionResult captured)
    {
        var result = AnnotationRenderer.SamePixels(selected.FrozenPng, captured.Png)
            ? captured
            : FrozenImage(selected);
        if (selected.Annotations.Count == 0) return result;
        var info = new ImageAnnotationInfo
        {
            StrokeCount = selected.Annotations.Count,
            Tools = selected.Annotations.Select(stroke => stroke.Tool.ToString().ToLowerInvariant()).Distinct().ToArray(),
        };
        return result with
        {
            Png = AnnotationRenderer.Apply(selected.FrozenPng, selected.Annotations),
            Snapshot = result.Snapshot! with { ImageAnnotations = info },
        };
    }

    private static RegionSelectionResult FrozenImage(ContentSelection selected)
    {
        const string reason = "The source changed while you were selecting or drawing. The frozen image is retained; newer source context was omitted.";
        var screen = BrowserObservationBridge.ToRectangle(selected.Region);
        var alignment = new RegionAlignment
        {
            Status = "image-only", Reason = reason, ScreenBounds = screen,
            Mapping = new CaptureMapping
            {
                CoordinateSpace = "desktop-physical-pixels", ScreenBounds = screen, ViewportBounds = screen,
                ImageBounds = new CaptureRectangle(0, 0, selected.Region.Width, selected.Region.Height),
            },
        };
        return new(selected.Region, selected.FrozenPng, new ContextSnapshot
        {
            SnapshotId = Guid.NewGuid().ToString("D"), ObservedAtUtc = selected.FrozenAtUtc,
            ExpiresAtUtc = selected.FrozenAtUtc.AddSeconds(30), SurfaceKind = "Image region",
            Application = "Screen", ProcessName = "screen", Region = alignment,
            Confidence = "limited", Limitation = reason,
        }, alignment);
    }
}
