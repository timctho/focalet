using Zommi.Core;

namespace Zommi.Windows;

internal static class Program
{
    [STAThread]
    private static int Main(string[] args)
    {
        if (args.Contains("--zommi-hook", StringComparer.OrdinalIgnoreCase))
        {
            return RunHook();
        }

        ApplicationConfiguration.Initialize();
        var store = new StateStore(StateStore.GetDefaultRoot());
        using var snapshots = SharedSnapshotStore.CreateOwner();
        Application.Run(new MainForm(store, snapshots, new ForegroundContextCapture()));
        return 0;
    }

    private static int RunHook()
    {
        try
        {
            var input = Console.In.ReadToEnd();
            var store = new StateStore(StateStore.GetDefaultRoot());
            var output = new HookProcessor(store, new SharedSnapshotReader()).Process(input, DateTimeOffset.UtcNow);
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
