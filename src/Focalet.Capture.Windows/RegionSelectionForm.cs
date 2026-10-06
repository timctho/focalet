using Focalet.Capture;

namespace Focalet.Windows;

internal sealed record RegionSelectionResult(Rectangle Bounds, byte[] Png,
    ContextSnapshot? Snapshot = null, RegionAlignment? Alignment = null);

internal sealed class RegionSelectionForm(uint returnProcessId, Bitmap capturedDesktop, CaptureTheme? theme = null) : ContentSelectionForm(returnProcessId, capturedDesktop, 1, theme)
{
    protected override void OnShown(EventArgs e)
    {
        Text = "Focalet image selection";
        base.OnShown(e);
    }
}
