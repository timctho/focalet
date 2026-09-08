using System.Diagnostics;
using System.Text.Json;
using Zommi.Capture;

var executable = args.FirstOrDefault() ?? Environment.GetEnvironmentVariable("ZOMMI_TEST_CHROMIUM")
    ?? throw new InvalidOperationException("Pass the Chromium executable path to run live browser tests.");
var output = Path.GetFullPath(args.ElementAtOrDefault(1) ?? "artifacts/browser-capture-acceptance");
Directory.CreateDirectory(output);
var profile = Path.Combine(Path.GetTempPath(), "zommi-browser-" + Guid.NewGuid().ToString("N"));
Directory.CreateDirectory(profile);
var start = new ProcessStartInfo(executable) { UseShellExecute = false, RedirectStandardError = true, RedirectStandardOutput = true };
var fixture = new Uri(Path.Combine(AppContext.BaseDirectory, "fixture.html")).AbsoluteUri;
if (Environment.GetEnvironmentVariable("ZOMMI_BROWSER_TEST_HEADFUL") != "1") start.ArgumentList.Add("--headless=new");
foreach (var argument in new[] { "--no-sandbox", "--disable-gpu", "--no-first-run", "--no-default-browser-check",
    "--remote-debugging-port=0", "--window-size=1000,900", "--user-data-dir=" + profile, fixture }) start.ArgumentList.Add(argument);
using var browser = Process.Start(start) ?? throw new InvalidOperationException("Could not start Chromium.");
browser.BeginErrorReadLine(); browser.BeginOutputReadLine();
using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(50));
var token = deadline.Token;
var passed = new List<string>();
using var desktopPointer = DesktopPointer.Park();
try
{
    var portFile = Path.Combine(profile, "DevToolsActivePort");
    while (!File.Exists(portFile)) { if (browser.HasExited) throw new InvalidOperationException("Chromium exited before opening CDP."); await Task.Delay(50, token); }
    var port = File.ReadAllLines(portFile);
    var endpoint = new Uri($"ws://127.0.0.1:{port[0]}{port[1]}");
    using var driver = await CdpConnection.ConnectAsync(endpoint, token);
    string tab;
    while (true)
    {
        var targets = await driver.CallAsync("Target.getTargets", null, null, token);
        var candidate = targets.GetProperty("targetInfos").EnumerateArray().FirstOrDefault(target =>
            target.GetProperty("type").GetString() == "page" && target.GetProperty("title").GetString() == "Zommi DOM capture acceptance");
        if (candidate.ValueKind != JsonValueKind.Undefined) { tab = candidate.GetProperty("targetId").GetString()!; break; }
        await Task.Delay(50, token);
    }
    var attached = await driver.CallAsync("Target.attachToTarget", new { targetId = tab, flatten = true }, null, token);
    var driverSession = attached.GetProperty("sessionId").GetString()!;
    Task<JsonElement> Command(string method, object? parameters = null) => driver.CallAsync(method, parameters, driverSession, token);
    async Task<JsonElement> Evaluate(string expression)
    {
        var result = await Command("Runtime.evaluate", new { expression, returnByValue = true });
        return result.GetProperty("result").GetProperty("value").Clone();
    }
    async Task<CaptureRectangle> Bounds(string selector)
    {
        var value = await Evaluate($"JSON.parse(JSON.stringify(document.querySelector({JsonSerializer.Serialize(selector)}).getBoundingClientRect()))");
        return new CaptureRectangle(value.GetProperty("x").GetDouble(), value.GetProperty("y").GetDouble(), value.GetProperty("width").GetDouble(), value.GetProperty("height").GetDouble());
    }
    async Task Key(string key, string code, int modifiers = 0, int virtualKey = 0)
    {
        await Command("Input.dispatchKeyEvent", new { type = "keyDown", key, code, modifiers, windowsVirtualKeyCode = virtualKey });
        await Command("Input.dispatchKeyEvent", new { type = "keyUp", key, code, modifiers, windowsVirtualKeyCode = virtualKey });
    }
    async Task Click(double x, double y)
    {
        await Command("Input.dispatchMouseEvent", new { type = "mouseMoved", x, y });
        await Command("Input.dispatchMouseEvent", new { type = "mousePressed", x, y, button = "left", clickCount = 1 });
        await Command("Input.dispatchMouseEvent", new { type = "mouseReleased", x, y, button = "left", clickCount = 1 });
    }
    void Check(bool condition, string name) { if (!condition) throw new InvalidOperationException(name); passed.Add(name); Console.WriteLine("PASS " + name); }
    if (OperatingSystem.IsWindows() && Environment.GetEnvironmentVariable("ZOMMI_TEST_CAPTURE_HOST") is { Length: > 0 } nativeHost)
    {
        while (browser.MainWindowHandle == 0) { await Task.Delay(50, token); browser.Refresh(); }
        await using var nativeProxy = new CountingBrowserProxy(endpoint);
        var nativeStart = new ProcessStartInfo(nativeHost)
        {
            UseShellExecute = false, RedirectStandardOutput = true, RedirectStandardError = true, CreateNoWindow = true,
        };
        nativeStart.ArgumentList.Add("--acceptance-browser-binding");
        nativeStart.ArgumentList.Add(browser.MainWindowHandle.ToString());
        nativeStart.Environment["ZOMMI_BROWSER_CDP_ENDPOINT"] = nativeProxy.Endpoint.AbsoluteUri;
        using var native = Process.Start(nativeStart)!;
        try
        {
            var stdout = native.StandardOutput.ReadToEndAsync(token);
            var stderr = native.StandardError.ReadToEndAsync(token);
            await native.WaitForExitAsync(token);
            var result = await stdout;
            if (native.ExitCode != 0) throw new InvalidOperationException("Windows browser binding failed: " + result + await stderr);
            using var binding = JsonDocument.Parse(result);
            Check(binding.RootElement.GetProperty("matched").GetBoolean() &&
                binding.RootElement.GetProperty("source").GetProperty("TabId").GetString() == tab &&
                binding.RootElement.GetProperty("source").GetProperty("NativeWindowId").GetString() == browser.MainWindowHandle.ToString(),
                "Windows HWND and native viewport bind to the exact CDP tab and document");
            Check(binding.RootElement.GetProperty("captures").GetArrayLength() == 3 && nativeProxy.AcceptedConnections == 1,
                "The packaged native helper reuses one browser WebSocket across three fresh captures");
            await File.WriteAllTextAsync(Path.Combine(output, "native-binding.json"), result, token);
        }
        finally { if (!native.HasExited) native.Kill(entireProcessTree: true); }
    }
    using var capture = await BrowserDomSession.ConnectAsync(endpoint, browser.Id, title => title == "Zommi DOM capture acceptance", token)
        ?? throw new InvalidOperationException("The current page was not bound.");
    Check(await BrowserDomSession.ConnectAsync(endpoint, browser.Id + 100000, _ => true, token) is null, "Reject a different native process");
    Check(await BrowserDomSession.ConnectAsync(endpoint, browser.Id, title => title == "Zommi DOM capture acceptance", token) is null,
        "A simultaneous capture cannot replace an active selection's observation");
    var textarea = await Bounds("#selection");
    await Click(textarea.X + 40, textarea.Y + 25);
    await Key("a", "KeyA", 2, 65);
    var exact = (await Evaluate("document.querySelector('#selection').value")).GetString();
    var selection = await capture.ReadAsync("capture", textarea.X + 40, textarea.Y + 25, null, token);
    Check(selection.SelectedText.Single() == exact, "Mouse and keyboard selection preserves original newlines, spaces and Unicode");
    var target = await Bounds("#target");
    var x = target.X + 15; var y = target.Y + target.Height / 2;
    await capture.BeginPickerAsync(x, y, token);
    await Command("Input.dispatchMouseEvent", new { type = "mouseMoved", x, y });
    await Key("ArrowUp", "ArrowUp", virtualKey: 38);
    await Key("ArrowUp", "ArrowUp", virtualKey: 38);
    var screenshot = await Command("Page.captureScreenshot", new { format = "png" });
    await File.WriteAllBytesAsync(Path.Combine(output, "parent-selection.png"), Convert.FromBase64String(screenshot.GetProperty("data").GetString()!), token);
    await Key("Enter", "Enter", virtualKey: 13);
    var picked = await capture.PollPickerAsync(token);
    Check(picked.Done && picked.Observation?.Elements.Single().Role == "article" &&
        picked.Observation.Elements.Single().Text.Contains("Review from Mei", StringComparison.Ordinal), "Expand the visible selection to the entire comment and confirm");
    Check((await Evaluate("window.pageClicks")).GetInt32() == 0, "Choosing context does not activate the page control");
    Check((await Evaluate("document.querySelectorAll('[data-zommi-picker]').length")).GetInt32() == 0, "Confirmation removes the selection overlay");
    await capture.BeginPickerAsync(x, y, token);
    await Key("ArrowUp", "ArrowUp", virtualKey: 38);
    await Key("ArrowUp", "ArrowUp", virtualKey: 38);
    await Key("ArrowDown", "ArrowDown", virtualKey: 40);
    await Click(x, y);
    var clickedScope = await capture.PollPickerAsync(token);
    Check(clickedScope.Done && clickedScope.Observation?.Elements.Single().Role == "p", "Shrink the parent scope and click to confirm without resetting it");
    await capture.BeginPickerAsync(x, y, token);
    await Key("Escape", "Escape", virtualKey: 27);
    var cancelled = await capture.PollPickerAsync(token);
    Check(cancelled.Done && cancelled.Observation is null, "Escape cancels without attaching context");
    var region = await Bounds("#comment");
    var cropped = await capture.ReadAsync("region", x, y, region, token);
    var cropImage = await capture.CaptureImageAsync(region, token);
    var deviceScale = (await Evaluate("devicePixelRatio")).GetDouble();
    Check(cropImage.Stamp == cropped.Stamp && Math.Abs(cropImage.Width - region.Width * deviceScale) <= 1 &&
        Math.Abs(cropImage.Height - region.Height * deviceScale) <= 1,
        "The image crop and structural region share the same document, scroll and dimensions");
    await File.WriteAllBytesAsync(Path.Combine(output, "selected-region.png"), cropImage.Png, token);
    var text = string.Join("\n", cropped.Elements.Select(element => element.Text));
    Check(text.Contains("Review from Mei", StringComparison.Ordinal) && !text.Contains("UNRELATED", StringComparison.Ordinal), "Region text belongs to the chosen comment and excludes the neighboring content");
    var partial = await capture.ReadAsync("region", x, y, new CaptureRectangle(target.X, target.Y, target.Width / 2, target.Height), token);
    Check(partial.Elements.Count == 0, "A clipped line is not reported as fully selected text");
    var all = await capture.ReadAsync("region", x, y, new CaptureRectangle(0, 0, 1000, 900), token);
    Check(!JsonSerializer.Serialize(all.Context).Contains("DO_NOT_CAPTURE", StringComparison.Ordinal), "Hidden, clipped and password content is excluded");
    var icon = await Bounds("#icon");
    var iconContext = await capture.ReadAsync("capture", icon.X + icon.Width / 2, icon.Y + icon.Height / 2, null, token);
    Check(iconContext.Nearby?.Label == "Publish" && iconContext.Nearby.Disabled == true,
        "Pointing at an icon retains its surrounding control label and disabled state");
    await driver.CallAsync("Browser.setWindowBounds", new { windowId = capture.WindowId, bounds = new { width = 1000, height = 500 } }, null, token);
    await Evaluate("window.scrollTo(0, 300); true");
    await Task.Delay(100, token);
    var tableRegion = await Bounds("#table");
    var tableImage = await capture.CaptureImageAsync(tableRegion, token);
    Check(tableImage.Stamp.ScrollY > 0 && Math.Abs(tableImage.Width - tableRegion.Width * deviceScale) <= 1,
        "Scrolled viewport crops retain document offsets and device-pixel scale");
    await File.WriteAllBytesAsync(Path.Combine(output, "scrolled-table.png"), tableImage.Png, token);
    var cell = await Bounds("#table td");
    await capture.BeginPickerAsync(cell.X + cell.Width / 2, cell.Y + cell.Height / 2, token);
    for (var level = 0; level < 3; level++) await Key("ArrowUp", "ArrowUp", virtualKey: 38);
    await Key("Enter", "Enter", virtualKey: 13);
    var tableScope = await capture.PollPickerAsync(token);
    Check(tableScope.Observation?.Elements.Single().Text == "Item\tCount\nApples\t42",
        "Expanding a cell to its table preserves row and column text boundaries");
    var stamp = await capture.StampAsync(token);
    await Evaluate("document.getElementById('target').textContent = 'Changed while capturing'; true");
    Check((await capture.StampAsync(token)).Revision > stamp.Revision, "Text changes invalidate an observation stamp");
    await Command("Page.reload");
    await Task.Delay(150, token);
    var rejected = false;
    try { await capture.ReadAsync("capture", x, y, null, token); }
    catch (InvalidOperationException) { rejected = true; }
    Check(rejected, "Reloading the same URL invalidates the old document binding");
    var secondWindow = await driver.CallAsync("Target.createTarget", new { url = fixture, newWindow = true }, null, token);
    await Task.Delay(300, token);
    var ambiguous = await BrowserDomSession.ConnectAsync(endpoint, browser.Id, title => title == "Zommi DOM capture acceptance", token);
    Check(ambiguous is null, "Two visible windows with identical titles and URLs are rejected as ambiguous");
    await driver.CallAsync("Target.closeTarget", new { targetId = secondWindow.GetProperty("targetId").GetString() }, null, token);
    using (var finalCapture = await BrowserDomSession.ConnectAsync(endpoint, browser.Id, title => title == "Zommi DOM capture acceptance", token)
        ?? throw new InvalidOperationException("The observation lease was not released.")) { }
    var currentTree = await Command("Page.getFrameTree");
    var currentFrame = currentTree.GetProperty("frameTree").GetProperty("frame").GetProperty("id").GetString();
    var observerWorld = await Command("Page.createIsolatedWorld", new { frameId = currentFrame, worldName = "zommi-context-observation" });
    var released = await Command("Runtime.evaluate", new { expression = "typeof globalThis.__zommiCapture", contextId = observerWorld.GetProperty("executionContextId").GetInt32(), returnByValue = true });
    Check(released.GetProperty("result").GetProperty("value").GetString() == "undefined", "Closing capture removes retained browser observations and listeners");
    using (var switched = await BrowserDomSession.ConnectAsync(endpoint, browser.Id, title => title == "Zommi DOM capture acceptance", token)
        ?? throw new InvalidOperationException("Could not bind the tab-switch test."))
    {
        var otherTab = await driver.CallAsync("Target.createTarget", new { url = fixture }, null, token);
        await Task.Delay(100, token);
        await driver.CallAsync("Target.activateTarget", new { targetId = tab }, null, token);
        await Task.Delay(100, token);
        var switchRejected = false;
        try { await switched.ValidateAsync(token); } catch (InvalidOperationException) { switchRejected = true; }
        Check(switchRejected, "Switching away and back to the same-URL tab invalidates an in-flight capture");
        await driver.CallAsync("Target.closeTarget", new { targetId = otherTab.GetProperty("targetId").GetString() }, null, token);
    }
    await driver.CallAsync("Browser.setWindowBounds", new { windowId = capture.WindowId, bounds = new { width = 1000, height = 900 } }, null, token);
    await Evaluate("window.scrollTo(0, 0); true");
    await Task.Delay(100, token);
    await using (var proxy = new CountingBrowserProxy(endpoint))
    {
        using var connections = new BrowserConnectionPool();
        async Task<BrowserDomSession> Reopen() => await connections.OpenAsync(proxy.Endpoint, browser.Id,
            title => title == "Zommi DOM capture acceptance", token) ?? throw new InvalidOperationException("Could not bind a reused browser connection.");
        string firstDocument;
        using (var first = await Reopen())
        {
            firstDocument = (await first.StampAsync(token)).DocumentId;
            Check(await connections.OpenAsync(proxy.Endpoint, browser.Id + 100000, _ => true, token) is null,
                "A retained connection still rejects a different native browser process");
            Check(await connections.OpenAsync(proxy.Endpoint, browser.Id, title => title == "Zommi DOM capture acceptance", token) is null,
                "A second lease on the retained connection cannot replace an active capture");
            await first.ValidateAsync(token);
            await first.BeginPickerAsync(x, y, token);
        }
        var pooledWorld = await Command("Page.createIsolatedWorld", new { frameId = currentFrame, worldName = "zommi-context-observation" });
        var pooledReleased = await Command("Runtime.evaluate", new { expression = "typeof globalThis.__zommiCapture", contextId = pooledWorld.GetProperty("executionContextId").GetInt32(), returnByValue = true });
        Check(pooledReleased.GetProperty("result").GetProperty("value").GetString() == "undefined" &&
            (await Evaluate("document.querySelectorAll('[data-zommi-picker]').length")).GetInt32() == 0,
            "Releasing a retained connection's capture removes its observers and selection overlay");
        using (var second = await Reopen())
        {
            var fresh = await second.ReadAsync("capture", x, y, null, token);
            Check(fresh.Stamp.DocumentId != firstDocument, "Reusing a connection creates a fresh document observation");
            var imageRegion = await Bounds("#comment");
            var aligned = await second.ReadAsync("region", x, y, imageRegion, token);
            var image = await second.CaptureImageAsync(imageRegion, token);
            Check(image.Stamp == aligned.Stamp && aligned.Elements.Count > 0, "A reused connection captures aligned region text and pixels");
            Check(proxy.AcceptedConnections == 1, "Repeated text, picker and image captures use one browser WebSocket");
            await Command("Page.reload");
            await Task.Delay(150, token);
            var staleRejected = false;
            try { await second.ValidateAsync(token); } catch (InvalidOperationException) { staleRejected = true; }
            Check(staleRejected, "Keeping a connection does not keep an invalid binding after page reload");
        }
        using (var reloaded = await Reopen())
        {
            await reloaded.ReadAsync("capture", x, y, null, token);
            Check(proxy.AcceptedConnections == 1, "Page reload rebinds without another browser WebSocket");
        }
        var newTab = await driver.CallAsync("Target.createTarget", new { url = fixture }, null, token);
        await Task.Delay(150, token);
        using (var switchedCapture = await Reopen())
            Check(switchedCapture.TabId == newTab.GetProperty("targetId").GetString() && proxy.AcceptedConnections == 1,
                "A retained connection binds the newly active tab without reconnecting");
        await driver.CallAsync("Target.closeTarget", new { targetId = newTab.GetProperty("targetId").GetString() }, null, token);
        await Task.Delay(100, token);
        proxy.DisconnectClients();
        using (var recovered = await Reopen())
        {
            await recovered.ReadAsync("capture", x, y, null, token);
            Check(proxy.AcceptedConnections == 2, "An idle browser disconnect triggers one fresh connection and binding");
        }
        connections.Dispose();
        var closeDeadline = Stopwatch.StartNew();
        while (proxy.ActiveConnections != 0 && closeDeadline.Elapsed < TimeSpan.FromSeconds(2)) await Task.Delay(20, token);
        Check(proxy.ActiveConnections == 0, "Closing the capture host releases its browser WebSocket");
        var closedPoolRejected = false;
        try { await Reopen(); } catch (ObjectDisposedException) { closedPoolRejected = true; }
        Check(closedPoolRejected, "Closing the capture host's connection pool prevents further browser access");
    }
    await File.WriteAllTextAsync(Path.Combine(output, "result.json"), JsonSerializer.Serialize(new { passed, count = passed.Count }, new JsonSerializerOptions { WriteIndented = true }), token);
    Console.WriteLine($"{passed.Count} live browser checks passed. Evidence: {output}");
}
finally
{
    if (!browser.HasExited) browser.Kill(entireProcessTree: true);
    await browser.WaitForExitAsync();
    try { Directory.Delete(profile, recursive: true); } catch (IOException) { }
}
