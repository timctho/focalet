using System.IO;
using System.Text.Json;
using System.Text.Json.Serialization;
using Zommi.Capture;

namespace Zommi.Windows;

internal static class CaptureNativeHost
{
    private static readonly object OutputLock = new();
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        PropertyNameCaseInsensitive = true,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        Converters = { new JsonStringEnumConverter(JsonNamingPolicy.CamelCase) },
    };

    public static int Run()
    {
        ApplicationConfiguration.Initialize();
        using var capture = new ForegroundContextCapture();

        try
        {
            string? line;
            while ((line = Console.In.ReadLine()) is not null)
            {
                NativeHostRequest? request;
                try
                {
                    request = JsonSerializer.Deserialize<NativeHostRequest>(line, JsonOptions);
                }
                catch (JsonException exception)
                {
                    WriteResponse(null, false, null, $"Invalid native-host request: {exception.Message}");
                    continue;
                }

                if (request is null || string.IsNullOrWhiteSpace(request.Id) || string.IsNullOrWhiteSpace(request.Method))
                {
                    WriteResponse(request?.Id, false, null, "Native-host requests require id and method.");
                    continue;
                }

                try
                {
                    var shouldExit = ProcessRequest(request, capture, out var result);
                    WriteResponse(request.Id, true, result, null);
                    if (shouldExit)
                    {
                        break;
                    }
                }
                catch (Exception exception)
                {
                    WriteResponse(request.Id, false, null, exception.Message);
                }
            }

            return 0;
        }
        catch (IOException exception)
        {
            Console.Error.Write(exception);
            return 1;
        }
        finally { BrowserObservationBridge.CloseConnections(); }
    }

    private static bool ProcessRequest(
        NativeHostRequest request,
        ForegroundContextCapture capture,
        out object? result)
    {
        if (request.Method is "capture" or "selectContent" or "selectContext" or "selectImage")
            BrowserObservationBridge.SetPageDetailsEnabled(!(request.Params.ValueKind == JsonValueKind.Object &&
                request.Params.TryGetProperty("browserPageDetails", out var pageDetails) && pageDetails.ValueKind == JsonValueKind.False));
        switch (request.Method)
        {
            case "ping":
                result = new
                {
                    platform = "windows",
                    version = typeof(CaptureNativeHost).Assembly.GetName().Version?.ToString() ?? "0.0.0",
                };
                return false;
            case "capture":
            {
                void TargetResolved()
                {
                    if (request.Params.ValueKind == JsonValueKind.Object &&
                        request.Params.TryGetProperty("reportReady", out var reportReady) &&
                        reportReady.ValueKind == JsonValueKind.True)
                    {
                        Write(new { type = "captureReady", id = request.Id });
                    }
                }
                var captured = TryReadCapturePoint(request.Params, out var pointerX, out var pointerY)
                    ? capture.CaptureAt(DateTimeOffset.UtcNow, pointerX, pointerY, TargetResolved)
                    : capture.Capture(DateTimeOffset.UtcNow, TargetResolved);
                var previewStartedAt = System.Diagnostics.Stopwatch.GetTimestamp();
                var previewText = captured.Snapshot is null
                    ? null
                    : ContextPreviewFormatter.Format(captured.Snapshot);
                var previewMilliseconds = (long)System.Diagnostics.Stopwatch.GetElapsedTime(previewStartedAt).TotalMilliseconds;
                result = new
                {
                    captured.Snapshot,
                    captured.PreservePrevious,
                    captured.ElapsedMilliseconds,
                    captured.Timings,
                    PreviewMilliseconds = previewMilliseconds,
                    PreviewText = previewText,
                };
                return false;
            }
            case "selectContent":
                result = SelectContent(ReturnProcessId(request.Params));
                return false;
            case "selectContext":
                result = SelectContext(capture, ReturnProcessId(request.Params));
                return false;
            case "selectImage":
                result = SelectImage(ReturnProcessId(request.Params));
                return false;
            case "shutdown":
                result = new { stopped = true };
                return true;
            default:
                throw new InvalidOperationException($"Unknown native-host method '{request.Method}'.");
        }
    }

    private static bool TryReadCapturePoint(JsonElement parameters, out int x, out int y)
    {
        x = 0;
        y = 0;
        return parameters.ValueKind == JsonValueKind.Object &&
            parameters.TryGetProperty("point", out var point) &&
            point.ValueKind == JsonValueKind.Object &&
            point.TryGetProperty("x", out var xValue) &&
            xValue.TryGetInt32(out x) &&
            point.TryGetProperty("y", out var yValue) &&
            yValue.TryGetInt32(out y);
    }

    private static uint ReturnProcessId(JsonElement parameters) =>
        parameters.ValueKind == JsonValueKind.Object &&
        parameters.TryGetProperty("returnProcessId", out var value) &&
        value.TryGetUInt32(out var processId) && processId != uint.MaxValue
            ? processId
            : 0;

    private static object SelectImage(uint returnProcessId)
    {
        using var selector = new RegionSelectionForm(returnProcessId: returnProcessId,
            captureAlignedRegion: RegionContextCapture.Capture);
        var dialogResult = selector.ShowDialog();
        if (dialogResult != DialogResult.OK || selector.Result is not { } selected)
        {
            return new
            {
                Cancelled = true,
                selector.ErrorMessage,
            };
        }

        return ImageResult(selected);
    }

    private static object ImageResult(RegionSelectionResult selected) => new
        {
            Cancelled = false,
            DataUrl = $"data:image/png;base64,{Convert.ToBase64String(selected.Png)}",
            selected.Snapshot,
            selected.Alignment,
            PreviewText = selected.Snapshot is null
                ? $"Image only — {selected.Alignment?.Reason ?? "No aligned text was exposed for this region."}"
                : ContextPreviewFormatter.Format(selected.Snapshot),
            Bounds = new
            {
                selected.Bounds.X,
                selected.Bounds.Y,
                selected.Bounds.Width,
                selected.Bounds.Height,
            },
        };

    private static object SelectContent(uint returnProcessId)
    {
        using var selector = new ContentSelectionForm(returnProcessId);
        if (selector.ShowDialog() != DialogResult.OK || selector.Selections.Count == 0)
            return new { Cancelled = true, selector.ErrorMessage };
        Application.DoEvents();
        Thread.Sleep(80);
        var results = new List<object>();
        foreach (var selected in selector.Selections)
        {
            bool Matches() => NativeCaptureWindow.Bounds(selected.Window) == selected.WindowBounds &&
                NativeCaptureWindow.Title(selected.Window) == selected.WindowTitle &&
                NativeCaptureWindow.ProcessId(selected.Window) == selected.ProcessId;
            if (selected.Window != 0)
            {
                if (!Matches()) return new { Cancelled = true, ErrorMessage = "The selected window changed. Select the content again." };
                if (selected.WholeWindow)
                {
                    // Explicit whole-window sharing brings that source forward.
                    // Owned dialogs still remain above it and fail the coverage check.
                    NativeCaptureWindow.Activate(selected.Window);
                    Application.DoEvents();
                    Thread.Sleep(80);
                }
                if (!Matches() || NativeCaptureWindow.ForRegion(selected.Region) != selected.Window)
                    return new { Cancelled = true, ErrorMessage = "The selected window changed or is covered. Select the content again." };
            }
            results.Add(ImageResult(RegionContextCapture.Capture(selected.Region)));
        }
        return results.Count == 1 ? results[0] : new { Cancelled = false, Selections = results };
    }

    private static object SelectContext(ForegroundContextCapture capture, uint returnProcessId)
    {
        using var selector = new PointSelectionForm(returnProcessId);
        var dialogResult = selector.ShowDialog();
        if (dialogResult != DialogResult.OK || selector.Result is not { } point)
        {
            return new { Cancelled = true };
        }

        // The transparent picker must leave the z-order before WindowFromPoint
        // resolves the user's target rather than Zommi's own overlay.
        Application.DoEvents();
        Thread.Sleep(80);
        var targetWindow = NativeCaptureWindow.At(point);
        using var browser = BrowserObservationBridge.TryOpen(targetWindow);
        if (browser is not null)
        {
            try
            {
                var observation = browser.Pick(point);
                if (observation is null) return new { Cancelled = true };
                var snapshot = browser.Snapshot(observation);
                return new { Cancelled = false, Snapshot = snapshot, PreviewText = ContextPreviewFormatter.Format(snapshot) };
            }
            catch (Exception exception) when (BrowserObservationBridge.IsUnavailable(exception))
            {
                return new { Cancelled = true, ErrorMessage = "The page changed while selecting. Select the content again." };
            }
        }
        var choices = capture.ScopeChoices(point);
        if (choices.Count > 0)
        {
            using var scopeSelector = new PointSelectionForm(returnProcessId, choices);
            if (scopeSelector.ShowDialog() != DialogResult.OK) return new { Cancelled = true };
            Application.DoEvents();
            try
            {
                var selected = scopeSelector.SelectedScope?.Capture();
                if (selected is null) return new { Cancelled = true, ErrorMessage = "The element changed. Select it again." };
                return new { Cancelled = false, Snapshot = selected, PreviewText = ContextPreviewFormatter.Format(selected) };
            }
            catch (Exception exception) when (BrowserObservationBridge.IsUnavailable(exception))
            {
                return new { Cancelled = true, ErrorMessage = "The element is no longer available. Select it again." };
            }
        }
        var captured = capture.CaptureAt(DateTimeOffset.UtcNow, point.X, point.Y);
        var previewText = captured.Snapshot is null
            ? null
            : ContextPreviewFormatter.Format(captured.Snapshot);
        return new
        {
            Cancelled = false,
            captured.Snapshot,
            captured.PreservePrevious,
            captured.ElapsedMilliseconds,
            captured.Timings,
            PreviewText = previewText,
        };
    }

    private static void WriteResponse(string? id, bool ok, object? result, string? error) =>
        Write(new
        {
            type = "response",
            id,
            ok,
            result,
            error,
        });

    private static void Write(object envelope)
    {
        var json = JsonSerializer.Serialize(envelope, JsonOptions);
        lock (OutputLock)
        {
            Console.Out.WriteLine(json);
            Console.Out.Flush();
        }
    }

    private sealed record NativeHostRequest
    {
        public string? Id { get; init; }

        public string? Method { get; init; }

        public JsonElement Params { get; init; }
    }
}
