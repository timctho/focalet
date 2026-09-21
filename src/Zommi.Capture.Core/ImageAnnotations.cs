namespace Zommi.Capture;

public enum AnnotationTool { Pen, Arrow, Rectangle, Ellipse, Highlighter }

public sealed record AnnotationPoint(float X, float Y);

public sealed record ImageAnnotation(AnnotationTool Tool, string Color, float Width,
    IReadOnlyList<AnnotationPoint> Points);

/// <summary>One region owns its history; editing B never changes A.</summary>
public sealed class AnnotationDocument
{
    public const int MaximumStrokes = 256;
    public const int MaximumPointsPerStroke = 4096;
    private readonly List<ImageAnnotation> strokes = [];
    private readonly Stack<ImageAnnotation> undone = new();
    public IReadOnlyList<ImageAnnotation> Strokes => strokes.AsReadOnly();
    public bool CanUndo => strokes.Count > 0;
    public bool CanRedo => undone.Count > 0;

    public bool Add(ImageAnnotation stroke)
    {
        if (strokes.Count >= MaximumStrokes || stroke.Points.Count == 0 ||
            stroke.Points.Count > MaximumPointsPerStroke || !float.IsFinite(stroke.Width) ||
            stroke.Width <= 0 || stroke.Width > 64 || !Enum.IsDefined(stroke.Tool) ||
            stroke.Color.Length != 7 || stroke.Color[0] != '#' || !stroke.Color.AsSpan(1).ContainsOnlyHexDigits() ||
            stroke.Points.Any(point => !float.IsFinite(point.X) || !float.IsFinite(point.Y))) return false;
        if (stroke.Tool is not (AnnotationTool.Pen or AnnotationTool.Highlighter) &&
            (stroke.Points.Count != 2 || stroke.Points[0] == stroke.Points[1])) return false;
        strokes.Add(stroke with { Points = Array.AsReadOnly(stroke.Points.ToArray()) });
        undone.Clear();
        return true;
    }

    public bool Undo()
    {
        if (!CanUndo) return false;
        undone.Push(strokes[^1]);
        strokes.RemoveAt(strokes.Count - 1);
        return true;
    }

    public bool Redo()
    {
        if (!CanRedo) return false;
        strokes.Add(undone.Pop());
        return true;
    }
}

internal static class AnnotationColorValidation
{
    public static bool ContainsOnlyHexDigits(this ReadOnlySpan<char> text)
    {
        foreach (var character in text)
            if (!Uri.IsHexDigit(character)) return false;
        return true;
    }
}

public sealed record ImageAnnotationInfo
{
    public int Version { get; init; } = 1;
    public string Source { get; init; } = "user";
    public bool BakedIntoImage { get; init; } = true;
    public string CoordinateSpace { get; init; } = "image-pixels";
    public required int StrokeCount { get; init; }
    public required IReadOnlyList<string> Tools { get; init; }
}
