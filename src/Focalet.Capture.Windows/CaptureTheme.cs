using System.Text.Json;

namespace Focalet.Windows;

internal sealed record CaptureTheme(Color Accent, Color OnAccent, Color Surface,
    Color OnSurface, Color Muted, Color Outline, Color Hover)
{
    public static CaptureTheme Default { get; } = new(
        Color.FromArgb(56, 125, 168), Color.White, Color.FromArgb(40, 40, 40),
        Color.WhiteSmoke, Color.LightGray, Color.FromArgb(80, 80, 80), Color.FromArgb(60, 60, 60));

    public static CaptureTheme FromParameters(JsonElement parameters)
    {
        if (parameters.ValueKind != JsonValueKind.Object ||
            !parameters.TryGetProperty("theme", out var theme) || theme.ValueKind != JsonValueKind.Object)
            return Default;
        Color Read(string name, Color fallback) => theme.TryGetProperty(name, out var value) &&
            value.ValueKind == JsonValueKind.Number && value.TryGetUInt32(out var argb)
            ? Color.FromArgb(unchecked((int)(argb | 0xff000000))) : fallback;
        return new(Read("accent", Default.Accent), Read("onAccent", Default.OnAccent),
            Read("surface", Default.Surface), Read("onSurface", Default.OnSurface),
            Read("muted", Default.Muted), Read("outline", Default.Outline), Read("hover", Default.Hover));
    }
}
