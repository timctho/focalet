namespace Zommi.Capture;

public sealed record CaptureRectangle(double X, double Y, double Width, double Height)
{
    public double Right => X + Width;
    public double Bottom => Y + Height;
    public bool IsValid => double.IsFinite(X) && double.IsFinite(Y) &&
        double.IsFinite(Width) && double.IsFinite(Height) && Width > 0 && Height > 0;
    public bool Contains(CaptureRectangle other) => IsValid && other.IsValid &&
        other.X >= X && other.Y >= Y && other.Right <= Right && other.Bottom <= Bottom;
    public bool Intersects(CaptureRectangle other) => IsValid && other.IsValid &&
        other.Right > X && other.X < Right && other.Bottom > Y && other.Y < Bottom;
}

public sealed record ObservationSource
{
    public required string Provider { get; init; }
    public required string NativeWindowId { get; init; }
    public int ProcessId { get; init; }
    public CaptureRectangle? WindowBounds { get; init; }
    public int? BrowserWindowId { get; init; }
    public string? TabId { get; init; }
    public string? FrameId { get; init; }
    public string? DocumentId { get; init; }
}

public sealed record CaptureMapping
{
    public required CaptureRectangle ScreenBounds { get; init; }
    public required CaptureRectangle ViewportBounds { get; init; }
    public required CaptureRectangle ImageBounds { get; init; }
    public required string CoordinateSpace { get; init; }
}

public sealed record RegionAlignment
{
    public required string Status { get; init; }
    public string? Reason { get; init; }
    public required CaptureRectangle ScreenBounds { get; init; }
    public CaptureMapping? Mapping { get; init; }
}

public sealed record DomElementContext
{
    public required string Role { get; init; }
    public required string Text { get; init; }
    public string? Label { get; init; }
    public string? Value { get; init; }
    public string? Href { get; init; }
    public bool? Disabled { get; init; }
    public bool? Checked { get; init; }
    public required CaptureRectangle Bounds { get; init; }
    public bool Truncated { get; init; }
}

public sealed record DomContext
{
    public required string Mode { get; init; }
    public IReadOnlyList<string> SelectedText { get; init; } = [];
    public IReadOnlyList<DomElementContext> Elements { get; init; } = [];
    public DomElementContext? Nearby { get; init; }
    public bool Truncated { get; init; }
    public string? Limitation { get; init; }
}
