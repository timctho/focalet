using Zommi.Core;

namespace Zommi.Windows;

internal static class Program
{
    [STAThread]
    private static int Main(string[] args)
    {
        RuntimeOptions.Apply(args);

        if (args.Contains("--electron-host", StringComparer.OrdinalIgnoreCase))
        {
            return ElectronNativeHost.Run();
        }

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

        if (args.Contains("--acceptance-app-server-turn", StringComparer.OrdinalIgnoreCase))
        {
            return AcceptanceProbe.AppServerTurn();
        }

        if (args.Contains("--acceptance-app-server-activity", StringComparer.OrdinalIgnoreCase))
        {
            return AcceptanceProbe.AppServerActivity();
        }

        if (args.Contains("--acceptance-app-server-image", StringComparer.OrdinalIgnoreCase))
        {
            return AcceptanceProbe.AppServerImage();
        }

        if (args.Contains("--acceptance-selected-text", StringComparer.OrdinalIgnoreCase))
        {
            return AcceptanceProbe.SelectedTextCapture();
        }

        ApplicationConfiguration.Initialize();
        var seededUi = args.Contains("--acceptance-ui-seeded", StringComparer.OrdinalIgnoreCase);
        var autoLaunch = !seededUi && !args.Contains("--no-auto-launch", StringComparer.OrdinalIgnoreCase);
        Func<RegionSelectionForm>? selectorFactory = seededUi
            ? () => new RegionSelectionForm(_ => Convert.FromBase64String(
                "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="))
            : null;
        var form = new MainForm(
            new ForegroundContextCapture(),
            new CodexAppServerClient(),
            autoLaunch,
            selectorFactory);
        if (seededUi)
        {
            form.SeedAcceptanceContexts();
        }

        Application.Run(form);
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
