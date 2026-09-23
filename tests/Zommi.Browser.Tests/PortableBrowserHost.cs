using System.Diagnostics;
using System.Text.Json;
using Zommi.Capture;

internal static class PortableBrowserHost
{
    internal static async Task VerifyAsync(string executable, Uri endpoint, int processId,
        Func<string, Task<JsonElement>> evaluate, Func<string, Task<CaptureRectangle>> bounds,
        Action<bool, string> check, CancellationToken cancellation)
    {
        var start = new ProcessStartInfo(executable.EndsWith(".dll", StringComparison.Ordinal) ? "dotnet" : executable)
        { UseShellExecute = false, RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true };
        if (executable.EndsWith(".dll", StringComparison.Ordinal)) start.ArgumentList.Add(executable);
        start.Environment["ZOMMI_BROWSER_CDP_ENDPOINT"] = endpoint.ToString();
        using var process = Process.Start(start) ?? throw new InvalidOperationException("Portable browser host did not start.");
        process.BeginErrorReadLine();
        try
        {
            var sequence = 0;
            async Task<JsonElement> Request(string method, object? parameters = null)
            {
                var id = (++sequence).ToString();
                await process.StandardInput.WriteLineAsync(JsonSerializer.Serialize(new { id, method, @params = parameters }));
                var line = await process.StandardOutput.ReadLineAsync(cancellation) ?? throw new InvalidOperationException("Portable browser host exited.");
                using var response = JsonDocument.Parse(line);
                check(response.RootElement.GetProperty("id").GetString() == id, "Portable host responses keep their request identity");
                return response.RootElement.Clone();
            }
            var rect = await bounds("#line");
            var viewport = await evaluate("({width:innerWidth,height:innerHeight})");
            var width = viewport.GetProperty("width").GetDouble();
            var height = viewport.GetProperty("height").GetDouble();
            object Parameters(int pid, bool ambiguous = false, bool distorted = false)
            {
                var source = new { nativeWindowId = "fixture-window", processId = pid, windowTitle = "Zommi DOM capture acceptance - Browser" };
                return new
                {
                    source, windows = ambiguous
                        ? new object[] { source, source with { nativeWindowId = "another-window" } }
                        : new object[] { new { nativeWindowId = "decorations", processId = (int?)null, windowTitle = "Window manager" }, source },
                    viewport = new CaptureRectangle(100, 200, width * 2, height * 2 + (distorted ? 120 : 0)),
                    bounds = new CaptureRectangle(100 + rect.X * 2, 200 + rect.Y * 2, rect.Width * 2, rect.Height * 2),
                    imageWidth = (int)Math.Round(rect.Width * 2), imageHeight = (int)Math.Round(rect.Height * 2),
                };
            }
            var ping = await Request("ping");
            check(ping.GetProperty("result").GetProperty("ready").GetBoolean(), "Portable browser host starts without a desktop runtime dependency");
            var observed = await Request("observe", Parameters(processId));
            check(observed.GetProperty("result").GetProperty("available").GetBoolean(), "Portable observer binds the native browser process and viewport");
            var oldOutside = await evaluate("document.querySelector('#outside').textContent");
            await evaluate("document.querySelector('#outside').textContent='Changed outside region'");
            var confirmed = await Request("confirm");
            if (!confirmed.GetProperty("ok").GetBoolean() || !confirmed.GetProperty("result").GetProperty("available").GetBoolean()) throw new InvalidOperationException(confirmed.ToString());
            check(confirmed.GetProperty("result").GetProperty("available").GetBoolean(),
                "Portable region confirmation tolerates unrelated document updates");
            var elements = confirmed.GetProperty("result").GetProperty("regionContext").GetProperty("elements");
            check(elements.EnumerateArray().Any(element => element.GetProperty("text").GetString()?.Contains("Keep the original spacing.", StringComparison.Ordinal) == true),
                "Portable host returns the bounded region text");
            check(elements.EnumerateArray().All(element => {
                var visible = element.GetProperty("visibleBounds");
                return visible.GetProperty("x").GetDouble() >= -.001 && visible.GetProperty("y").GetDouble() >= -.001 &&
                    visible.GetProperty("x").GetDouble() + visible.GetProperty("width").GetDouble() <= Math.Round(rect.Width * 2) + .001 &&
                    visible.GetProperty("y").GetDouble() + visible.GetProperty("height").GetDouble() <= Math.Round(rect.Height * 2) + .001;
            }), "Portable host maps native points and CSS into image pixels");
            await evaluate($"document.querySelector('#outside').textContent={JsonSerializer.Serialize(oldOutside.GetString())}");
            await Request("observe", Parameters(processId));
            var oldTarget = await evaluate("document.querySelector('#target').innerHTML");
            await evaluate("document.querySelector('#target').textContent='Changed selected text'");
            check(!(await Request("confirm")).GetProperty("ok").GetBoolean(), "Portable host rejects selected content changes");
            await evaluate($"document.querySelector('#target').innerHTML={JsonSerializer.Serialize(oldTarget.GetString())}");
            var wrongProcess = await Request("observe", Parameters(-1));
            check(!wrongProcess.GetProperty("result").GetProperty("available").GetBoolean(), "Portable host refuses a different native process");
            var ambiguous = await Request("observe", Parameters(processId, ambiguous: true));
            check(!ambiguous.GetProperty("result").GetProperty("available").GetBoolean(), "Portable host refuses ambiguous native windows");
            check(!(await Request("observe", Parameters(processId, distorted: true))).GetProperty("ok").GetBoolean(), "Portable host rejects mismatched viewport geometry");
            await Request("observe", Parameters(processId));
            check((await Request("confirm")).GetProperty("ok").GetBoolean(), "Portable host recovers after rejected observations");
            await Request("shutdown");
            await process.WaitForExitAsync(cancellation);
            check(process.ExitCode == 0, "Portable host releases browser access on shutdown");
        }
        finally { if (!process.HasExited) { process.Kill(entireProcessTree: true); await process.WaitForExitAsync(CancellationToken.None); } }
    }
}
