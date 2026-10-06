using Focalet.CaptureTool;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text.Json;
using Focalet.Capture;
using Focalet.Windows;

internal static class ChromiumClipboardAcceptance
{
    [DllImport("user32.dll")] private static extern bool SetWindowPos(nint window, nint after, int x, int y, int width, int height, uint flags);
    [DllImport("user32.dll")] private static extern nint GetForegroundWindow();
    [DllImport("dwmapi.dll")] private static extern int DwmGetWindowAttribute(nint window, int attribute, out int value, int size);

    public static async Task RunAsync(CaptureClipboardBatch batch, bool focusOnly = false)
    {
        var executable = Environment.GetEnvironmentVariable("FOCALET_TEST_CHROMIUM") ?? new[]
        {
            @"C:\Program Files\Google\Chrome\Application\chrome.exe",
            @"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe",
        }.FirstOrDefault(File.Exists) ?? throw new InvalidOperationException("Chromium is required for native clipboard acceptance.");
        var temporary = Path.Combine(Path.GetTempPath(), "focalet-clipboard-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(temporary);
        var fixture = Path.Combine(temporary, "fixture.html");
        File.WriteAllText(fixture, """
            <!doctype html><meta charset="utf-8"><title>Focalet clipboard fixture</title>
            <style>body{font:16px sans-serif;margin:24px}textarea{width:90%;height:140px}img{border:1px solid #bbb;margin:5px}</style>
            <h2>Separate images and matching context</h2>
            <textarea id="chat" aria-label="Focalet fixture image input">image-before image-after</textarea><div id="previews"></div>
            <h2>Text fallback</h2><textarea id="plain" aria-label="Focalet fixture text input">text-before text-after</textarea>
            <div role="dialog" aria-label="Focalet fixture source dialog">
              <div id="source" role="group" tabindex="0" aria-label="Focalet fixture source panel">Read-only browser source panel</div>
            </div>
            <script>
            window.enterCount=0; window.imageResult=[]; window.pasteDiagnostics=[]; window.order=[];
            document.addEventListener('paste',e=>pasteDiagnostics.push({target:e.target.id,types:Array.from(e.clipboardData.types),textLength:e.clipboardData.getData('text/plain').length}),true);
            document.addEventListener('keydown',e=>{if(e.key==='Enter')enterCount++});
            chat.addEventListener('paste',async e=>{
              const text=e.clipboardData.getData('text/plain');
              // Reproduce a terminal's text-first choice. A competing text format
              // would skip every image, as in the user's report.
              if(text){order.push('text');return;}
              const file=Array.from(e.clipboardData.items).find(i=>i.type.startsWith('image/'))?.getAsFile();
              if(!file)return; e.preventDefault(); order.push('image');
              const index=imageResult.length; imageResult.push(null);
              await new Promise(r=>setTimeout(r,400));
              const image=await createImageBitmap(file), canvas=document.createElement('canvas');
              canvas.width=image.width;canvas.height=image.height;const ctx=canvas.getContext('2d');ctx.drawImage(image,0,0);
              imageResult[index]={width:image.width,height:image.height,pixel:Array.from(ctx.getImageData(50,30,1,1).data)};
              const preview=document.createElement('img');preview.src=URL.createObjectURL(file);previews.appendChild(preview);
            });
            </script>
            """);
        var start = new ProcessStartInfo(executable) { UseShellExecute = false };
        foreach (var argument in new[] { "--no-first-run", "--no-default-browser-check", "--disable-background-networking",
            "--disable-sync", "--force-renderer-accessibility", "--remote-debugging-port=0", "--window-size=1050,900", "--user-data-dir=" + Path.Combine(temporary, "profile"), new Uri(fixture).AbsoluteUri })
            start.ArgumentList.Add(argument);
        using var browser = Process.Start(start) ?? throw new InvalidOperationException("Could not start isolated Chromium.");
        using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(90));
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
                    target.GetProperty("title").GetString() == "Focalet clipboard fixture");
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
            async Task FocusInput(string id)
            {
                using var automation = new FlaUI.UIA3.UIA3Automation
                {
                    ConnectionTimeout = TimeSpan.FromSeconds(2), TransactionTimeout = TimeSpan.FromSeconds(2),
                };
                var root = automation.FromHandle(browser.MainWindowHandle);
                var name = id switch
                {
                    "chat" => "Focalet fixture image input", "source" => "Focalet fixture source panel", _ => "Focalet fixture text input",
                };
                var exposed = Stopwatch.StartNew();
                FlaUI.Core.AutomationElements.AutomationElement? input;
                while ((input = root.FindFirstDescendant(automation.ConditionFactory.ByName(name))) is null)
                {
                    if (exposed.ElapsedMilliseconds > 5000) throw new InvalidOperationException("Native accessibility input was not exposed: " + id);
                    await Task.Delay(50, token);
                }
                if (id == "source" && input.Properties.ControlType.ValueOrDefault != FlaUI.Core.Definitions.ControlType.Group)
                    throw new InvalidOperationException("The synthetic source must expose the browser Group that previously stole the destination.");
                input.Focus();
                var focused = Stopwatch.StartNew();
                // Chromium updates DOM focus before its accessibility provider.
                // Both channels must identify the intended input before testing
                // saved native focus identity or injecting a clipboard payload.
                while (!input.Properties.HasKeyboardFocus.ValueOrDefault ||
                    automation.FocusedElement()?.Properties.Name.ValueOrDefault != name ||
                    !(await Evaluate($"document.hasFocus() && document.activeElement.id === '{id}'")).GetBoolean())
                {
                    if (focused.ElapsedMilliseconds > 2000) throw new InvalidOperationException("Native accessibility did not focus the fixture input.");
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
            await FocusInput("chat");
            if (focusOnly) { Console.WriteLine("PASS Chromium native input focus (clipboard untouched)."); return; }
            using var inputAutomation = new FlaUI.UIA3.UIA3Automation
            {
                ConnectionTimeout = TimeSpan.FromSeconds(2), TransactionTimeout = TimeSpan.FromSeconds(2),
            };
            await Evaluate("chat.setSelectionRange(13,13);true");
            var target = CapturePasteTarget.RememberWindow() ?? throw new InvalidOperationException("Browser input not focused.");
            var observation = CapturePasteTarget.ObserveInput(inputAutomation, target);
            if (observation.Kind != CaptureInputKind.Input)
                throw new InvalidOperationException("The fixture input has no native focus identity: " + observation.Kind);
            target = observation.Target;
            await FocusInput("plain");
            if (await target.IsInputCurrentAsync()) throw new InvalidOperationException("A different browser input accepted the saved editor identity.");
            // The user selects the input and caret before invoking paste.
            await FocusInput("chat");
            await Evaluate("chat.setSelectionRange(13,13);true");
            target = CapturePasteTarget.RememberWindow() ?? throw new InvalidOperationException("Browser input not focused.");
            target = CapturePasteTarget.ObserveInput(inputAutomation, target).Target;
            stage = "sequential native image and text paste";
            var result = await CapturePasteSequence.PasteAsync(batch, target, false);
            if (result.StoppedBecause is not null || result.StepsSent != 4)
                throw new InvalidOperationException("Browser sequence failed: " + result);
            // Native clipboard reads finish before this receiver's deliberately
            // asynchronous decode. Observe completion without slowing production
            // paste or mistaking an unfinished bitmap for a missing image.
            var decoded = Stopwatch.StartNew();
            while ((await Evaluate("imageResult.filter(Boolean).length")).GetInt32() < 2 && decoded.ElapsedMilliseconds < 5000)
                await Task.Delay(25, token);
            var actual = await Evaluate("imageResult");
            var colors = new[] { new[] {255,127,80,255}, new[] {0,0,255,255} };
            if (actual.GetArrayLength() != 2 || actual.EnumerateArray().Any(item => item.ValueKind != JsonValueKind.Object)) throw new InvalidOperationException("Browser did not receive two separate images: " + actual);
            for (var index = 0; index < 2; index++)
            {
                var item = actual[index];
                if (item.GetProperty("width").GetInt32() != 100 || item.GetProperty("height").GetInt32() != 60 ||
                    !item.GetProperty("pixel").EnumerateArray().Select(value => value.GetInt32()).SequenceEqual(colors[index]))
                    throw new InvalidOperationException("A separate image changed its pixels or geometry: " + item);
            }
            if (!(await Evaluate("order")).EnumerateArray().Select(value => value.GetString()).SequenceEqual(["image", "text", "image", "text"]))
                throw new InvalidOperationException("Browser paste events were reordered or duplicated.");
            var expected = ("image-before " + string.Concat(batch.TextParts) + "image-after").Replace("\r", "", StringComparison.Ordinal);
            if ((await Evaluate("chat.value")).GetString() != expected)
                throw new InvalidOperationException("Image/text paste lost context or the original draft/caret.");
            await FocusInput("plain");
            await Evaluate("plain.setSelectionRange(12,12);true");
            var textTarget = CapturePasteTarget.Remember() ?? throw new InvalidOperationException("Browser text input not focused.");
            stage = "plain text fallback";
            result = await CapturePasteSequence.PasteAsync(batch, textTarget, false);
            expected = ("text-before " + string.Concat(batch.TextParts) + "text-after").Replace("\r", "", StringComparison.Ordinal);
            if (result.StoppedBecause is not null || (await Evaluate("plain.value")).GetString() != expected)
                throw new InvalidOperationException("Plain browser input lost its text fallback: " + result);
            if ((await Evaluate("enterCount")).GetInt32() != 0)
                throw new InvalidOperationException("Paste sent Enter.");
            stage = "routing after an earlier browser input";
            var unchangedBrowserDraft = (await Evaluate("chat.value")).GetString();
            async Task FocusBrowser(string id)
            {
                if (!(browserWindow with { Focus = 0 }).Restore()) throw new InvalidOperationException("Could not activate the browser fixture source.");
                await FocusInput(id);
                if (GetForegroundWindow() != browser.MainWindowHandle) throw new InvalidOperationException("The source browser did not become the actual foreground window.");
            }
            await ForegroundRoutingAcceptance.RunAsync(batch, () => FocusBrowser("source"));
            if ((await Evaluate("chat.value")).GetString() != unchangedBrowserDraft)
                throw new InvalidOperationException("A console/custom-chat capture was pasted into the earlier browser.");
            var screenshot = await driver.CallAsync("Page.captureScreenshot", new { format = "png" }, session, token);
            File.WriteAllBytes("artifacts/capture-browser-paste.png", Convert.FromBase64String(screenshot.GetProperty("data").GetString()!));
            Console.WriteLine("PASS Chromium receives image A, text A, image B, text B; current input/caret and text fallback preserve drafts.");
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
