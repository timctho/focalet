using System.IO;
using System.Text.Json;
using System.Text.Json.Serialization;
using Zommi.Core;

namespace Zommi.Windows;

internal static class ElectronNativeHost
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
        using var codex = new CodexAppServerClient();
        var capture = new ForegroundContextCapture();
        codex.StatusChanged += status => WriteEvent("status", status);
        codex.StreamUpdate += update => WriteEvent("streamUpdate", update);
        codex.TurnCompleted += status => WriteEvent("turnCompleted", status);

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
                    var shouldExit = ProcessRequest(request, capture, codex, out var result);
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
        CodexAppServerClient codex,
        out object? result)
    {
        switch (request.Method)
        {
            case "ping":
                result = new
                {
                    platform = "windows",
                    version = typeof(ElectronNativeHost).Assembly.GetName().Version?.ToString() ?? "0.0.0",
                };
                return false;
            case "capture":
            {
                var captured = capture.Capture(DateTimeOffset.UtcNow);
                result = new
                {
                    captured.Snapshot,
                    captured.PreservePrevious,
                    PreviewText = captured.Snapshot is null
                        ? null
                        : ContextFormatter.FormatPreview(captured.Snapshot, DateTimeOffset.UtcNow),
                };
                return false;
            }
            case "selectImage":
                result = SelectImage();
                return false;
            case "startCodex":
                codex.EnsureStartedAsync().GetAwaiter().GetResult();
                result = new { codex.ThreadId, codex.IsReady };
                return false;
            case "startTurn":
            {
                var parameters = request.Params;
                var message = ReadRequiredString(parameters, "message");
                var snapshots = parameters.TryGetProperty("snapshots", out var snapshotsElement)
                    ? snapshotsElement.Deserialize<ContextSnapshot[]>(JsonOptions) ?? []
                    : [];
                var images = parameters.TryGetProperty("images", out var imagesElement)
                    ? imagesElement.Deserialize<string[]>(JsonOptions) ?? []
                    : [];
                var model = ReadOptionalString(parameters, "model");
                var effort = ReadOptionalString(parameters, "effort");
                var turnId = codex.StartTurnAsync(message, snapshots, images, model, effort).GetAwaiter().GetResult();
                result = new { accepted = true, codex.ThreadId, turnId };
                return false;
            }
            case "interruptTurn":
                result = codex.InterruptTurnAsync().GetAwaiter().GetResult();
                return false;
            case "getChatState":
                result = codex.GetChatStateAsync().GetAwaiter().GetResult();
                return false;
            case "createSession":
                result = codex.CreateSessionAsync(
                    ReadOptionalString(request.Params, "model"),
                    ReadOptionalString(request.Params, "effort")).GetAwaiter().GetResult();
                return false;
            case "switchSession":
                result = codex.SwitchSessionAsync(
                    ReadRequiredString(request.Params, "threadId")).GetAwaiter().GetResult();
                return false;
            case "shutdown":
                result = new { stopped = true };
                return true;
            default:
                throw new InvalidOperationException($"Unknown native-host method '{request.Method}'.");
        }
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

    private static string ReadRequiredString(JsonElement parameters, string name)
    {
        if (!parameters.TryGetProperty(name, out var value) || string.IsNullOrWhiteSpace(value.GetString()))
        {
            throw new ArgumentException($"Native-host parameter '{name}' is required.");
        }

        return value.GetString()!;
    }

    private static string? ReadOptionalString(JsonElement parameters, string name) =>
        parameters.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String
            ? value.GetString()
            : null;

    private static void WriteEvent(string eventName, object data) =>
        Write(new
        {
            type = "event",
            @event = eventName,
            data,
        });

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
