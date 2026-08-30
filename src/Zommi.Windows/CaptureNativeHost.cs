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
    }

    private static bool ProcessRequest(
        NativeHostRequest request,
        ForegroundContextCapture capture,
        out object? result)
    {
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
                var captured = TryReadCapturePoint(request.Params, out var pointerX, out var pointerY)
                    ? capture.CaptureAt(DateTimeOffset.UtcNow, pointerX, pointerY)
                    : capture.Capture(DateTimeOffset.UtcNow);
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
            case "selectImage":
                result = SelectImage();
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

    private static object SelectImage()
    {
        using var selector = new RegionSelectionForm();
        var dialogResult = selector.ShowDialog();
        if (dialogResult != DialogResult.OK || selector.Result is not { } selected)
        {
            return new
            {
                Cancelled = true,
                selector.ErrorMessage,
            };
        }

        return new
        {
            Cancelled = false,
            DataUrl = $"data:image/png;base64,{Convert.ToBase64String(selected.Png)}",
            Bounds = new
            {
                selected.Bounds.X,
                selected.Bounds.Y,
                selected.Bounds.Width,
                selected.Bounds.Height,
            },
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
