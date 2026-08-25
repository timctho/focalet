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
            snapshots.WriteSnapshot(new ContextSnapshot
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
            });

            Console.Out.WriteLine($"READY {sessionId}");
            Console.Out.Flush();
            Thread.Sleep(TimeSpan.FromSeconds(seconds));
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
}
