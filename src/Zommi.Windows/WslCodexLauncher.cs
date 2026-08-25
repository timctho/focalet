using System.ComponentModel;
using System.Diagnostics;

namespace Zommi.Windows;

internal static class WslCodexLauncher
{
    private const string CodexCommand = "exec codex --dangerously-bypass-hook-trust";

    public static void Launch(HookInstaller.WslEnvironment environment)
    {
        try
        {
            _ = Process.Start(BuildStartInfo("wt.exe", environment, useWindowsTerminal: true))
                ?? throw new InvalidOperationException("Windows Terminal did not start.");
        }
        catch (Exception exception) when (exception is Win32Exception or InvalidOperationException)
        {
            _ = Process.Start(BuildStartInfo("wsl.exe", environment, useWindowsTerminal: false))
                ?? throw new InvalidOperationException("The default WSL distribution did not start.");
        }
    }

    internal static ProcessStartInfo BuildStartInfo(
        string executable,
        HookInstaller.WslEnvironment environment,
        bool useWindowsTerminal)
    {
        var startInfo = new ProcessStartInfo
        {
            FileName = executable,
            UseShellExecute = true,
        };

        if (useWindowsTerminal)
        {
            startInfo.ArgumentList.Add("-w");
            startInfo.ArgumentList.Add("new");
            startInfo.ArgumentList.Add("wsl.exe");
        }

        startInfo.ArgumentList.Add("-d");
        startInfo.ArgumentList.Add(environment.DistroName);
        startInfo.ArgumentList.Add("--cd");
        startInfo.ArgumentList.Add(environment.LinuxHome);
        startInfo.ArgumentList.Add("-e");
        startInfo.ArgumentList.Add("sh");
        startInfo.ArgumentList.Add("-lc");
        startInfo.ArgumentList.Add(CodexCommand);
        return startInfo;
    }
}
