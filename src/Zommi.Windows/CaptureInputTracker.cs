using System.Runtime.InteropServices;
using FlaUI.UIA3;

namespace Zommi.Windows;

/// <summary>Volatile bookmark of the last editable input; no text or screen capture.</summary>
internal sealed class CaptureInputTracker : IDisposable
{
    private readonly AutoResetEvent changed = new(false);
    private readonly Thread worker;
    private readonly WinEvent callback;
    private readonly nint focusHook;
    private readonly nint foregroundHook;
    private readonly int excludedProcess;
    private readonly object gate = new();
    private bool stopped;
    private bool paused;
    private int generation;
    private CapturePasteTarget? latest;

    public CaptureInputTracker(bool includeOwnProcess = false)
    {
        excludedProcess = includeOwnProcess ? 0 : Environment.ProcessId;
        callback = (_, _, _, _, _, _, _) => Signal();
        focusHook = SetWinEventHook(0x8005, 0x8005, 0, callback, 0, 0, 0);
        foregroundHook = SetWinEventHook(3, 3, 0, callback, 0, 0, 0);
        worker = new Thread(Observe) { IsBackground = true, Name = "Zommi input bookmark" };
        worker.SetApartmentState(ApartmentState.MTA);
        worker.Start();
    }

    public CapturePasteTarget? Latest { get { lock (gate) return latest; } }
    public CapturePasteTarget? Pause()
    {
        lock (gate) { paused = true; generation++; return latest; }
    }
    public void Resume() { lock (gate) { paused = false; generation++; } Signal(); }
    public void Clear() { lock (gate) { latest = null; generation++; } }
    private void Signal() { try { changed.Set(); } catch (ObjectDisposedException) { } }

    private void Observe()
    {
        try
        {
            using var automation = new UIA3Automation
            {
                ConnectionTimeout = TimeSpan.FromMilliseconds(500), TransactionTimeout = TimeSpan.FromMilliseconds(500),
            };
            while (true)
            {
                bool suspended;
                int observedGeneration;
                lock (gate) { if (stopped) return; suspended = paused; observedGeneration = generation; }
                if (!suspended)
                {
                    try
                    {
                        var input = CapturePasteTarget.RememberInput(automation, excludedProcess);
                        lock (gate) { if (!paused && generation == observedGeneration && input is not null) latest = input; }
                    }
                    catch (Exception error) when (error is not OutOfMemoryException) { /* Unavailable provider: retain the previous input. */ }
                }
                // Focus hooks wake immediately; polling refreshes the caret when
                // it moves within an editor, without observing any key contents.
                changed.WaitOne(250);
            }
        }
        catch (Exception error) when (error is not OutOfMemoryException) { /* Capture remains available through the tray. */ }
        finally { changed.Dispose(); }
    }

    public void Dispose()
    {
        UnhookWinEvent(focusHook);
        UnhookWinEvent(foregroundHook);
        lock (gate) stopped = true;
        // Do not block the UI behind an unresponsive accessibility provider.
        Signal();
        GC.KeepAlive(callback);
    }

    private delegate void WinEvent(nint hook, uint kind, nint window, int objectId, int childId, uint thread, uint time);
    [DllImport("user32.dll")] private static extern nint SetWinEventHook(uint first, uint last, nint module, WinEvent callback, uint process, uint thread, uint flags);
    [DllImport("user32.dll")] private static extern bool UnhookWinEvent(nint hook);
}
