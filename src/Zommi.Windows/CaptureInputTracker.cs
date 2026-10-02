using System.Runtime.InteropServices;
using FlaUI.UIA3;

namespace Zommi.Windows;

/// <summary>Foreground-window bookmarks; accessibility enhances but never owns routing.</summary>
internal sealed class CaptureInputTracker : IDisposable
{
    private readonly AutoResetEvent changed = new(false);
    private readonly Thread worker;
    private readonly WinEvent callback;
    private readonly nint focusHook;
    private readonly nint foregroundHook;
    private readonly int excludedProcess;
    private readonly object gate = new();
    private readonly CaptureInputHistory history = new();
    private bool stopped;
    private bool paused;
    private int generation;
    private ObservationRequest? pending;
    private sealed record ObservationRequest(CapturePasteTarget Target, TaskCompletionSource<CaptureInputObservation?> Completion);

    public CaptureInputTracker(bool includeOwnProcess = false)
    {
        excludedProcess = includeOwnProcess ? 0 : Environment.ProcessId;
        callback = (_, kind, window, _, _, _, _) =>
        {
            // Record the native window immediately, independently of a slow or
            // unavailable UIA provider. Never leave a different app as "current".
            var target = ReadWindow();
            lock (gate)
            {
                if (!paused && !stopped && target is not null)
                    history.ObserveWindow(target, kind == 0x8005 && (window == 0 || target.ContainsWindow(window)));
            }
            Signal();
        };
        focusHook = SetWinEventHook(0x8005, 0x8005, 0, callback, 0, 0, 0);
        foregroundHook = SetWinEventHook(3, 3, 0, callback, 0, 0, 0);
        worker = new Thread(Observe) { IsBackground = true, Name = "Zommi input bookmark" };
        worker.SetApartmentState(ApartmentState.MTA);
        worker.Start();
    }

    private CapturePasteTarget? ReadWindow()
    {
        var target = CapturePasteTarget.RememberWindow();
        return target is null || target.ProcessId == excludedProcess || CapturePasteTarget.IsShellSurface(target.Window) ? null : target;
    }

    public CapturePasteTarget? Latest { get { lock (gate) return history.Destination; } }
    public void Pause() { lock (gate) { paused = true; generation++; } }

    public async Task<CapturePasteTarget?> PauseAsync()
    {
        var target = ReadWindow();
        TaskCompletionSource<CaptureInputObservation?> completion;
        long revision;
        int requestedGeneration;
        lock (gate)
        {
            paused = true;
            requestedGeneration = ++generation;
            if (target is null) return null;
            revision = history.ObserveWindow(target);
            completion = new(TaskCreationOptions.RunContinuationsAsynchronously);
            pending = new(target, completion);
        }
        Signal();
        CaptureInputObservation? observation = null;
        try { observation = await completion.Task.WaitAsync(TimeSpan.FromMilliseconds(1500)); }
        catch (TimeoutException) { /* Use this window's native bookmark, never an older app's global Edit. */ }
        lock (gate)
        {
            if (generation != requestedGeneration || !target.IsCurrent()) return null;
            if (observation is not null) history.ObserveInput(revision, observation);
            return history.Destination;
        }
    }

    public void Resume() { lock (gate) { paused = false; generation++; } Signal(); }
    public void Clear() { lock (gate) { history.Clear(); generation++; } }
    private void Signal() { try { changed.Set(); } catch (ObjectDisposedException) { } }

    private void Observe()
    {
        try
        {
            using var automation = new UIA3Automation
            {
                ConnectionTimeout = TimeSpan.FromMilliseconds(500), TransactionTimeout = TimeSpan.FromMilliseconds(500),
            };
            CaptureInputObservation? ReadInput(CapturePasteTarget target)
            {
                try { return CapturePasteTarget.ObserveInput(automation, target); }
                catch (Exception error) when (error is not OutOfMemoryException) { return null; }
            }
            while (true)
            {
                bool suspended;
                int observedGeneration;
                ObservationRequest? request;
                lock (gate)
                {
                    if (stopped) return;
                    suspended = paused;
                    observedGeneration = generation;
                    request = pending;
                    pending = null;
                }
                if (request is not null) request.Completion.TrySetResult(ReadInput(request.Target));
                else if (!suspended && ReadWindow() is { } target)
                {
                    long revision;
                    lock (gate)
                    {
                        revision = !paused && generation == observedGeneration ? history.ObserveWindow(target) : -1;
                    }
                    if (revision >= 0)
                    {
                        var observation = ReadInput(target);
                        lock (gate)
                        {
                            if (!paused && generation == observedGeneration && observation is not null)
                                history.ObserveInput(revision, observation);
                        }
                    }
                }
                changed.WaitOne(250);
            }
        }
        catch (Exception error) when (error is not OutOfMemoryException) { /* Native foreground callbacks remain available. */ }
        finally { changed.Dispose(); }
    }

    public void Dispose()
    {
        UnhookWinEvent(focusHook);
        UnhookWinEvent(foregroundHook);
        lock (gate) { stopped = true; pending?.Completion.TrySetCanceled(); }
        Signal();
        GC.KeepAlive(callback);
    }

    private delegate void WinEvent(nint hook, uint kind, nint window, int objectId, int childId, uint thread, uint time);
    [DllImport("user32.dll")] private static extern nint SetWinEventHook(uint first, uint last, nint module, WinEvent callback, uint process, uint thread, uint flags);
    [DllImport("user32.dll")] private static extern bool UnhookWinEvent(nint hook);
}
