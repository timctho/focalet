using Focalet.Capture;

namespace Focalet.Windows;

internal static class RegionCaptureSession
{
    internal sealed record SelectedBatch(IReadOnlyList<RegionSelectionResult> Regions, string? ErrorMessage = null);

    internal static SelectedBatch SelectBatch(uint returnProcessId, CaptureTheme theme, string confirmLabel = "Attach", string? destinationName = null)
    {
        var sourceFocus = WindowFocus.Remember();
        var sourcePointer = Cursor.Position;
        using var desktop = ScreenCapture.CaptureBitmap(SystemInformation.VirtualScreen);
        using var selector = new ContentSelectionForm(returnProcessId, desktop, theme: theme, confirmLabel: confirmLabel, destinationName: destinationName);
        if (selector.ShowDialog() != DialogResult.OK || selector.Selections.Count == 0)
            return new([], selector.ErrorMessage);
        var selections = selector.Selections;
        selector.Dispose();
        // The selector changes activation and leaves the pointer over its last
        // toolbar/drag position. Restore the observed surface before comparing
        // its pixels; a new hover highlight is not a document mutation.
        sourceFocus?.Restore();
        Cursor.Position = sourcePointer;
        Application.DoEvents();
        Thread.Sleep(120);
        ScreenCapture.FlushDesktop();
        return CompleteSelections(selections);
    }

    internal static SelectedBatch CompleteSelections(IReadOnlyList<ContentSelection> selections)
    {
        var results = new List<RegionSelectionResult>();
        foreach (var selected in selections)
        {
            bool Matches() => NativeCaptureWindow.Bounds(selected.Window) == selected.WindowBounds &&
                NativeCaptureWindow.Title(selected.Window) == selected.WindowTitle &&
                NativeCaptureWindow.ProcessId(selected.Window) == selected.ProcessId;
            if (selected.Window != 0)
            {
                if (!Matches()) return new([], "The selected window changed. Select the content again.");
                var actualWindow = NativeCaptureWindow.ForRegion(selected.Region);
                if (!Matches() || actualWindow != selected.Window)
                {
                    if (Environment.GetEnvironmentVariable("FOCALET_CAPTURE_DIAGNOSTICS") == "1")
                        Console.Error.WriteLine($"Selection mismatch: expected={selected.Window}, actual={actualWindow}, identityMatches={Matches()}, region={selected.Region}, queuedBounds={selected.WindowBounds}, currentBounds={NativeCaptureWindow.Bounds(selected.Window)}");
                    return new([], "The selected window changed or is covered. Select the content again.");
                }
            }
            results.Add(AnnotatedCapture.Complete(selected, RegionContextCapture.Capture(selected.Region)));
        }
        return new(results);
    }
}
