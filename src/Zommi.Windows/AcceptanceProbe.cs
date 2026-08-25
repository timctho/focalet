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
        try
        {
            var environment = HookInstaller.ResolveWslHook("acceptance-launch-token");
            var startInfo = WslCodexLauncher.BuildStartInfo("wt.exe", environment, useWindowsTerminal: true);
            Console.Out.Write(JsonSerializer.Serialize(new
            {
                startInfo.FileName,
                arguments = startInfo.ArgumentList,
                environment.DistroName,
                environment.LinuxHome,
                environment.Command,
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
