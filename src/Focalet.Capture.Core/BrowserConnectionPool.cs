using System.Diagnostics;
using System.Net.WebSockets;

namespace Focalet.Capture;

/// <summary>Keeps browser transports alive while every capture gets a fresh document lease.</summary>
public sealed class BrowserConnectionPool : IDisposable
{
    private readonly SemaphoreSlim gate = new(1, 1);
    private readonly SemaphoreSlim bindings = new(1, 1);
    private readonly Dictionary<Uri, CdpConnection> connections = [];
    private readonly Dictionary<Uri, DateTimeOffset> retryAfter = [];
    private bool disposed;

    // Inspection never opens a socket or triggers a browser permission prompt.
    internal async Task<(string State, int? ProcessId)> InspectAsync(Uri endpoint)
    {
        await gate.WaitAsync().ConfigureAwait(false);
        try
        {
            ObjectDisposedException.ThrowIf(disposed, this);
            if (connections.TryGetValue(endpoint, out var connection))
                return connection.IsOpen && connection.BrowserProcessId is { } pid && IsProcessRunning(pid)
                    ? ("connected", pid) : ("unavailable", connection.BrowserProcessId);
            return (retryAfter.ContainsKey(endpoint) ? "unavailable" : "available", null);
        }
        finally { gate.Release(); }
    }

    internal async Task<bool> ReconnectAsync(Uri endpoint, Func<int, bool> matchesProcess,
        CancellationToken cancellationToken)
    {
        await bindings.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            await gate.WaitAsync(cancellationToken).ConfigureAwait(false);
            try
            {
                ObjectDisposedException.ThrowIf(disposed, this);
                // A global override may point at the other browser. Do not
                // disconnect that browser when reconnecting this one.
                if (connections.TryGetValue(endpoint, out var previous))
                {
                    if (previous.BrowserProcessId is { } pid && IsProcessRunning(pid) && !matchesProcess(pid)) return false;
                    connections.Remove(endpoint);
                    previous.Dispose();
                }
                retryAfter.Remove(endpoint);
            }
            finally { gate.Release(); }
            var (connection, _) = await GetConnectionAsync(endpoint, cancellationToken).ConfigureAwait(false);
            var processes = await connection.CallAsync("SystemInfo.getProcessInfo", null, null, cancellationToken).ConfigureAwait(false);
            var ids = processes.GetProperty("processInfo").EnumerateArray()
                .Where(process => process.GetProperty("type").GetString() == "browser")
                .Select(process => process.GetProperty("id").GetInt32()).ToArray();
            if (ids.Length != 1) return false;
            connection.BrowserProcessId = ids[0];
            return matchesProcess(ids[0]);
        }
        finally { bindings.Release(); }
    }

    public async Task<BrowserDomSession?> OpenAsync(Uri endpoint, int processId,
        Func<string, bool> matchesNativeWindow, CancellationToken cancellationToken)
    {
        await bindings.WaitAsync(cancellationToken).ConfigureAwait(false);
        try { return await BindAsync(endpoint, processId, matchesNativeWindow, cancellationToken).ConfigureAwait(false); }
        finally { bindings.Release(); }
    }

    private async Task<BrowserDomSession?> BindAsync(Uri endpoint, int processId,
        Func<string, bool> matchesNativeWindow, CancellationToken cancellationToken)
    {
        for (var attempt = 0; ; attempt++)
        {
            var (connection, reused) = await GetConnectionAsync(endpoint, cancellationToken).ConfigureAwait(false);
            try
            {
                return await BrowserDomSession.BindAsync(connection, processId, matchesNativeWindow,
                    ownsConnection: false, cancellationToken).ConfigureAwait(false);
            }
            catch (Exception exception) when (attempt == 0 && reused && !connection.IsOpen &&
                !cancellationToken.IsCancellationRequested && exception is IOException or WebSocketException or ObjectDisposedException)
            {
                // A browser may have closed an idle socket. Reconnect once; a
                // document/selection validation failure must never retry silently.
            }
        }
    }

    private async Task<(CdpConnection Connection, bool Reused)> GetConnectionAsync(Uri endpoint, CancellationToken cancellationToken)
    {
        await gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            ObjectDisposedException.ThrowIf(disposed, this);
            foreach (var entry in connections.Where(entry => !entry.Value.IsOpen ||
                         entry.Value.BrowserProcessId is { } processId && !IsProcessRunning(processId)).ToArray())
            {
                connections.Remove(entry.Key);
                entry.Value.Dispose();
            }
            if (connections.TryGetValue(endpoint, out var existing)) return (existing, true);
            if (retryAfter.TryGetValue(endpoint, out var retry) && retry > DateTimeOffset.UtcNow)
                throw new InvalidOperationException("Browser access is unavailable. Retrying is paused briefly after a failed connection.");
            CdpConnection connection;
            try { connection = await CdpConnection.ConnectAsync(endpoint, cancellationToken).ConfigureAwait(false); }
            catch (Exception exception) when (exception is OperationCanceledException or WebSocketException or IOException or HttpRequestException)
            {
                // A declined/expired Chrome prompt must not be repeated for
                // every remaining item in a batch or every quick retry.
                retryAfter[endpoint] = DateTimeOffset.UtcNow.AddMinutes(1);
                throw;
            }
            retryAfter.Remove(endpoint);
            connections.Add(endpoint, connection);
            return (connection, false);
        }
        finally { gate.Release(); }
    }

    private static bool IsProcessRunning(int processId)
    {
        try { using var process = Process.GetProcessById(processId); return !process.HasExited; }
        catch (ArgumentException) { return false; }
    }

    public void Dispose()
    {
        gate.Wait();
        try
        {
            if (disposed) return;
            disposed = true;
            foreach (var connection in connections.Values) connection.Dispose();
            connections.Clear();
            retryAfter.Clear();
        }
        finally { gate.Release(); }
    }
}
