using System.Collections.Concurrent;
using System.Net;
using System.Net.Sockets;
using System.Net.WebSockets;
using System.Security.Cryptography;
using System.Text;

// Counts actual WebSocket handshakes to a real Chromium instance. It also lets
// the test disconnect an idle client without restarting or changing the page.
internal sealed class CountingBrowserProxy : IAsyncDisposable
{
    private readonly TcpListener listener = new(IPAddress.Loopback, 0);
    private readonly CancellationTokenSource stopped = new();
    private readonly ConcurrentBag<Task> clients = [];
    private readonly ConcurrentDictionary<WebSocket, byte> sockets = [];
    private readonly Uri upstream;
    private readonly Task accepting;
    private int acceptedConnections;

    public CountingBrowserProxy(Uri upstream)
    {
        this.upstream = upstream;
        listener.Start();
        Endpoint = new Uri($"ws://127.0.0.1:{((IPEndPoint)listener.LocalEndpoint).Port}/");
        accepting = AcceptAsync();
    }

    public Uri Endpoint { get; }
    public int AcceptedConnections => Volatile.Read(ref acceptedConnections);
    public int ActiveConnections => sockets.Count / 2;

    private async Task AcceptAsync()
    {
        try
        {
            while (!stopped.IsCancellationRequested)
                clients.Add(ForwardAsync(await listener.AcceptTcpClientAsync(stopped.Token)));
        }
        catch (Exception exception) when (exception is OperationCanceledException or SocketException) { }
    }

    private async Task ForwardAsync(TcpClient client)
    {
        using (client)
        using (var browser = new ClientWebSocket())
        {
            WebSocket? downstream = null;
            try
            {
                var stream = client.GetStream();
                var headers = new StringBuilder();
                var next = new byte[1];
                while (!headers.ToString().EndsWith("\r\n\r\n", StringComparison.Ordinal))
                {
                    if (headers.Length > 16384 || await stream.ReadAsync(next, stopped.Token) == 0)
                        throw new IOException("Invalid test WebSocket handshake.");
                    headers.Append((char)next[0]);
                }
                var key = headers.ToString().Split("\r\n").Single(line =>
                    line.StartsWith("Sec-WebSocket-Key:", StringComparison.OrdinalIgnoreCase)).Split(':', 2)[1].Trim();
                var accept = Convert.ToBase64String(SHA1.HashData(Encoding.ASCII.GetBytes(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")));
                browser.Options.Proxy = null;
                await browser.ConnectAsync(upstream, stopped.Token);
                await stream.WriteAsync(Encoding.ASCII.GetBytes("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: " + accept + "\r\n\r\n"), stopped.Token);
                downstream = WebSocket.CreateFromStream(stream, true, null, TimeSpan.FromSeconds(20));
                sockets.TryAdd(browser, 0);
                sockets.TryAdd(downstream, 0);
                Interlocked.Increment(ref acceptedConnections);
                var outbound = CopyAsync(downstream, browser);
                var inbound = CopyAsync(browser, downstream);
                await Task.WhenAny(outbound, inbound);
                browser.Abort();
                downstream.Abort();
                await Task.WhenAll(outbound, inbound);
            }
            catch (Exception exception) when (exception is OperationCanceledException or WebSocketException or IOException or ObjectDisposedException) { }
            finally
            {
                sockets.TryRemove(browser, out _);
                if (downstream is not null)
                {
                    sockets.TryRemove(downstream, out _);
                    downstream.Dispose();
                }
            }
        }
    }

    private async Task CopyAsync(WebSocket source, WebSocket destination)
    {
        var buffer = new byte[32768];
        while (true)
        {
            var received = await source.ReceiveAsync(buffer.AsMemory(), stopped.Token);
            if (received.MessageType == WebSocketMessageType.Close) return;
            await destination.SendAsync(buffer.AsMemory(0, received.Count), received.MessageType, received.EndOfMessage, stopped.Token);
        }
    }

    public void DisconnectClients()
    {
        foreach (var socket in sockets.Keys) socket.Abort();
    }

    public async ValueTask DisposeAsync()
    {
        stopped.Cancel();
        listener.Stop();
        DisconnectClients();
        await accepting;
        await Task.WhenAll(clients);
        stopped.Dispose();
    }
}
