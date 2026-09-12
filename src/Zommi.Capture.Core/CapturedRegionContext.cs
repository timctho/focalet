namespace Zommi.Capture;

/// <summary>One user-drawn rectangle, with observations expressed in its image pixels.</summary>
public sealed record CapturedRegionContext
{
    public int Version { get; init; } = 1;
    public string SelectionKind { get; init; } = "bbox";
    public string CoordinateSpace { get; init; } = "image-pixels";
    public IReadOnlyList<CapturedElement> Elements { get; init; } = [];
    public bool Truncated { get; init; }
    public string? Limitation { get; init; }
}

public sealed record CapturedElement
{
    // References identify observations in this capture, not another tool's action handles.
    public required string Id { get; init; }
    public string? ParentId { get; init; }
    public required string Provider { get; init; }
    public IReadOnlyDictionary<string, string>? NativeIds { get; init; }
    public required string Role { get; init; }
    public string? Name { get; init; }
    public string? Text { get; init; }
    public string? Value { get; init; }
    public string? Description { get; init; }
    public string? Href { get; init; }
    public CapturedElementState? State { get; init; }
    public required CaptureRectangle Bounds { get; init; }
    public required CaptureRectangle VisibleBounds { get; init; }
    public required string Relation { get; init; }
    public bool Truncated { get; init; }
}

public sealed record CapturedElementState
{
    public bool? Enabled { get; init; }
    public bool? Focused { get; init; }
    public bool? Selected { get; init; }
    public bool? Editable { get; init; }
    public string? Toggle { get; init; }
    public string? Expanded { get; init; }
    public string? ValueType { get; init; }
}

public static class RegionContextGeometry
{
    public static CaptureRectangle? Intersect(CaptureRectangle a, CaptureRectangle b)
    {
        var left = Math.Max(a.X, b.X);
        var top = Math.Max(a.Y, b.Y);
        var width = Math.Min(a.Right, b.Right) - left;
        var height = Math.Min(a.Bottom, b.Bottom) - top;
        return width > 0 && height > 0 ? new(left, top, width, height) : null;
    }

    public static CaptureRectangle ToImage(CaptureRectangle bounds, CaptureRectangle screen, int width, int height) =>
        new((bounds.X - screen.X) * width / screen.Width, (bounds.Y - screen.Y) * height / screen.Height,
            bounds.Width * width / screen.Width, bounds.Height * height / screen.Height);
}
