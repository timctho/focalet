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
using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(OperatingSystem.IsWindows() ? 120 : 50));
var token = deadline.Token;
var passed = new List<string>();
using var desktopPointer = DesktopPointer.Park();
try
{
    var portFile = Path.Combine(profile, "DevToolsActivePort");
    string[] port;
    while (true)
    {
        if (browser.HasExited) throw new InvalidOperationException("Chromium exited before opening CDP.");
        try
        {
            port = File.ReadAllLines(portFile);
            if (port.Length >= 2 && int.TryParse(port[0], out _) && port[1].StartsWith("/devtools/browser/", StringComparison.Ordinal)) break;
        }
        catch (IOException) { } // Chrome may still hold/write the startup file.
        await Task.Delay(50, token);
    }
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
    async Task CloseTarget(string targetId)
    {
        await driver.CallAsync("Target.closeTarget", new { targetId }, null, token);
        // Chrome acknowledges closure before removing the target. Starting the
        // next binding then can attach to a closing tab whose renderer is gone.
        while (true)
        {
            var remaining = await driver.CallAsync("Target.getTargets", null, null, token);
            if (!remaining.GetProperty("targetInfos").EnumerateArray().Any(target =>
                target.GetProperty("targetId").GetString() == targetId)) return;
            await Task.Delay(20, token);
        }
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
    void Check(bool condition, string name, object? details = null)
    {
        if (!condition) throw new InvalidOperationException(name + (details is null ? "" : ": " + JsonSerializer.Serialize(details)));
        passed.Add(name);
        Console.WriteLine("PASS " + name);
    }
    // DOMRect values retain float noise at fractional display scales (for
    // example, 641.6000366 CSS px * 1.25 = 802.000046 device px). Keep the
    // one-pixel raster rounding allowance, with a subpixel numeric epsilon.
    bool WithinOneDevicePixel(int actual, double expected) => Math.Abs(actual - expected) <= 1.001;
    if (OperatingSystem.IsWindows() && Environment.GetEnvironmentVariable("ZOMMI_TEST_CAPTURE_HOST") is { Length: > 0 } nativeHost)
    {
        while (browser.MainWindowHandle == 0 || !browser.MainWindowTitle.StartsWith("Zommi DOM capture acceptance", StringComparison.Ordinal))
        { await Task.Delay(50, token); browser.Refresh(); }
        await driver.CallAsync("Target.activateTarget", new { targetId = tab }, null, token);
        NativeContentInput.Activate(browser.MainWindowHandle);
        while ((await Evaluate("document.visibilityState")).GetString() != "visible") await Task.Delay(25, token);
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
            Check(nativeProxy.Count("Target.attachToTarget") == 1 && nativeProxy.Count("Target.detachFromTarget") == 0,
                "Three native captures retain one debugger target without attach/detach churn");
            await File.WriteAllTextAsync(Path.Combine(output, "native-binding.json"), result, token);
            // Exercise the actual desktop-region pipeline, including the rule
            // that a URL alone is enough to retain aligned structural context.
            await Evaluate("document.querySelector('#products').scrollIntoView({block:'start'}); true");
            var viewport = binding.RootElement.GetProperty("viewport").Deserialize<CaptureRectangle>()!;
            // The real RPC preference must prevent every CDP handshake, even
            // when a matching browser and a usable endpoint are available.
            var policyStart = new ProcessStartInfo(nativeHost)
            {
                UseShellExecute = false, RedirectStandardInput = true,
                RedirectStandardOutput = true, RedirectStandardError = true, CreateNoWindow = true,
            };
            policyStart.ArgumentList.Add("--capture-host");
            policyStart.Environment["ZOMMI_BROWSER_CDP_ENDPOINT"] = nativeProxy.Endpoint.AbsoluteUri;
            policyStart.Environment["ZOMMI_CAPTURE_DIAGNOSTICS"] = "1";
            using (var policyHost = Process.Start(policyStart)!)
            {
                var errors = policyHost.StandardError.ReadToEndAsync(token);
                async Task<JsonDocument> Request(bool enabled)
                {
                    await policyHost.StandardInput.WriteLineAsync(JsonSerializer.Serialize(new
                    {
                        id = "policy", method = "capture", @params = new
                        {
                            browserPageDetails = enabled,
                            point = new { x = (int)viewport.X + 20, y = (int)viewport.Y + 20 },
                        },
                    }));
                    await policyHost.StandardInput.FlushAsync(token);
                    var response = await policyHost.StandardOutput.ReadLineAsync(token);
                    if (response is null) throw new Exception("Capture policy returned no response: " + await errors);
                    return JsonDocument.Parse(response);
                }
                try
                {
                    var count = nativeProxy.AcceptedConnections;
                    using var disabled = await Request(false);
                    Check(disabled.RootElement.GetProperty("ok").GetBoolean() && nativeProxy.AcceptedConnections == count,
                        "Turning off webpage details captures without any browser debugging connection");
                    using var enabled = await Request(true);
                    Check(enabled.RootElement.GetProperty("ok").GetBoolean() && nativeProxy.AcceptedConnections == count + 1,
                        "Re-enabling webpage details restores the browser connection");
                    var attachments = nativeProxy.Count("Target.attachToTarget");
                    var detaches = nativeProxy.Count("Target.detachFromTarget");
                    await Evaluate("window.__captureResizes = 0; window.addEventListener('resize', () => window.__captureResizes++); true");
                    var cssWidth = (await Evaluate("innerWidth")).GetDouble();
                    var cssHeight = (await Evaluate("innerHeight")).GetDouble();
                    var regions = new List<CaptureRectangle>();
                    foreach (var selector in new[] { "#product-a", "#product-b" })
                    {
                        var bounds = await Bounds(selector);
                        regions.Add(new CaptureRectangle(viewport.X + bounds.X * viewport.Width / cssWidth,
                            viewport.Y + bounds.Y * viewport.Height / cssHeight,
                            bounds.Width * viewport.Width / cssWidth, bounds.Height * viewport.Height / cssHeight));
                    }
                    // Repeat selection after ordinary text capture through the same
                    // actual RPC helper, not merely through a shared test pool.
                    for (var batch = 0; batch < 2; batch++)
                    {
                        NativeContentInput.Activate(browser.MainWindowHandle);
                        NativeContentInput.AssertSource(browser.MainWindowHandle, regions);
                        await policyHost.StandardInput.WriteLineAsync("{\"id\":\"multi\",\"method\":\"selectContent\",\"params\":{\"browserPageDetails\":true}}");
                        await policyHost.StandardInput.FlushAsync(token);
                        await NativeContentInput.SelectAsync(policyHost.Id, regions, token);
                        using var response = JsonDocument.Parse(await policyHost.StandardOutput.ReadLineAsync(token) ?? throw new IOException("The shared selector returned no response."));
                        await File.WriteAllTextAsync(Path.Combine(output, $"multi-{batch + 1}.json"), response.RootElement.GetRawText(), token);
                        if (!response.RootElement.TryGetProperty("result", out var selectionResult) ||
                            !selectionResult.TryGetProperty("selections", out var selectedItems))
                        {
                            policyHost.StandardInput.Close();
                            throw new InvalidOperationException("Native batch did not return two selections: " +
                                (selectionResult.ValueKind == JsonValueKind.Object ? string.Join(", ", selectionResult.EnumerateObject()
                                    .Where(property => property.Name is "cancelled" or "errorMessage" or "bounds").Select(property => $"{property.Name}: {property.Value}")) : "missing result") + await errors);
                        }
                        var resultItems = selectedItems.EnumerateArray().ToArray();
                        Check(resultItems.Length == 2 && resultItems.All(item => item.GetProperty("alignment").GetProperty("status").GetString() == "aligned") &&
                            resultItems[0].GetProperty("snapshot").GetProperty("dom").GetProperty("elements").EnumerateArray().Any(element => element.TryGetProperty("href", out var href) && href.GetString() == "https://shop.example/products/paddle-a?color=blue") &&
                            resultItems[1].GetProperty("snapshot").GetProperty("dom").GetProperty("elements").EnumerateArray().Any(element => element.TryGetProperty("href", out var href) && href.GetString() == "https://shop.example/products/paddle-b"),
                            $"Native Ctrl batch {batch + 1} retains two correctly aligned images and product URLs");
                        for (var index = 0; index < resultItems.Length; index++)
                            await File.WriteAllBytesAsync(Path.Combine(output, $"multi-{batch + 1}-{index + 1}.png"),
                                Convert.FromBase64String(resultItems[index].GetProperty("dataUrl").GetString()!.Split(',')[1]), token);
                    }
                    Check(nativeProxy.AcceptedConnections == count + 1 && nativeProxy.Count("Target.attachToTarget") == attachments &&
                        nativeProxy.Count("Target.detachFromTarget") == detaches && nativeProxy.Count("Page.captureScreenshot") == 0 &&
                        (await Evaluate("window.__captureResizes")).GetInt32() == 0,
                        "Text capture and two Ctrl batches share one connection and attachment without screenshot commands or viewport resize");
                    await policyHost.StandardInput.WriteLineAsync("{\"id\":\"stop\",\"method\":\"shutdown\",\"params\":{}}");
                    await policyHost.StandardInput.FlushAsync(token);
                    await policyHost.WaitForExitAsync(token);
                    await File.WriteAllTextAsync(Path.Combine(output, "native-input.log"), await errors, token);
                    if (policyHost.ExitCode != 0) throw new Exception(await errors);
                }
                finally { if (!policyHost.HasExited) policyHost.Kill(entireProcessTree: true); }
            }
            var scale = viewport.Width / (await Evaluate("innerWidth")).GetDouble();
            var scaleY = viewport.Height / (await Evaluate("innerHeight")).GetDouble();
            var imageA = await Bounds("#product-a");
            var imageB = await Bounds("#product-b");
            foreach (var onlyEmptyAlt in new[] { false, true })
            {
                var leftImage = onlyEmptyAlt ? imageB : imageA;
                var left = (int)Math.Floor(viewport.X + leftImage.X * scale);
                var top = (int)Math.Floor(viewport.Y + leftImage.Y * scaleY);
                var right = (int)Math.Ceiling(viewport.X + imageB.Right * scale);
                var bottom = (int)Math.Ceiling(viewport.Y + imageB.Bottom * scaleY);
                var regionStart = new ProcessStartInfo(nativeHost)
                {
                    UseShellExecute = false, RedirectStandardOutput = true, RedirectStandardError = true, CreateNoWindow = true,
                };
                regionStart.ArgumentList.Add("--acceptance-region");
                regionStart.ArgumentList.Add($"{left},{top},{right - left},{bottom - top}");
                regionStart.Environment["ZOMMI_BROWSER_CDP_ENDPOINT"] = nativeProxy.Endpoint.AbsoluteUri;
                using var regionHost = Process.Start(regionStart)!;
                var regionOutput = regionHost.StandardOutput.ReadToEndAsync(token);
                var regionErrors = regionHost.StandardError.ReadToEndAsync(token);
                try
                {
                    await regionHost.WaitForExitAsync(token);
                    var regionJson = await regionOutput;
                    if (regionHost.ExitCode != 0) throw new InvalidOperationException(await regionErrors);
                    using var regionResult = JsonDocument.Parse(regionJson);
                    var root = regionResult.RootElement;
                    var snapshot = root.GetProperty("snapshot");
                    var links = snapshot.GetProperty("regionContext").GetProperty("elements").EnumerateArray()
                        .Where(element => element.TryGetProperty("href", out var href) && href.ValueKind == JsonValueKind.String)
                        .Select(element => element.GetProperty("href").GetString()).Distinct().ToArray();
                    var expected = onlyEmptyAlt ? new[] { "https://shop.example/products/paddle-b" } :
                        new[] { "https://shop.example/products/paddle-a?color=blue", "https://shop.example/products/paddle-b" };
                    Check(root.GetProperty("alignment").GetProperty("status").GetString() == "aligned" && links.SequenceEqual(expected) &&
                        root.GetProperty("previewText").GetString()!.Contains("Link: https://shop.example/products/paddle-b", StringComparison.Ordinal),
                        onlyEmptyAlt ? "The packaged region pipeline retains URL-only context for an empty-alt image" :
                            "The packaged region pipeline captures two image links without outside captions");
                    var stem = onlyEmptyAlt ? "native-empty-alt" : "native-linked-images";
                    await File.WriteAllBytesAsync(Path.Combine(output, stem + ".png"), root.GetProperty("png").GetBytesFromBase64(), token);
                    await File.WriteAllTextAsync(Path.Combine(output, stem + ".json"), snapshot.GetRawText(), token);
                }
                finally { if (!regionHost.HasExited) regionHost.Kill(entireProcessTree: true); }
            }
            await Evaluate("window.scrollTo(0,0); true");
            Check(nativeProxy.Count("Page.captureScreenshot") == 0,
                "Native region images do not request Chrome compositor screenshots");
            desktopPointer?.Repark();
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
    Check(cropImage.Stamp == cropped.Stamp && WithinOneDevicePixel(cropImage.Width, region.Width * deviceScale) &&
        WithinOneDevicePixel(cropImage.Height, region.Height * deviceScale),
        "The image crop and structural region share the same document, scroll and dimensions",
        new { region, deviceScale, cropImage.Width, cropImage.Height,
            imageStamp = cropImage.Stamp, regionStamp = cropped.Stamp });
    await File.WriteAllBytesAsync(Path.Combine(output, "selected-region.png"), cropImage.Png, token);
    var text = string.Join("\n", cropped.Elements.Select(element => element.Text));
    Check(text.Contains("Review from Mei", StringComparison.Ordinal) && !text.Contains("UNRELATED", StringComparison.Ordinal), "Region text belongs to the chosen comment and excludes the neighboring content");
    var partial = await capture.ReadAsync("region", x, y, new CaptureRectangle(target.X, target.Y, target.Width / 2, target.Height), token);
    Check(partial.Elements.Any(element => element.Role == "text" && element.Relation == "intersects" && element.Text == "Keep the original spacing."),
        "A partially selected text node retains its content with an explicit intersection relation");
    Check(partial.Elements.All(element => element.VisibleBounds is { Width: > 0, Height: > 0 }),
        "Every region element has a visible intersection with the user's rectangle");
    var all = await capture.ReadAsync("region", x, y, new CaptureRectangle(0, 0, 1000, 900), token);
    Check(!JsonSerializer.Serialize(all.Context).Contains("DO_NOT_CAPTURE", StringComparison.Ordinal), "Hidden, clipped and password content is excluded");
    var icon = await Bounds("#icon");
    var iconContext = await capture.ReadAsync("capture", icon.X + icon.Width / 2, icon.Y + icon.Height / 2, null, token);
    Check(iconContext.Nearby?.Label == "Publish" && iconContext.Nearby.Disabled == true,
        "Pointing at an icon retains its surrounding control label and disabled state");
    var iconRegion = await capture.ReadAsync("region", icon.X, icon.Y, icon, token);
    var publish = iconRegion.Elements.Single(element => element.NativeIds?.GetValueOrDefault("domId") == "disabled");
    Check(publish.Role == "button" && publish.State?.Enabled == false && publish.Label == "Publish" && publish.Relation == "intersects",
        "An icon crop retains its containing disabled button and native identity");
    Check(iconRegion.Elements.All(element => element.ParentId is null || iconRegion.Elements.Any(parent => parent.Id == element.ParentId)),
        "Region parent references resolve within the same observation");
    await Evaluate("document.querySelector('#selection').focus(); document.querySelector('#selection').readOnly = true; true");
    var editorBounds = await Bounds("#selection");
    var editorRegion = await capture.ReadAsync("region", editorBounds.X, editorBounds.Y, editorBounds, token);
    Check(editorRegion.Elements.Any(element => element.NativeIds?.GetValueOrDefault("domId") == "selection" &&
        element.State is { Focused: true, Editable: false } && element.Value!.Contains("第二行", StringComparison.Ordinal)),
        "Region captures preserve editor value, focus and read-only state without an ambient selection");
    Check(editorRegion.SelectedText.Count == 0, "A bbox is not replaced by text selected inside the app");
    var originalEditorValue = (await Evaluate("document.querySelector('#selection').value")).GetString();
    await Evaluate("document.querySelector('#selection').value = 'x'.repeat(31000); document.querySelector('#selection').setAttribute('data-testid', 'id'.repeat(200)); true");
    var longEditor = await capture.ReadAsync("region", editorBounds.X, editorBounds.Y, editorBounds, token);
    Check(longEditor.Truncated && longEditor.Elements.Any(element => element.Truncated &&
        element.NativeIds?.GetValueOrDefault("domId") == "selection" && !element.NativeIds.ContainsKey("testId") && element.Value is { Length: > 0 and <= 30000 }),
        "Overlong values are labelled and native identifiers are omitted rather than changed into partial IDs");
    await Evaluate($"document.querySelector('#selection').value = {JsonSerializer.Serialize(originalEditorValue)}; document.querySelector('#selection').removeAttribute('data-testid'); true");
    await Evaluate("""
        (() => {
          const root = document.createElement('div'); root.id = 'overflow-fixture';
          root.style.cssText = 'position:fixed;left:900px;top:10px;width:1px;height:1px;z-index:100';
          root.innerHTML = '<div style="position:absolute;left:-170px;top:50px;width:160px;background:white"><span style="display:contents">Overflow visible context</span></div>';
          document.body.append(root);
          const secret = document.createElement('div'); secret.id = 'shadow-secret';
          secret.setAttribute('autocomplete', 'one-time-code');
          secret.style.cssText = 'position:fixed;left:730px;top:130px;width:160px;height:30px';
          secret.attachShadow({mode:'open'}).innerHTML = '<span>DO_NOT_CAPTURE_SHADOW_SECRET</span>';
          document.body.append(secret); return true;
        })()
        """);
    var overflow = await capture.ReadAsync("region", 730, 60, new(725, 55, 170, 150), token);
    Check(overflow.Elements.Any(element => element.Text == "Overflow visible context"),
        "Visible overflow descendants and display-contents text survive a crop outside the parent box");
    Check(!JsonSerializer.Serialize(overflow.Context).Contains("DO_NOT_CAPTURE_SHADOW_SECRET", StringComparison.Ordinal),
        "Sensitive ancestor exclusion crosses open shadow roots");
    await Evaluate("document.querySelector('#overflow-fixture').remove(); document.querySelector('#shadow-secret').remove(); true");
    await driver.CallAsync("Browser.setWindowBounds", new { windowId = capture.WindowId, bounds = new { width = 1000, height = 500 } }, null, token);
    await Evaluate("window.scrollTo(0, 300); true");
    await Task.Delay(100, token);
    var tableRegion = await Bounds("#table");
    var tableImage = await capture.CaptureImageAsync(tableRegion, token);
    Check(tableImage.Stamp.ScrollY > 0 && WithinOneDevicePixel(tableImage.Width, tableRegion.Width * deviceScale),
        "Scrolled viewport crops retain document offsets and device-pixel scale");
    await File.WriteAllBytesAsync(Path.Combine(output, "scrolled-table.png"), tableImage.Png, token);
    var cell = await Bounds("#table td");
    await capture.BeginPickerAsync(cell.X + cell.Width / 2, cell.Y + cell.Height / 2, token);
    for (var level = 0; level < 3; level++) await Key("ArrowUp", "ArrowUp", virtualKey: 38);
    await Key("Enter", "Enter", virtualKey: 13);
    var tableScope = await capture.PollPickerAsync(token);
    Check(tableScope.Observation?.Elements.Single().Text == "Item\tCount\nApples\t42",
        "Expanding a cell to its table preserves row and column text boundaries");
    await Evaluate("document.querySelector('#products').scrollIntoView({block:'start'}); true");
    var productA = await Bounds("#product-a");
    var productB = await Bounds("#product-b");
    var productRegion = new CaptureRectangle(productA.X, productA.Y, productB.Right - productA.X, productA.Height);
    var products = await capture.ReadAsync("region", productA.X, productA.Y, productRegion, token);
    Check(products.Elements.Count(element => element.Role == "img") == 2 && products.Elements.All(element => element.Text == "") &&
        products.Elements.Where(element => element.Role == "img").Select(element => element.Href).SequenceEqual(new[]
            { "https://shop.example/products/paddle-a?color=blue", "https://shop.example/products/paddle-b" }),
        "An image-only rectangle retains each enclosed image's own product link without captions or neighboring products");
    var noLabel = await capture.ReadAsync("region", productB.X, productB.Y, productB, token);
    Check(noLabel.Elements.Single(element => element.Role == "img").Label == null && noLabel.Elements.Single(element => element.Role == "img").Href == "https://shop.example/products/paddle-b",
        "A linked image with no alt text still exposes its destination");
    var caption = await Bounds("#product-b + span");
    var captionOnly = await capture.ReadAsync("region", caption.X, caption.Y, caption, token);
    Check(captionOnly.Elements.Any(element => element.Role == "text" && element.Href == "https://shop.example/products/paddle-b") &&
        captionOnly.Elements.All(element => element.Role != "img"), "Selecting a complete link caption retains its URL without enclosing the image");
    var roundedProduct = await capture.ReadAsync("region", productB.X, productB.Y,
        productB with { Width = productB.Width - 0.25 / deviceScale }, token);
    Check(roundedProduct.Elements.Single(element => element.Role == "img").Href == "https://shop.example/products/paddle-b",
        "A subpixel boundary difference does not discard an enclosed image link");
    var partialProduct = await capture.ReadAsync("region", productA.X, productA.Y,
        productA with { Width = productA.Width / 2 }, token);
    Check(partialProduct.Elements.Any(element => element.Role == "img" && element.Relation == "intersects" && element.Href == "https://shop.example/products/paddle-a?color=blue"),
        "A partial image retains its associated link without claiming the whole object was selected");
    await Evaluate("document.querySelector('#layers').scrollIntoView({block:'center'}); true");
    var front = await Bounds("#layer-front");
    var frontHit = await capture.ReadAsync("capture", front.X + 20, front.Y + 20, null, token);
    Check(frontHit.Elements.Single().Text == "Foreground action", "Overlapping browser objects use the visually frontmost hit target");
    var frontRegion = await capture.ReadAsync("region", front.X, front.Y, front, token);
    Check(!JsonSerializer.Serialize(frontRegion.Context).Contains("Background action", StringComparison.Ordinal),
        "A region over an opaque foreground control excludes the covered background text");
    await Evaluate("document.body.style.height='100vh'; document.body.style.overflowX='hidden'; document.querySelector('#card-grid').scrollIntoView({block:'center'}); true");
    var gridBounds = await Bounds("#card-grid");
    var grid = await capture.ReadAsync("region", gridBounds.X, gridBounds.Y, gridBounds, token);
    await File.WriteAllTextAsync(Path.Combine(output, "twelve-card-grid.json"), JsonSerializer.Serialize(grid.Context), token);
    Check(grid.Elements.Where(element => element.Href is not null).Select(element => element.Href).Distinct()
        .SequenceEqual(Enumerable.Range(1, 12).Select(number => $"https://cards.example/{number}")),
        "A scrolled 100vh body does not clip the twelve visible cards or their fractional right edge",
        new { gridBounds, grid.Stamp, links = grid.Elements.Where(element => element.Href is not null).Select(element => element.Href).Distinct() });
    Check(!JsonSerializer.Serialize(grid.Context).Contains("CLIPPED_CARD", StringComparison.Ordinal) &&
        grid.Elements.All(element => element.Href is null || !new[] { "13", "14", "15", "16" }.Any(number => element.Href.EndsWith("/" + number, StringComparison.Ordinal))),
        "The real grid overflow still excludes its clipped next row");
    var noisyGrid = await capture.ReadAsync("region", gridBounds.X, gridBounds.Y,
        gridBounds with { Height = gridBounds.Height + 0.0001 }, token);
    Check(noisyGrid.Elements.Where(element => element.Href is not null).Select(element => element.Href).Distinct()
        .SequenceEqual(Enumerable.Range(1, 12).Select(number => $"https://cards.example/{number}")),
        "Float noise at a crop edge does not include an adjacent link");
    await Evaluate("document.body.style.height=''; document.body.style.overflowX=''; true");
    await Evaluate("document.querySelector('#clipped-link-text').scrollIntoView({block:'center'}); true");
    var clippedLinkBounds = await Bounds("#clipped-link-text");
    var fractionalLink = await capture.ReadAsync("region", clippedLinkBounds.X, clippedLinkBounds.Y + 1,
        clippedLinkBounds with { Y = clippedLinkBounds.Y + 1, Height = 0.25 }, token);
    Check(fractionalLink.Elements.Any(element => element.Href == "https://cards.example/clipped"),
        "A real fractional-pixel intersection still retains the selected link");
    var clippedLink = await capture.ReadAsync("region", clippedLinkBounds.X, clippedLinkBounds.Y,
        clippedLinkBounds with { Width = 700 }, token);
    Check(!JsonSerializer.Serialize(clippedLink.Context).Contains("DO_NOT_CAPTURE_DIRECTLY_CLIPPED_LINK_TEXT", StringComparison.Ordinal),
        "Text clipped by the app's overflow is not reported as fully visible text");
    var stamp = await capture.StampAsync(token);
    await Evaluate("document.getElementById('target').textContent = 'Changed while capturing'; true");
    Check((await capture.StampAsync(token)).Revision > stamp.Revision, "Text changes invalidate an observation stamp");
    await Command("Page.reload");
    await Task.Delay(150, token);
    var rejected = false;
    try { await capture.ReadAsync("capture", x, y, null, token); }
    catch (InvalidOperationException) { rejected = true; }
    Check(rejected, "Reloading the same URL invalidates the old document binding");
    // The native gesture fixture stays topmost. Put the second window partly
    // beside it so Chrome does not hide a fully occluded page, and wait for
    // both documents to be ready before testing ambiguous visible windows.
    var secondWindow = await driver.CallAsync("Target.createTarget", new
        { url = fixture, newWindow = true, left = 700, top = 20, width = 600, height = 700 }, null, token);
    var secondAttachment = await driver.CallAsync("Target.attachToTarget", new
        { targetId = secondWindow.GetProperty("targetId").GetString(), flatten = true }, null, token);
    var secondSession = secondAttachment.GetProperty("sessionId").GetString()!;
    const string visibleFixture = "document.readyState === 'complete' && document.title === 'Zommi DOM capture acceptance' && document.visibilityState === 'visible'";
    while (true)
    {
        var secondReady = await driver.CallAsync("Runtime.evaluate", new { expression = visibleFixture, returnByValue = true }, secondSession, token);
        if (secondReady.GetProperty("result").GetProperty("value").GetBoolean() && (await Evaluate(visibleFixture)).GetBoolean()) break;
        await Task.Delay(20, token);
    }
    await driver.CallAsync("Target.detachFromTarget", new { sessionId = secondSession }, null, token);
    var ambiguous = await BrowserDomSession.ConnectAsync(endpoint, browser.Id, title => title == "Zommi DOM capture acceptance", token);
    Check(ambiguous is null, "Two visible windows with identical titles and URLs are rejected as ambiguous");
    await CloseTarget(secondWindow.GetProperty("targetId").GetString()!);
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
        await CloseTarget(otherTab.GetProperty("targetId").GetString()!);
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
            proxy.DelayNextReply("Runtime.evaluate", 250);
            using (var shortDeadline = new CancellationTokenSource(TimeSpan.FromMilliseconds(50)))
            {
                var timedOut = false;
                try { await first.StampAsync(shortDeadline.Token); }
                catch (OperationCanceledException) { timedOut = true; }
                Check(timedOut, "A delayed browser reply respects the observation deadline");
            }
            await first.ValidateAsync(token);
            Check(proxy.AcceptedConnections == 1, "An observation timeout keeps the authorized browser connection usable");
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
            Check(proxy.Count("Target.attachToTarget") == 1 && proxy.Count("Target.detachFromTarget") == 0,
                "Fresh observations reuse one attached tab without debugger banner churn");
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
        // Tab creation returns before the fixture has loaded and become visible.
        // Observe that state under the existing test deadline before rebinding.
        var newTabAttachment = await driver.CallAsync("Target.attachToTarget", new { targetId = newTab.GetProperty("targetId").GetString(), flatten = true }, null, token);
        var newTabSession = newTabAttachment.GetProperty("sessionId").GetString()!;
        while (true)
        {
            var ready = await driver.CallAsync("Runtime.evaluate", new { expression = visibleFixture, returnByValue = true }, newTabSession, token);
            if (ready.GetProperty("result").GetProperty("value").GetBoolean()) break;
            await Task.Delay(20, token);
        }
        await driver.CallAsync("Target.detachFromTarget", new { sessionId = newTabSession }, null, token);
        using (var switchedCapture = await Reopen())
            Check(switchedCapture.TabId == newTab.GetProperty("targetId").GetString() && proxy.AcceptedConnections == 1,
                "A retained connection binds the newly active tab without reconnecting");
        await CloseTarget(newTab.GetProperty("targetId").GetString()!);
        while (!(await Evaluate(visibleFixture)).GetBoolean()) await Task.Delay(20, token);
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
    await using (var rejectedProxy = new CountingBrowserProxy(endpoint) { RejectConnections = true })
    {
        using var connections = new BrowserConnectionPool();
        for (var item = 0; item < 3; item++)
        {
            try { await connections.OpenAsync(rejectedProxy.Endpoint, browser.Id, _ => true, token); }
            catch (Exception exception) when (exception is System.Net.WebSockets.WebSocketException or IOException or InvalidOperationException) { }
        }
        Check(rejectedProxy.AttemptedConnections == 1, "A declined connection is not retried for every selected item");
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
