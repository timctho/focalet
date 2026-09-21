using Zommi.Capture;

namespace Zommi.Windows;

internal sealed record RegionSelectionResult(Rectangle Bounds, byte[] Png,
    ContextSnapshot? Snapshot = null, RegionAlignment? Alignment = null);

internal sealed class RegionSelectionForm(uint returnProcessId, Bitmap capturedDesktop) : ContentSelectionForm(returnProcessId, capturedDesktop, 1)
{
    protected override void OnShown(EventArgs e)
    {
        Text = "Zommi image selection";
        base.OnShown(e);
    }
}
