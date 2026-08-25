using System.IO;
using System.Text.Json;
using Zommi.Core;

namespace Zommi.Windows;

internal static class AcceptanceProbe
{
    public static int RunSharedMemoryProbe(IReadOnlyList<string> args)
    {
        try
        {
            var sessionId = RuntimeOptions.Read(args, "--session");
            if (string.IsNullOrWhiteSpace(sessionId))
            {
                Console.Error.Write("--acceptance-probe requires --session <UUID>.");
                return 2;
            }

            var secondsText = RuntimeOptions.Read(args, "--seconds");
            var seconds = int.TryParse(secondsText, out var parsedSeconds) ? Math.Clamp(parsedSeconds, 1, 300) : 30;
            var now = DateTimeOffset.UtcNow;
            var store = new StateStore(StateStore.GetDefaultRoot());
            store.WriteBinding(new BindingState
            {
                SessionId = sessionId,
                Mode = CaptureMode.Active,
                UpdatedAtUtc = now,
            });

            using var snapshots = SharedSnapshotStore.CreateOwner();
            var snapshot = new ContextSnapshot
            {
                SnapshotId = "windows-shared-memory-probe",
                ObservedAtUtc = now,
                ExpiresAtUtc = now.AddMinutes(5),
                SurfaceKind = "Browser",
                Application = "Zommi acceptance probe",
                ProcessName = "zommi-acceptance",
                WindowTitle = "Synthetic acceptance surface",
                Locator = new LocatorInfo
                {
                    Kind = "URL",
                    Value = "https://windows-runtime-probe.example/zommi",
                },
                IndicatedTarget = new IndicatedTargetInfo
                {
                    Name = "Acceptance target",
                    ControlType = "Button",
                    AutomationId = "acceptance-target",
                    Confidence = "high",
                },
                Confidence = "high",
            };
            snapshots.WriteSnapshot(snapshot);

            Console.Out.WriteLine($"READY {sessionId}");
            Console.Out.Flush();
            var deadline = DateTimeOffset.UtcNow.AddSeconds(seconds);
            while (DateTimeOffset.UtcNow < deadline)
            {
                snapshots.WriteSnapshot(snapshot);
                Thread.Sleep(TimeSpan.FromMilliseconds(100));
            }
            return 0;
        }
        catch (Exception exception)
        {
            Console.Error.Write(exception);
            return 1;
        }
    }

    public static int CaptureOnce()
    {
        try
        {
            var result = new ForegroundContextCapture().Capture(DateTimeOffset.UtcNow);
            Console.Out.Write(JsonSerializer.Serialize(result, new JsonSerializerOptions
            {
                PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
            }));
            return result.Snapshot is null ? 3 : 0;
        }
        catch (Exception exception)
        {
            Console.Error.Write(exception);
            return 1;
        }
    }

    public static int DiscoverWsl()
    {
        try
        {
            var result = HookInstaller.ResolveWslHook();
            Console.Out.Write(JsonSerializer.Serialize(new
            {
                hooksPath = result.HooksPath,
                command = result.Command,
            }));
            return 0;
        }
        catch (Exception exception)
        {
            Console.Error.Write(exception);
            return 1;
        }
    }

    public static int WslLaunchPlan()
    {
        var validationDirectory = Path.Combine(Path.GetTempPath(), $"zommi-wsl-command-{Guid.NewGuid():N}");
        try
        {
            var environment = HookInstaller.ResolveWslHook("acceptance-launch-token");
            var startInfo = WslCodexLauncher.BuildStartInfo("wt.exe", environment, useWindowsTerminal: true);
            var validationHooksPath = Path.Combine(validationDirectory, "hooks.json");
            _ = CodexHookConfiguration.Install(validationHooksPath, environment.Command);
            var hookConfigurationValidated = CodexHookConfiguration.IsInstalled(validationHooksPath);
            Console.Out.Write(JsonSerializer.Serialize(new
            {
                startInfo.FileName,
                arguments = startInfo.ArgumentList,
                environment.DistroName,
                environment.LinuxHome,
                environment.Command,
                hookConfigurationValidated,
            }));
            return 0;
        }
        catch (Exception exception)
        {
            Console.Error.Write(exception);
            return 1;
        }
        finally
        {
            try
            {
                Directory.Delete(validationDirectory, recursive: true);
            }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
            {
                // Acceptance cleanup must not obscure the actual probe result.
            }
        }
    }

    public static int AppServerHandshake()
    {
        try
        {
            using var client = new CodexAppServerClient();
            var statuses = new List<string>();
            client.StatusChanged += status =>
            {
                statuses.Add(status);
                Console.Error.WriteLine(status);
                Console.Error.Flush();
            };
            client.EnsureStartedAsync().WaitAsync(TimeSpan.FromSeconds(45)).GetAwaiter().GetResult();
            Console.Out.Write(JsonSerializer.Serialize(new
            {
                ready = client.IsReady,
                threadId = client.ThreadId,
                statuses,
            }));
            return client.IsReady ? 0 : 3;
        }
        catch (Exception exception)
        {
            Console.Error.Write(exception);
            return 1;
        }
    }

    public static int AppServerTurn()
    {
        try
        {
            using var client = new CodexAppServerClient();
            var response = new System.Text.StringBuilder();
            var statuses = new List<string>();
            var completed = new TaskCompletionSource<string>(TaskCreationOptions.RunContinuationsAsynchronously);
            client.AgentMessageDelta += delta => response.Append(delta);
            client.StatusChanged += statusMessage =>
            {
                statuses.Add(statusMessage);
                Console.Error.WriteLine(statusMessage);
                Console.Error.Flush();
            };
            client.TurnCompleted += status => completed.TrySetResult(status);
            client.EnsureStartedAsync().WaitAsync(TimeSpan.FromSeconds(45)).GetAwaiter().GetResult();

            var now = DateTimeOffset.UtcNow;
            var context = new ContextSnapshot
            {
                SnapshotId = "app-server-turn-probe",
                ObservedAtUtc = now,
                ExpiresAtUtc = now.AddMinutes(1),
                SurfaceKind = "Window",
                Application = "Zommi acceptance",
                ProcessName = "zommi-acceptance",
                WindowTitle = "Relay acceptance",
                VisibleText = ["ZOMMI_CONTEXT_MARKER"],
                Confidence = "high",
            };
            client.StartTurnAsync(
                    "Reply with exactly ZOMMI_RELAY_READY and nothing else.",
                    context)
                .WaitAsync(TimeSpan.FromSeconds(45))
                .GetAwaiter()
                .GetResult();
            var status = completed.Task.WaitAsync(TimeSpan.FromSeconds(120)).GetAwaiter().GetResult();
            var responseText = response.ToString();
            Console.Out.Write(JsonSerializer.Serialize(new
            {
                threadId = client.ThreadId,
                status,
                response = responseText,
                statuses,
            }));
            return status.Equals("completed", StringComparison.OrdinalIgnoreCase) &&
                   responseText.Contains("ZOMMI_RELAY_READY", StringComparison.Ordinal)
                ? 0
                : 3;
        }
        catch (Exception exception)
        {
            Console.Error.Write(exception);
            return 1;
        }
    }
}
