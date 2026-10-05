using Zommi.CaptureTool;
using System.Diagnostics;
using System.Text.Json;
using FlaUI.UIA3;
using Zommi.Capture;
using Zommi.Windows;

internal static class ElectronClipboardAcceptance
{
    public static async Task RunAsync(CaptureClipboardBatch batch)
    {
        var fixture = Path.GetFullPath("tests/clipboard-electron");
        var electron = Path.Combine(fixture, "node_modules/electron/dist/electron.exe");
        if (!File.Exists(electron)) throw new InvalidOperationException("Install the locked tests/clipboard-electron dependencies first.");
        foreach (var mode in new[] { "terminal", "native-chat" })
        foreach (var slowerImages in new[] { false, true })
        {
            var pace = slowerImages ? "slower" : "fast";
            var temporary = Path.Combine(Path.GetTempPath(), "zommi-electron-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(temporary);
            var start = new ProcessStartInfo(electron) { UseShellExecute = false };
            // Keep the delayed double-read regression in the compatibility profile,
            // and exercise the default profile with ordinary asynchronous IPC reads.
            foreach (var argument in new[] { Path.Combine(fixture, "main.cjs"), temporary, mode, slowerImages ? "1500" : "100" }) start.ArgumentList.Add(argument);
            start.Environment.Remove("ELECTRON_RUN_AS_NODE");
            using var process = Process.Start(start) ?? throw new InvalidOperationException("Electron fixture did not start.");
            try
            {
                await ForegroundRoutingAcceptance.WaitFor(() => File.Exists(Path.Combine(temporary, "ready")), "Electron fixture was not ready.", 20000);
                using var ready = JsonDocument.Parse(File.ReadAllText(Path.Combine(temporary, "ready")));
                var window = new nint(long.Parse(ready.RootElement.GetProperty("window").GetString()!));
                var target = new CapturePasteTarget(window, 0, (uint)process.Id, process.StartTime.ToUniversalTime().Ticks);
                if (!target.Restore()) throw new InvalidOperationException("Electron fixture did not acquire native foreground.");
                using var automation = new UIA3Automation { ConnectionTimeout = TimeSpan.FromSeconds(2), TransactionTimeout = TimeSpan.FromSeconds(2) };
                var input = automation.FromHandle(window).FindFirstDescendant(automation.ConditionFactory.ByName("Electron fixture input"))
                    ?? throw new InvalidOperationException("Electron fixture input is unavailable.");
                input.Focus();
                await ForegroundRoutingAcceptance.WaitFor(() => input.Properties.HasKeyboardFocus.ValueOrDefault, "Electron input did not acquire focus.");
                target = CapturePasteTarget.RememberWindow() ?? throw new InvalidOperationException("Electron input was not current.");
                var elapsed = Stopwatch.StartNew();
                var result = await CapturePasteSequence.PasteAsync(batch, target, false, slowerImages);
                elapsed.Stop();
                if (result.StoppedBecause is not null) throw new InvalidOperationException("Electron sequence stopped: " + result);
                await Task.Delay(1800);
                var json = File.ReadAllText(Path.Combine(temporary, "result.json"));
                using var document = JsonDocument.Parse(json);
                var events = document.RootElement.GetProperty("events").EnumerateArray().ToArray();
                Console.WriteLine($"Electron {mode} {pace}: " + JsonSerializer.Serialize(new {
                    elapsedMs = elapsed.ElapsedMilliseconds, events = events.Select(e => e.GetProperty("kind").GetString()), diagnostics = document.RootElement.GetProperty("diagnostics") }));
                if (!events.Select(e => e.GetProperty("kind").GetString()).SequenceEqual(new[] { "image", "text", "image", "text" }))
                    throw new InvalidOperationException($"Electron {mode} did not display image A, context A, image B, context B in order.");
                for (var index = 0; index < batch.Items.Count; index++)
                {
                    var item = batch.Items[index];
                    var picture = events[index * 2];
                    using var stream = new MemoryStream(item.Png);
                    using var bitmap = new System.Drawing.Bitmap(stream);
                    var pixel = bitmap.GetPixel(50, 30);
                    if (picture.GetProperty("width").GetInt32() != item.Width || picture.GetProperty("height").GetInt32() != item.Height ||
                        !picture.GetProperty("pixel").EnumerateArray().Select(v => v.GetInt32()).SequenceEqual(new int[] { pixel.R, pixel.G, pixel.B, pixel.A }))
                        throw new InvalidOperationException("Electron native clipboard changed image geometry/pixels.");
                    if (events[index * 2 + 1].GetProperty("value").GetString() != batch.TextParts[index])
                        throw new InvalidOperationException("Electron native clipboard lost region context.");
                    var contextDelay = events[index * 2 + 1].GetProperty("receivedAt").GetInt64() - picture.GetProperty("receivedAt").GetInt64();
                    if (!slowerImages && contextDelay >= 2000)
                        throw new InvalidOperationException($"Fast image paste retained an unnecessary long delay: {contextDelay} ms.");
                }
                if (document.RootElement.GetProperty("enters").GetInt32() != 0 ||
                    events[^1].GetProperty("draft").GetString() != ("draft-before " + string.Concat(batch.TextParts) + "draft-after").Replace("\r\n", "\n"))
                    throw new InvalidOperationException("Electron paste changed the draft/caret or sent Enter.");
                await Task.Delay(200);
                Directory.CreateDirectory("artifacts");
                var bounds = automation.FromHandle(window).BoundingRectangle;
                File.WriteAllBytes($"artifacts/capture-electron-{mode}-{pace}.png", ScreenCapture.CapturePng(bounds));
                Console.WriteLine($"PASS Electron {mode} {pace} native readImage retains both images through asynchronous preview/save and ordered context.");
            }
            finally
            {
                if (!process.HasExited)
                {
                    process.CloseMainWindow();
                    try { await process.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(5)); }
                    catch (TimeoutException) { process.Kill(entireProcessTree: true); }
                }
                await process.WaitForExitAsync();
                for (var attempt = 0; attempt < 20; attempt++)
                {
                    try { Directory.Delete(temporary, recursive: true); break; }
                    catch (IOException) when (attempt < 19) { await Task.Delay(250); }
                }
            }
        }
    }
}
