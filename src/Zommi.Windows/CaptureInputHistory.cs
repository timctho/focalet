namespace Zommi.Windows;

internal enum CaptureInputKind { Unknown, Input, NonInput, Protected }
internal sealed record CaptureInputObservation(CapturePasteTarget Target, CaptureInputKind Kind);

/// <summary>Two foreground visits, not a global bookmark of the last UIA Edit.</summary>
internal sealed class CaptureInputHistory
{
    public CaptureInputObservation? Current { get; private set; }
    private CaptureInputObservation? previous;
    private CapturePasteTarget? lastInputInCurrentWindow;
    public long Revision { get; private set; }

    public long ObserveWindow(CapturePasteTarget target, bool focusChanged = false)
    {
        if (Current is null || Current.Target.Window != target.Window ||
            Current.Target.ProcessId != target.ProcessId || Current.Target.ProcessStarted != target.ProcessStarted)
        {
            previous = Current?.Kind == CaptureInputKind.NonInput && lastInputInCurrentWindow is not null
                ? new(lastInputInCurrentWindow, CaptureInputKind.Input) : Current;
            Current = new(target, CaptureInputKind.Unknown);
            lastInputInCurrentWindow = null;
            Revision++;
        }
        else if (focusChanged || Current.Target.Focus != target.Focus)
        {
            Current = new(target, CaptureInputKind.Unknown);
            Revision++;
        }
        return Revision;
    }

    public void ObserveInput(long revision, CaptureInputObservation observation)
    {
        if (revision == Revision && Current?.Target.Window == observation.Target.Window)
        {
            Current = observation;
            if (observation.Kind == CaptureInputKind.Input) lastInputInCurrentWindow = observation.Target;
            if (observation.Kind == CaptureInputKind.Protected) lastInputInCurrentWindow = null;
        }
    }

    public CapturePasteTarget? Destination => Current?.Kind switch
    {
        CaptureInputKind.Input or CaptureInputKind.Unknown => Current.Target,
        CaptureInputKind.NonInput when previous?.Kind is CaptureInputKind.Input or CaptureInputKind.Unknown => previous.Target,
        _ => null,
    };

    public void Clear() { Current = previous = null; lastInputInCurrentWindow = null; Revision++; }
}
