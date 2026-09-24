using System.Text.Json;
using Zommi.Capture;

// The native platform owns screenshots, window identity and accessibility.
// This process reuses the same bounded DOM observer and connection pool as
// Windows. It never chooses a window or captures pixels on the caller's behalf.
var json = new JsonSerializerOptions(JsonSerializerDefaults.Web);
using var host = new UnixBrowserCapture();
while (await Console.In.ReadLineAsync() is { } line)
{
    string? id = null;
    var shutdown = false;
    try
    {
        if (line.Length > 2_000_000) throw new InvalidOperationException("Capture request is too large.");
        using var document = JsonDocument.Parse(line);
        var request = document.RootElement;
        id = request.GetProperty("id").GetString();
        var method = request.GetProperty("method").GetString();
        shutdown = method == "shutdown";
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(18));
        var result = method switch
        {
            "ping" => (object)new { ready = true },
            "observe" => await host.ObserveAsync(request.GetProperty("params"), timeout.Token),
            "confirm" => await host.ConfirmAsync(timeout.Token),
            "release" or "shutdown" => host.Release(),
            _ => throw new InvalidOperationException("Unknown browser capture request."),
        };
        Console.WriteLine(JsonSerializer.Serialize(new { id, ok = true, result }, json));
    }
    catch (Exception error)
    {
        host.Release();
        Console.WriteLine(JsonSerializer.Serialize(new { id, ok = false, error = error.Message }, json));
    }
    if (shutdown) break;
}

sealed class UnixBrowserCapture : IDisposable
{
    private readonly BrowserConnectionPool pool = new();
    private BrowserDomSession? session;
    private BrowserDomObservation? observation;
    private CaptureRectangle? cssRegion;
    private CaptureRectangle? viewport;
    private CaptureRectangle? region;
    private int imageWidth;
    private int imageHeight;
    private DateTimeOffset expires;
    private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web);

    public async Task<object> ObserveAsync(JsonElement request, CancellationToken cancellation)
    {
        Release();
        var source = request.GetProperty("source");
        var processId = source.GetProperty("processId").GetInt32();
        var title = source.GetProperty("windowTitle").GetString() ?? "";
        var nativeId = source.GetProperty("nativeWindowId").GetString();
        viewport = request.GetProperty("viewport").Deserialize<CaptureRectangle>(Json)!;
        region = request.GetProperty("bounds").Deserialize<CaptureRectangle>(Json)!;
        imageWidth = request.GetProperty("imageWidth").GetInt32();
        imageHeight = request.GetProperty("imageHeight").GetInt32();
        if (!viewport.IsValid || !viewport.Contains(region) || imageWidth <= 0 || imageHeight <= 0)
            throw new InvalidOperationException("The native page viewport does not contain this region.");
        // The binding outlives this request's JsonDocument until confirm().
        var windows = request.GetProperty("windows").EnumerateArray().Select(window => window.Clone()).ToArray();
        bool Matches(string pageTitle) => !string.IsNullOrWhiteSpace(pageTitle) &&
            WindowTitleMatches(title, pageTitle) && windows.Count(window =>
                window.TryGetProperty("processId", out var pid) && pid.ValueKind == JsonValueKind.Number &&
                pid.TryGetInt32(out var windowProcessId) && windowProcessId == processId &&
                WindowTitleMatches(window.GetProperty("windowTitle").GetString() ?? "", pageTitle)) == 1 &&
            windows.Any(window => window.TryGetProperty("nativeWindowId", out var id) && id.GetString() == nativeId);
        var processName = source.TryGetProperty("processName", out var name) ? name.GetString() ?? "" : "";
        foreach (var endpoint in Endpoints(processName))
        {
            session = await pool.OpenAsync(endpoint, processId, Matches, cancellation);
            if (session is not null) break;
        }
        if (session is null) return new { available = false, limitation = "No authorized browser connection matched this native window unambiguously." };
        var stamp = await session.StampAsync(cancellation);
        if (!stamp.Visible || stamp.Width <= 0 || stamp.Height <= 0 || Math.Abs(stamp.ViewportScale - 1) > .01 ||
            Math.Abs(viewport.Width / stamp.Width - viewport.Height / stamp.Height) > .03)
            throw new InvalidOperationException("Browser and native viewport coordinates could not be aligned.");
        cssRegion = new((region.X - viewport.X) * stamp.Width / viewport.Width,
            (region.Y - viewport.Y) * stamp.Height / viewport.Height,
            region.Width * stamp.Width / viewport.Width, region.Height * stamp.Height / viewport.Height);
        observation = await session.ReadAsync("region", cssRegion.X, cssRegion.Y, cssRegion, cancellation);
        expires = DateTimeOffset.UtcNow.AddSeconds(10);
        return new { available = true };
    }

    public async Task<object> ConfirmAsync(CancellationToken cancellation)
    {
        if (session is null || observation is null || cssRegion is null || viewport is null || region is null || expires < DateTimeOffset.UtcNow)
            throw new InvalidOperationException("The browser observation expired. Capture the region again.");
        try
        {
            var confirmed = await session.ReadAsync("region", cssRegion.X, cssRegion.Y, cssRegion, cancellation);
            if (!observation.SameRegionContent(confirmed))
                throw new InvalidOperationException("The selected browser content changed during capture.");
            var stamp = confirmed.Stamp;
            CaptureRectangle Map(CaptureRectangle bounds) => RegionContextGeometry.ToImage(new(
                viewport.X + bounds.X * viewport.Width / stamp.Width,
                viewport.Y + bounds.Y * viewport.Height / stamp.Height,
                bounds.Width * viewport.Width / stamp.Width, bounds.Height * viewport.Height / stamp.Height),
                region, imageWidth, imageHeight);
            var elements = confirmed.Elements.Select(element => new CapturedElement
            {
                Id = element.Id!, ParentId = element.ParentId, Provider = "browser-dom", NativeIds = element.NativeIds,
                Role = element.Role, Name = element.Label, Text = element.Text, Value = element.Value,
                Description = element.Description, Href = element.Href, State = element.State,
                Bounds = Map(element.Bounds), VisibleBounds = Map(element.VisibleBounds ?? element.Bounds),
                Relation = element.Relation ?? "inside", Truncated = element.Truncated,
            }).ToArray();
            return new
            {
                available = elements.Length > 0, dom = confirmed.Context,
                regionContext = new CapturedRegionContext { Elements = elements, Truncated = confirmed.Truncated, Limitation = confirmed.Limitation },
                source = new { tabId = session.TabId, frameId = session.FrameId, documentId = stamp.DocumentId, browserWindowId = session.WindowId },
                locator = new { kind = "URL", value = stamp.Url }, limitation = confirmed.Limitation,
            };
        }
        finally { Release(); }
    }

    public object Release()
    {
        session?.Dispose(); session = null; observation = null;
        return new { released = true };
    }
    private static bool WindowTitleMatches(string native, string page) => native == page ||
        new[] { " - ", " – ", " — " }.Any(separator => native.StartsWith(page + separator, StringComparison.Ordinal));

    private static IEnumerable<Uri> Endpoints(string processName)
    {
        var configured = Environment.GetEnvironmentVariable("ZOMMI_BROWSER_CDP_ENDPOINT");
        if (!string.IsNullOrWhiteSpace(configured))
        {
            if (Uri.TryCreate(configured, UriKind.Absolute, out var endpoint)) yield return endpoint;
            yield break;
        }
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var root = OperatingSystem.IsMacOS() ? Path.Combine(home, "Library/Application Support") :
            Environment.GetEnvironmentVariable("XDG_CONFIG_HOME") ?? Path.Combine(home, ".config");
        var process = processName.ToLowerInvariant();
        var names = process.Contains("brave", StringComparison.Ordinal) ? new[] { "BraveSoftware/Brave-Browser" } :
            process.Contains("edge", StringComparison.Ordinal) ? new[] { OperatingSystem.IsMacOS() ? "Microsoft Edge" : "microsoft-edge" } :
            process.Contains("chromium", StringComparison.Ordinal) ? new[] { OperatingSystem.IsMacOS() ? "Chromium" : "chromium" } :
            process.Contains("chrome", StringComparison.Ordinal) ? new[] { OperatingSystem.IsMacOS() ? "Google/Chrome" : "google-chrome" } : [];
        foreach (var name in names)
        {
            string[] lines;
            try { lines = File.ReadAllLines(Path.Combine(root, name, "DevToolsActivePort")); }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException) { continue; }
            if (lines.Length >= 2 && int.TryParse(lines[0], out var port) && port is > 0 and <= 65535 &&
                lines[1].StartsWith("/devtools/browser/", StringComparison.Ordinal))
                yield return new Uri($"ws://127.0.0.1:{port}{lines[1]}");
        }
    }
    public void Dispose() { Release(); pool.Dispose(); }
}
