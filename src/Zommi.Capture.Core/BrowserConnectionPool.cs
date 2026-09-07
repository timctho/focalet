using System.Diagnostics;
using System.Net.WebSockets;

namespace Zommi.Capture;

/// <summary>Keeps browser transports alive while every capture gets a fresh document lease.</summary>
public sealed class BrowserConnectionPool : IDisposable
{
    private readonly SemaphoreSlim gate = new(1, 1);
    private readonly Dictionary<Uri, CdpConnection> connections = [];
    private bool disposed;

    public async Task<BrowserDomSession?> OpenAsync(Uri endpoint, int processId,
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
            var connection = await CdpConnection.ConnectAsync(endpoint, cancellationToken).ConfigureAwait(false);
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
        }
        finally { gate.Release(); }
    }
}
