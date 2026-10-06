using System.Diagnostics;
using Focalet.Capture;

internal static class BrowserConnectionAcceptance
{
    public static async Task VerifyAsync(string executable, Uri chromeEndpoint, int chromePid,
        Action<bool, string> check, CancellationToken token)
    {
        var profile = Path.Combine(Path.GetTempPath(), "focalet-second-browser-" + Guid.NewGuid().ToString("N"));
        var otherExecutable = Environment.GetEnvironmentVariable("FOCALET_TEST_EDGE") ?? executable;
        var start = new ProcessStartInfo(otherExecutable) { UseShellExecute = false, RedirectStandardError = true, RedirectStandardOutput = true };
        foreach (var argument in new[] { "--headless=new", "--no-sandbox", "--disable-gpu", "--no-first-run",
                     "--remote-debugging-port=0", "--user-data-dir=" + profile, "about:blank" }) start.ArgumentList.Add(argument);
        using var other = Process.Start(start) ?? throw new InvalidOperationException("Could not start the second browser fixture.");
        other.BeginErrorReadLine(); other.BeginOutputReadLine();
        try
        {
            string[] port;
            while (true)
            {
                if (other.HasExited) throw new InvalidOperationException("Second browser exited before opening CDP.");
                try
                {
                    port = File.ReadAllLines(Path.Combine(profile, "DevToolsActivePort"));
                    if (port.Length >= 2 && int.TryParse(port[0], out _) && port[1].StartsWith("/devtools/browser/", StringComparison.Ordinal)) break;
                }
                catch (IOException) { }
                await Task.Delay(30, token);
            }
            await using var chrome = new CountingBrowserProxy(chromeEndpoint);
            await using var edge = new CountingBrowserProxy(new Uri($"ws://127.0.0.1:{port[0]}{port[1]}"));
            using var pool = new BrowserConnectionPool();
            // Both CI fixtures use the installed Chromium executable; assign
            // their distinct real browser PIDs to the two discovery families.
            var manager = new BrowserConnections(pool)
            {
                Discover = browser => [browser == "chrome" ? chrome.Endpoint : edge.Endpoint],
                ProcessFamily = pid =>
                {
                    if (otherExecutable == executable) return pid == chromePid ? "chrome" : pid == other.Id ? "edge" : null;
                    using var process = Process.GetProcessById(pid);
                    return BrowserDiscovery.Family(process.ProcessName);
                },
            };
            var initial = await manager.StatusAsync(true);
            check(initial.All(status => status.State == "available") && chrome.AttemptedConnections + edge.AttemptedConnections == 0,
                "Opening browser settings inspects discovery without opening connections");
            var disabled = await manager.ReconnectAsync("edge", false, token);
            check(disabled.State == "disabled" && edge.AttemptedConnections == 0, "Disabled webpage details never reconnects a browser");
            var connectedChrome = await manager.ReconnectAsync("chrome", true, token);
            var connectedEdge = await manager.ReconnectAsync("edge", true, token);
            check(connectedChrome.State == "connected" && connectedEdge.State == "connected" &&
                (await manager.StatusAsync(true)).All(status => status.State == "connected"),
                "Two different browser processes remain connected in one pool");
            var chromeCount = chrome.AcceptedConnections;
            var edgeCount = edge.AcceptedConnections;
            await manager.ReconnectAsync("edge", true, token);
            check(chrome.AcceptedConnections == chromeCount && edge.AcceptedConnections == edgeCount + 1 &&
                chrome.Count("Target.attachToTarget") == 0 && edge.Count("Target.attachToTarget") == 0,
                "Reconnecting Edge leaves Chrome connected and does not read any page");
            var overridden = new BrowserConnections(pool)
            {
                Discover = _ => [chrome.Endpoint],
                ProcessFamily = manager.ProcessFamily,
            };
            check((await overridden.ReconnectAsync("edge", true, token)).State == "other-browser" &&
                chrome.AcceptedConnections == chromeCount && (await manager.StatusAsync(true)).Single(status => status.Browser == "chrome").State == "connected",
                "A single-browser override cannot reconnect or disconnect the other browser");
            edge.RejectConnections = true;
            check((await manager.ReconnectAsync("edge", true, token)).State == "unavailable", "Declined browser access is reported as disconnected");
            var attempts = edge.AttemptedConnections;
            check((await manager.StatusAsync(true)).Single(status => status.Browser == "edge").State == "unavailable" && edge.AttemptedConnections == attempts,
                "Refreshing a failed browser status does not repeat its permission attempt");
            edge.RejectConnections = false;
            check((await manager.ReconnectAsync("edge", true, token)).State == "connected" && chrome.AcceptedConnections == chromeCount,
                "Explicit reconnect clears only the chosen browser's retry cooldown");
            var absent = new BrowserConnections(pool) { Discover = _ => [] };
            check((await absent.StatusAsync(true)).All(status => status.State == "setup-required"), "Missing discovery is distinguished from a lost connection");
        }
        finally
        {
            if (!other.HasExited) other.Kill(entireProcessTree: true);
            await other.WaitForExitAsync(CancellationToken.None);
            try { Directory.Delete(profile, true); } catch (IOException) { }
        }
    }
}
