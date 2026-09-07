using System.Net;
using System.Buffers.Binary;
using System.Net.WebSockets;
using System.Text;
using System.Text.Json;

namespace Zommi.Capture;

public sealed record BrowserDocumentStamp
{
    public required string DocumentId { get; init; }
    public long Revision { get; init; }
    public long VisibilityRevision { get; init; }
    public double ScrollX { get; init; }
    public double ScrollY { get; init; }
    public double Width { get; init; }
    public double Height { get; init; }
    public double ViewportX { get; init; }
    public double ViewportY { get; init; }
    public double ViewportScale { get; init; }
    public required string Title { get; init; }
    public required string Url { get; init; }
    public bool Visible { get; init; }
}

public sealed record BrowserDomObservation : DomObservationData
{
    public required BrowserDocumentStamp Stamp { get; init; }
    public DomContext Context => new()
    {
        Mode = Mode, SelectedText = SelectedText, Elements = Elements,
        Nearby = Nearby, Truncated = Truncated, Limitation = Limitation,
    };
}

public record DomObservationData
{
    public required string Mode { get; init; }
    public IReadOnlyList<string> SelectedText { get; init; } = [];
    public IReadOnlyList<DomElementContext> Elements { get; init; } = [];
    public DomElementContext? Nearby { get; init; }
    public bool Truncated { get; init; }
    public string? Limitation { get; init; }
}

public sealed record BrowserRegionImage(byte[] Png, int Width, int Height, BrowserDocumentStamp Stamp);

/// <summary>A bounded connection to one native-verified browser window, tab and loader.</summary>
public sealed class BrowserDomSession : IDisposable
{
    private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web);
    private static readonly string Script = LoadScript();
    private readonly CdpConnection connection;
    private readonly Func<string, bool> matchesNativeWindow;
    private readonly string sessionId;
    private readonly int contextId;
    private readonly string leaseId = Guid.NewGuid().ToString("N");
    private bool disposed;
    private long? visibilityRevision;

    private BrowserDomSession(CdpConnection connection, Func<string, bool> matchesNativeWindow,
        string sessionId, int contextId, string tabId, string frameId, string loaderId, int windowId)
    {
        this.connection = connection;
        this.matchesNativeWindow = matchesNativeWindow;
        this.sessionId = sessionId;
        this.contextId = contextId;
        TabId = tabId;
        FrameId = frameId;
        LoaderId = loaderId;
        WindowId = windowId;
    }

    public string TabId { get; }
    public string FrameId { get; }
    public string LoaderId { get; }
    public int WindowId { get; }

    public static async Task<BrowserDomSession?> ConnectAsync(Uri endpoint, int processId,
        Func<string, bool> matchesNativeWindow, CancellationToken cancellationToken)
    {
        var connection = await CdpConnection.ConnectAsync(endpoint, cancellationToken).ConfigureAwait(false);
        BrowserDomSession? selected = null;
        try
        {
            var processes = await connection.CallAsync("SystemInfo.getProcessInfo", null, null, cancellationToken).ConfigureAwait(false);
            if (!processes.GetProperty("processInfo").EnumerateArray().Any(process =>
                process.GetProperty("type").GetString() == "browser" && process.GetProperty("id").GetInt32() == processId))
                return null;

            var targets = await connection.CallAsync("Target.getTargets", null, null, cancellationToken).ConfigureAwait(false);
            foreach (var target in targets.GetProperty("targetInfos").EnumerateArray())
            {
                if (target.GetProperty("type").GetString() != "page" ||
                    !matchesNativeWindow(target.GetProperty("title").GetString() ?? "")) continue;
                var tabId = target.GetProperty("targetId").GetString()!;
                var attached = await connection.CallAsync("Target.attachToTarget", new { targetId = tabId, flatten = true }, null, cancellationToken).ConfigureAwait(false);
                var session = attached.GetProperty("sessionId").GetString()!;
                var frameTree = await connection.CallAsync("Page.getFrameTree", null, session, cancellationToken).ConfigureAwait(false);
                var frame = frameTree.GetProperty("frameTree").GetProperty("frame");
                var frameId = frame.GetProperty("id").GetString()!;
                var loaderId = frame.GetProperty("loaderId").GetString()!;
                var world = await connection.CallAsync("Page.createIsolatedWorld", new { frameId, worldName = "zommi-context-observation" }, session, cancellationToken).ConfigureAwait(false);
                var context = world.GetProperty("executionContextId").GetInt32();
                var window = await connection.CallAsync("Browser.getWindowForTarget", new { targetId = tabId }, null, cancellationToken).ConfigureAwait(false);
                var candidate = new BrowserDomSession(connection, matchesNativeWindow, session, context, tabId, frameId, loaderId, window.GetProperty("windowId").GetInt32());
                var metadata = await candidate.EvaluateAsync("({ visible: document.visibilityState === 'visible', title: document.title })", cancellationToken).ConfigureAwait(false);
                if (!metadata.GetProperty("visible").GetBoolean() || !matchesNativeWindow(metadata.GetProperty("title").GetString() ?? ""))
                {
                    await connection.CallAsync("Target.detachFromTarget", new { sessionId = session }, null, cancellationToken).ConfigureAwait(false);
                    continue;
                }
                // Two visible matching tabs are ambiguous even if both have the same URL/title.
                if (selected is not null)
                {
                    await selected.InvokeAsync(new { mode = "release" }, cancellationToken).ConfigureAwait(false);
                    selected = null;
                    return null;
                }
                await candidate.EvaluateAsync(Script, cancellationToken).ConfigureAwait(false);
                var acquired = await candidate.InvokeAsync(new { mode = "acquire" }, cancellationToken).ConfigureAwait(false);
                if (!acquired.GetBoolean()) return null;
                candidate.visibilityRevision = (await candidate.StampAsync(cancellationToken).ConfigureAwait(false)).VisibilityRevision;
                selected = candidate;
            }
            if (selected is not null) await selected.ValidateAsync(cancellationToken).ConfigureAwait(false);
            return selected;
        }
        catch
        {
            selected?.Dispose();
            connection.Dispose();
            throw;
        }
        finally
        {
            if (selected is null) connection.Dispose();
        }
    }

    public async Task<BrowserDocumentStamp> StampAsync(CancellationToken cancellationToken) =>
        (await InvokeAsync(new { mode = "stamp" }, cancellationToken).ConfigureAwait(false)).Deserialize<BrowserDocumentStamp>(Json)
        ?? throw new InvalidOperationException("The browser document has no observation stamp.");

    public async Task<BrowserDomObservation> ReadAsync(string mode, double x, double y,
        CaptureRectangle? rect, CancellationToken cancellationToken)
    {
        await ValidateAsync(cancellationToken).ConfigureAwait(false);
        var result = await InvokeAsync(new { mode, x, y, rect }, cancellationToken).ConfigureAwait(false);
        var observation = result.Deserialize<BrowserDomObservation>(Json)
            ?? throw new InvalidOperationException("No browser observation was returned.");
        await ValidateAsync(cancellationToken).ConfigureAwait(false);
        var after = await StampAsync(cancellationToken).ConfigureAwait(false);
        if (observation.Stamp != after) throw new InvalidOperationException("The document changed during capture. Capture it again.");
        return observation;
    }

    public async Task BeginPickerAsync(double x, double y, CancellationToken cancellationToken)
    {
        await ValidateAsync(cancellationToken).ConfigureAwait(false);
        await InvokeAsync(new { mode = "picker", x, y }, cancellationToken).ConfigureAwait(false);
    }

    public async Task<BrowserRegionImage> CaptureImageAsync(CaptureRectangle viewportRegion, CancellationToken cancellationToken)
    {
        await ValidateAsync(cancellationToken).ConfigureAwait(false);
        var stamp = await StampAsync(cancellationToken).ConfigureAwait(false);
        if (!new CaptureRectangle(0, 0, stamp.Width, stamp.Height).Contains(viewportRegion))
            throw new InvalidOperationException("The image region is outside this browser viewport.");
        var result = await connection.CallAsync("Page.captureScreenshot", new
        {
            format = "png", fromSurface = true, captureBeyondViewport = false,
            clip = new
            {
                x = viewportRegion.X + stamp.ScrollX, y = viewportRegion.Y + stamp.ScrollY,
                width = viewportRegion.Width, height = viewportRegion.Height, scale = 1,
            },
        }, sessionId, cancellationToken).ConfigureAwait(false);
        var bytes = Convert.FromBase64String(result.GetProperty("data").GetString()!);
        if (bytes.Length < 24 || !bytes.AsSpan(0, 8).SequenceEqual(new byte[] { 137, 80, 78, 71, 13, 10, 26, 10 }))
            throw new InvalidOperationException("The browser returned an invalid region image.");
        var width = BinaryPrimitives.ReadInt32BigEndian(bytes.AsSpan(16, 4));
        var height = BinaryPrimitives.ReadInt32BigEndian(bytes.AsSpan(20, 4));
        if (width <= 0 || height <= 0 || (long)width * height > 100_000_000)
            throw new InvalidOperationException("The browser image dimensions are invalid.");
        await ValidateAsync(cancellationToken).ConfigureAwait(false);
        if (stamp != await StampAsync(cancellationToken).ConfigureAwait(false))
            throw new InvalidOperationException("The page changed while capturing the image.");
        return new BrowserRegionImage(bytes, width, height, stamp);
    }

    public async Task<(bool Done, BrowserDomObservation? Observation)> PollPickerAsync(CancellationToken cancellationToken)
    {
        await ValidateAsync(cancellationToken).ConfigureAwait(false);
        var result = await InvokeAsync(new { mode = "poll" }, cancellationToken).ConfigureAwait(false);
        var done = result.GetProperty("done").GetBoolean();
        var observation = result.TryGetProperty("result", out var captured) && captured.ValueKind == JsonValueKind.Object
            ? captured.Deserialize<BrowserDomObservation>(Json) : null;
        if (observation is not null)
        {
            var after = await StampAsync(cancellationToken).ConfigureAwait(false);
            if (observation.Stamp != after) throw new InvalidOperationException("The selected content changed. Select it again.");
        }
        return (done, observation);
    }

    public async Task CancelPickerAsync(CancellationToken cancellationToken) =>
        _ = await InvokeAsync(new { mode = "cancel" }, cancellationToken).ConfigureAwait(false);

    public async Task ValidateAsync(CancellationToken cancellationToken)
    {
        var tree = await connection.CallAsync("Page.getFrameTree", null, sessionId, cancellationToken).ConfigureAwait(false);
        var frame = tree.GetProperty("frameTree").GetProperty("frame");
        var window = await connection.CallAsync("Browser.getWindowForTarget", new { targetId = TabId }, null, cancellationToken).ConfigureAwait(false);
        var stamp = await StampAsync(cancellationToken).ConfigureAwait(false);
        if (frame.GetProperty("id").GetString() != FrameId || frame.GetProperty("loaderId").GetString() != LoaderId ||
            window.GetProperty("windowId").GetInt32() != WindowId || !stamp.Visible ||
            visibilityRevision is { } expectedVisibility && stamp.VisibilityRevision != expectedVisibility ||
            !matchesNativeWindow(stamp.Title))
            throw new InvalidOperationException("The browser window, tab or document changed. Capture it again.");
    }

    private Task<JsonElement> InvokeAsync(object options, CancellationToken cancellationToken) =>
        EvaluateAsync($"globalThis.__zommiCapture({JsonSerializer.Serialize(options, Json)}, {JsonSerializer.Serialize(leaseId)})", cancellationToken);

    private async Task<JsonElement> EvaluateAsync(string expression, CancellationToken cancellationToken)
    {
        var result = await connection.CallAsync("Runtime.evaluate", new
        {
            expression, contextId, returnByValue = true, awaitPromise = true,
        }, sessionId, cancellationToken).ConfigureAwait(false);
        if (result.TryGetProperty("exceptionDetails", out _)) throw new InvalidOperationException("Browser context is no longer available.");
        return result.GetProperty("result").TryGetProperty("value", out var value) ? value.Clone() : default;
    }

    public void Dispose()
    {
        if (disposed) return;
        disposed = true;
        try
        {
            using var timeout = new CancellationTokenSource(TimeSpan.FromMilliseconds(400));
            InvokeAsync(new { mode = "release" }, timeout.Token).GetAwaiter().GetResult();
        }
        catch (Exception exception) when (exception is OperationCanceledException or WebSocketException or InvalidOperationException or IOException) { }
        connection.Dispose();
    }

    private static string LoadScript()
    {
        using var stream = typeof(BrowserDomSession).Assembly.GetManifestResourceStream("Zommi.Capture.BrowserObservation.js")
            ?? throw new InvalidOperationException("Browser observation script is missing.");
        using var reader = new StreamReader(stream);
        return reader.ReadToEnd();
    }
}

internal sealed class CdpConnection : IDisposable
{
    private readonly ClientWebSocket socket = new();
    private int sequence;

    public static async Task<CdpConnection> ConnectAsync(Uri endpoint, CancellationToken cancellationToken)
    {
        RequireLoopback(endpoint);
        var connection = new CdpConnection();
        try
        {
            if (endpoint.Scheme is "http" or "https")
            {
                using var handler = new HttpClientHandler { AllowAutoRedirect = false, UseProxy = false };
                using var client = new HttpClient(handler);
                var versionUri = new Uri(endpoint, "/json/version");
                using var response = await client.GetAsync(versionUri, cancellationToken).ConfigureAwait(false);
                response.EnsureSuccessStatusCode();
                using var version = JsonDocument.Parse(await response.Content.ReadAsStringAsync(cancellationToken).ConfigureAwait(false));
                endpoint = new Uri(version.RootElement.GetProperty("webSocketDebuggerUrl").GetString()!);
                RequireLoopback(endpoint);
            }
            if (endpoint.Scheme is not ("ws" or "wss")) throw new InvalidOperationException("Expected a local browser debugging endpoint.");
            connection.socket.Options.Proxy = null;
            await connection.socket.ConnectAsync(endpoint, cancellationToken).ConfigureAwait(false);
            return connection;
        }
        catch { connection.Dispose(); throw; }
    }

    private static void RequireLoopback(Uri endpoint)
    {
        if (!string.IsNullOrEmpty(endpoint.UserInfo) ||
            !(endpoint.Host.Equals("localhost", StringComparison.OrdinalIgnoreCase) ||
              IPAddress.TryParse(endpoint.Host, out var address) && IPAddress.IsLoopback(address)))
            throw new InvalidOperationException("Browser capture only connects to local loopback endpoints.");
    }

    public async Task<JsonElement> CallAsync(string method, object? parameters, string? sessionId, CancellationToken cancellationToken)
    {
        var id = ++sequence;
        var request = new Dictionary<string, object?> { ["id"] = id, ["method"] = method, ["params"] = parameters ?? new { } };
        if (sessionId is not null) request["sessionId"] = sessionId;
        var bytes = JsonSerializer.SerializeToUtf8Bytes(request);
        await socket.SendAsync(bytes.AsMemory(), WebSocketMessageType.Text, true, cancellationToken).ConfigureAwait(false);
        var buffer = new byte[16384];
        while (true)
        {
            using var message = new MemoryStream();
            ValueWebSocketReceiveResult received;
            do
            {
                received = await socket.ReceiveAsync(buffer.AsMemory(), cancellationToken).ConfigureAwait(false);
                if (received.MessageType == WebSocketMessageType.Close) throw new IOException("The browser connection closed.");
                message.Write(buffer, 0, received.Count);
                if (message.Length > 4 * 1024 * 1024) throw new IOException("The browser observation exceeded its size limit.");
            } while (!received.EndOfMessage);
            using var document = JsonDocument.Parse(message.ToArray());
            var response = document.RootElement;
            if (!response.TryGetProperty("id", out var responseId) || responseId.GetInt32() != id) continue;
            if (response.TryGetProperty("error", out _)) throw new InvalidOperationException($"Browser command {method} could not complete.");
            return response.GetProperty("result").Clone();
        }
    }

    public void Dispose() => socket.Dispose();
}
