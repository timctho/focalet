using System.Diagnostics;
using System.Net.WebSockets;
using System.Text.Json;

namespace Zommi.Capture;

public sealed record BrowserConnectionStatus(string Browser, string State, string Message, bool ExplicitEndpoint);

public sealed class BrowserConnections(BrowserConnectionPool pool)
{
    internal Func<string, IEnumerable<Uri>> Discover { get; init; } = BrowserDiscovery.Endpoints;
    internal Func<int, string?> ProcessFamily { get; init; } = ProcessBrowser;

    public async Task<IReadOnlyList<BrowserConnectionStatus>> StatusAsync(bool enabled)
    {
        var result = new List<BrowserConnectionStatus>();
        foreach (var browser in new[] { "edge", "chrome" }) result.Add(await StatusAsync(browser, enabled).ConfigureAwait(false));
        return result;
    }

    private async Task<BrowserConnectionStatus> StatusAsync(string browser, bool enabled)
    {
        if (!enabled) return Status(browser, "disabled", "Full webpage details is off.");
        var endpoints = Discover(browser).ToArray();
        if (endpoints.Length == 0) return BrowserDiscovery.HasExplicitEndpoint
            ? Status(browser, "unavailable", "The custom browser connection is invalid. Use a local browser address without credentials, or restore automatic discovery.")
            : Status(browser, "setup-required", "Enable browser access to include webpage text and links.");
        foreach (var endpoint in endpoints)
        {
            var (state, pid) = await pool.InspectAsync(endpoint).ConfigureAwait(false);
            if (state == "connected" && pid is { } processId)
                return ProcessFamily(processId) == browser
                    ? Status(browser, state, "Ready to include webpage text and links where available.")
                    : Status(browser, "other-browser", "The configured connection belongs to another browser.");
            if (state == "unavailable") return Status(browser, state, "Connection lost or declined. Reconnect to try again.");
        }
        return Status(browser, "available", "Browser access was found. Connect and allow the browser permission prompt.");
    }

    public async Task<BrowserConnectionStatus> ReconnectAsync(string browser, bool enabled, CancellationToken cancellationToken)
    {
        if (browser is not ("edge" or "chrome")) throw new ArgumentException("Choose Edge or Chrome.", nameof(browser));
        if (!enabled) return Status(browser, "disabled", "Full webpage details is off.");
        var endpoints = Discover(browser).ToArray();
        if (endpoints.Length == 0) return await StatusAsync(browser, enabled).ConfigureAwait(false);
        try
        {
            foreach (var endpoint in endpoints)
                if (await pool.ReconnectAsync(endpoint, pid => ProcessFamily(pid) == browser, cancellationToken).ConfigureAwait(false))
                    return await StatusAsync(browser, enabled).ConfigureAwait(false);
            return Status(browser, "other-browser", "The configured connection could not be verified as this browser.");
        }
        catch (Exception error) when (error is OperationCanceledException or IOException or WebSocketException or HttpRequestException or InvalidOperationException or JsonException)
        {
            return Status(browser, "unavailable", error is OperationCanceledException
                ? "Connection timed out. Allow access in the browser, then reconnect."
                : "Could not connect. Check browser access, then reconnect.");
        }
    }

    private static BrowserConnectionStatus Status(string browser, string state, string message) =>
        new(browser, state, message, BrowserDiscovery.HasExplicitEndpoint);

    private static string? ProcessBrowser(int pid)
    {
        try { using var process = Process.GetProcessById(pid); return BrowserDiscovery.Family(process.ProcessName); }
        catch (Exception error) when (error is ArgumentException or InvalidOperationException or System.ComponentModel.Win32Exception) { return null; }
    }
}
