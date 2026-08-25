using Zommi.Core;

namespace Zommi.Windows;

internal static class Program
{
    [STAThread]
    private static int Main(string[] args)
    {
        RuntimeOptions.Apply(args);

        if (args.Contains("--zommi-hook", StringComparer.OrdinalIgnoreCase))
        {
            return RunHook(args);
        }

        if (args.Contains("--acceptance-probe", StringComparer.OrdinalIgnoreCase))
        {
            return AcceptanceProbe.RunSharedMemoryProbe(args);
        }

        if (args.Contains("--acceptance-capture-once", StringComparer.OrdinalIgnoreCase))
        {
            return AcceptanceProbe.CaptureOnce();
        }

        if (args.Contains("--acceptance-discover-wsl", StringComparer.OrdinalIgnoreCase))
        {
            return AcceptanceProbe.DiscoverWsl();
        }

        if (args.Contains("--acceptance-wsl-launch-plan", StringComparer.OrdinalIgnoreCase))
        {
            return AcceptanceProbe.WslLaunchPlan();
        }

        if (args.Contains("--acceptance-app-server-handshake", StringComparer.OrdinalIgnoreCase))
        {
            return AcceptanceProbe.AppServerHandshake();
        }

        ApplicationConfiguration.Initialize();
        var autoLaunch = !args.Contains("--no-auto-launch", StringComparer.OrdinalIgnoreCase);
        Application.Run(new MainForm(new ForegroundContextCapture(), new CodexAppServerClient(), autoLaunch));
        return 0;
    }

    private static int RunHook(IReadOnlyList<string> args)
    {
        try
        {
            var input = Console.In.ReadToEnd();
            var store = new StateStore(StateStore.GetDefaultRoot());
            var launchToken = RuntimeOptions.Read(args, "--launch-token");
            var output = new HookProcessor(store, new SharedSnapshotReader(), launchToken).Process(input, DateTimeOffset.UtcNow);
            if (!string.IsNullOrEmpty(output))
            {
                Console.Out.Write(output);
            }
        }
        catch
        {
            // Zommi is advisory. A capture or state failure must never block Codex.
        }

        return 0;
    }
}
