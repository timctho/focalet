using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text.Json;
using Zommi.Capture;
using Zommi.Windows;

internal static class ChromiumClipboardAcceptance
{
    [DllImport("user32.dll")] private static extern bool SetWindowPos(nint window, nint after, int x, int y, int width, int height, uint flags);
    [DllImport("user32.dll")] private static extern nint GetForegroundWindow();
    [DllImport("dwmapi.dll")] private static extern int DwmGetWindowAttribute(nint window, int attribute, out int value, int size);

    public static async Task RunAsync(CaptureClipboardBatch batch, bool focusOnly = false)
    {
        var executable = Environment.GetEnvironmentVariable("ZOMMI_TEST_CHROMIUM") ?? new[]
        {
            @"C:\Program Files\Google\Chrome\Application\chrome.exe",
            @"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe",
        }.FirstOrDefault(File.Exists) ?? throw new InvalidOperationException("Chromium is required for native clipboard acceptance.");
        var temporary = Path.Combine(Path.GetTempPath(), "zommi-clipboard-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(temporary);
        var fixture = Path.Combine(temporary, "fixture.html");
        File.WriteAllText(fixture, """
            <!doctype html><meta charset="utf-8"><title>Zommi clipboard fixture</title>
            <style>body{font:16px sans-serif;margin:24px}textarea{width:90%;height:180px}#chat{border:1px solid;padding:12px;margin:12px 0;min-height:30px}img{border:1px solid #bbb}</style>
            <h2>Native image paste (chat-style handler)</h2>
            <div id="chat" contenteditable="true">image-before image-after</div><img id="preview">
            <h2>Plain text fallback (same clipboard)</h2><textarea id="plain">text-before text-after</textarea>
            <script>
            window.enterCount=0; window.imageResult=null; window.pasteDiagnostics=[];
            document.addEventListener('paste',e=>pasteDiagnostics.push({target:e.target.id,types:Array.from(e.clipboardData.types),items:Array.from(e.clipboardData.items).map(i=>({kind:i.kind,type:i.type})),textLength:e.clipboardData.getData('text/plain').length}),true);
            document.addEventListener('keydown',e=>{if(e.key==='Enter')enterCount++});
            chat.addEventListener('paste',async e=>{
              const file=Array.from(e.clipboardData.items).find(i=>i.type.startsWith('image/'))?.getAsFile();
              if(!file)return; e.preventDefault();
              const image=await createImageBitmap(file), canvas=document.createElement('canvas');
              canvas.width=image.width;canvas.height=image.height;const ctx=canvas.getContext('2d');ctx.drawImage(image,0,0);
              const pixel=(x,y)=>Array.from(ctx.getImageData(x,y,1,1).data);
              window.imageResult={width:image.width,height:image.height,a:pixel(50,50),b:pixel(50,150)};
              preview.src=URL.createObjectURL(file);
            });
            </script>
            """);
        var start = new ProcessStartInfo(executable) { UseShellExecute = false };
        foreach (var argument in new[] { "--no-first-run", "--no-default-browser-check", "--disable-background-networking",
            "--disable-sync", "--remote-debugging-port=0", "--window-size=1050,900", "--user-data-dir=" + Path.Combine(temporary, "profile"), new Uri(fixture).AbsoluteUri })
            start.ArgumentList.Add(argument);
        using var browser = Process.Start(start) ?? throw new InvalidOperationException("Could not start isolated Chromium.");
        using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(45));
        var token = deadline.Token;
        var stage = "browser startup";
        CdpConnection? driver = null;
        string? session = null;
        try
        {
            string[] port;
            while (true)
            {
                try
                {
                    port = File.ReadAllLines(Path.Combine(temporary, "profile", "DevToolsActivePort"));
                    if (port.Length >= 2) break;
                }
                catch (IOException) { }
                await Task.Delay(50, token);
            }
            driver = await CdpConnection.ConnectAsync(new Uri($"ws://127.0.0.1:{port[0]}{port[1]}"), token);
            stage = "find fixture tab";
            string tab;
            while (true)
            {
                var targets = await driver.CallAsync("Target.getTargets", null, null, token);
                var candidate = targets.GetProperty("targetInfos").EnumerateArray().FirstOrDefault(target =>
                    target.GetProperty("title").GetString() == "Zommi clipboard fixture");
                if (candidate.ValueKind != JsonValueKind.Undefined) { tab = candidate.GetProperty("targetId").GetString()!; break; }
                await Task.Delay(50, token);
            }
            var attached = await driver.CallAsync("Target.attachToTarget", new { targetId = tab, flatten = true }, null, token);
            session = attached.GetProperty("sessionId").GetString()!;
            async Task<JsonElement> Evaluate(string expression)
            {
                var result = await driver.CallAsync("Runtime.evaluate", new { expression, returnByValue = true }, session, token);
                return result.GetProperty("result").GetProperty("value").Clone();
            }
            async Task ClickInput(string id)
            {
                var location = await Evaluate($"(()=>{{const r=document.getElementById('{id}').getBoundingClientRect();return {{x:r.left+r.width/2,y:r.top+r.height/2,width:innerWidth,height:innerHeight,screenX,screenY,outerWidth,outerHeight,devicePixelRatio,hasFocus:document.hasFocus()}}}})()");
                var views = NativeCaptureWindow.RenderViewBounds(browser.MainWindowHandle);
                Console.WriteLine($"Chromium native window: {browser.MainWindowTitle}; bounds={NativeCaptureWindow.Bounds(browser.MainWindowHandle)}; views={string.Join(';', views)}; page={location}");
                var viewport = views.Single();
                var x = viewport.X + location.GetProperty("x").GetDouble() * viewport.Width / location.GetProperty("width").GetDouble();
                var y = viewport.Y + location.GetProperty("y").GetDouble() * viewport.Height / location.GetProperty("height").GetDouble();
                Console.WriteLine($"Chromium fixture click: viewport={viewport}; page={location}; screen={x},{y}");
                FlaUI.Core.Input.Mouse.Click(new((int)x, (int)y), FlaUI.Core.Input.MouseButton.Left);
                var focused = Stopwatch.StartNew();
                while (!(await Evaluate($"document.hasFocus() && document.activeElement.id === '{id}'")).GetBoolean())
                {
                    if (focused.ElapsedMilliseconds > 2000) throw new InvalidOperationException("Native click did not focus the fixture input.");
                    await Task.Delay(25, token);
                }
            }
            await driver.CallAsync("Page.bringToFront", null, session, token);
            stage = "find browser window";
            while (true)
            {
                browser.Refresh();
                if (browser.MainWindowHandle != 0) break;
                await Task.Delay(50, token);
            }
            // Keep the synthetic receiver above the preceding WinForms fixture.
            // Browser DOM focus alone does not move the native window in z-order.
            SetWindowPos(browser.MainWindowHandle, new nint(-1), 0, 0, 0, 0, 0x0043);
            var browserWindow = new CapturePasteTarget(browser.MainWindowHandle, browser.MainWindowHandle,
                (uint)browser.Id, browser.StartTime.ToUniversalTime().Ticks);
            _ = browserWindow.Restore(); // Chrome redirects focus to its renderer child.
            await Task.Delay(250, token);
            DwmGetWindowAttribute(browser.MainWindowHandle, 14, out var cloaked, sizeof(int));
            Console.WriteLine($"Chromium native focus: expected={browser.MainWindowHandle}; foreground={GetForegroundWindow()}; cloaked={cloaked}");
            if (GetForegroundWindow() != browser.MainWindowHandle)
                throw new InvalidOperationException("Could not activate the synthetic browser window.");
            await ClickInput("chat");
            if (focusOnly) { Console.WriteLine("PASS Chromium native input focus (clipboard untouched)."); return; }
            var target = CapturePasteTarget.Remember() ?? throw new InvalidOperationException("Browser input not focused.");
            if (target.Window != browser.MainWindowHandle) throw new InvalidOperationException("Unexpected browser destination.");
            var sequence = CapturePasteTarget.GetClipboardSequenceNumber();
            if (!target.Paste(sequence)) throw new InvalidOperationException("Chromium image paste not dispatched.");
            stage = "read native image paste event";
            Console.WriteLine("Chromium clipboard: native paste dispatched.");
            JsonElement actual;
            while (true)
            {
                actual = await Evaluate("imageResult");
                if (actual.ValueKind != JsonValueKind.Null) break;
                await Task.Delay(50, token);
            }
            if (actual.GetProperty("width").GetInt32() != 100 || actual.GetProperty("height").GetInt32() != 176 ||
                !actual.GetProperty("a").EnumerateArray().Select(value => value.GetInt32()).SequenceEqual([255, 127, 80, 255]) ||
                !actual.GetProperty("b").EnumerateArray().Select(value => value.GetInt32()).SequenceEqual([0, 0, 255, 255]))
                throw new InvalidOperationException("Browser image handler lost selected pixels: " + actual);
            Console.WriteLine("Chromium clipboard: both image regions received.");
            await ClickInput("plain");
            await Evaluate("plain.setSelectionRange(12,12);true");
            await Task.Delay(100, token);
            var textTarget = CapturePasteTarget.Remember() ?? throw new InvalidOperationException("Browser text input not focused.");
            if (!textTarget.Paste(sequence)) throw new InvalidOperationException("Browser text paste not dispatched.");
            var expected = ("text-before " + batch.Text + "text-after").Replace("\r", "", StringComparison.Ordinal);
            stage = "read plain text paste";
            var actualText = "";
            while ((actualText = (await Evaluate("plain.value")).GetString()) != expected)
            {
                stage = $"read plain text paste (expected {expected.Length} characters, received {actualText?.Length})";
                await Task.Delay(50, token);
            }
            if ((await Evaluate("enterCount")).GetInt32() != 0 ||
                (await Evaluate("chat.textContent")).GetString() != "image-before image-after")
                throw new InvalidOperationException("Image paste submitted or replaced the original draft.");
            var screenshot = await driver.CallAsync("Page.captureScreenshot", new { format = "png" }, session, token);
            File.WriteAllBytes("artifacts/capture-browser-paste.png", Convert.FromBase64String(screenshot.GetProperty("data").GetString()!));
            Console.WriteLine("PASS Chromium native image event contains every region; text fallback and existing draft survive.");
        }
        catch (Exception error)
        {
            if (driver is not null && session is not null)
            {
                using var diagnostics = new CancellationTokenSource(TimeSpan.FromSeconds(3));
                try
                {
                    var state = await driver.CallAsync("Runtime.evaluate", new { expression = "JSON.stringify({pasteDiagnostics,imageResult,active:document.activeElement.id,plain:plain.value})", returnByValue = true }, session, diagnostics.Token);
                    Console.WriteLine("Chromium fixture diagnostics: " + state);
                    var screenshot = await driver.CallAsync("Page.captureScreenshot", new { format = "png" }, session, diagnostics.Token);
                    File.WriteAllBytes("artifacts/capture-browser-failure.png", Convert.FromBase64String(screenshot.GetProperty("data").GetString()!));
                    if (Environment.GetEnvironmentVariable("GITHUB_ACTIONS") == "true")
                    {
                        var bounds = NativeCaptureWindow.Bounds(browser.MainWindowHandle);
                        File.WriteAllBytes("artifacts/capture-browser-desktop-failure.png", ScreenCapture.CapturePng(new((int)bounds.X, (int)bounds.Y, (int)bounds.Width, (int)bounds.Height)));
                    }
                }
                catch (Exception diagnosticError) { Console.WriteLine("Could not read fixture diagnostics: " + diagnosticError.Message); }
            }
            throw new InvalidOperationException("Chromium clipboard acceptance failed at " + stage, error);
        }
        finally
        {
            driver?.Dispose();
            if (!browser.HasExited) browser.Kill(entireProcessTree: true);
            await browser.WaitForExitAsync();
            for (var attempt = 0; attempt < 20; attempt++)
            {
                try { Directory.Delete(temporary, true); break; }
                catch (IOException) { await Task.Delay(100); }
                catch (UnauthorizedAccessException) { await Task.Delay(100); }
            }
        }
    }
}
