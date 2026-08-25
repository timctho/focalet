using System.Diagnostics;
using System.IO;
using Zommi.Core;

namespace Zommi.Windows;

internal static class HookInstaller
{
    internal sealed record WslEnvironment(
        string DistroName,
        string LinuxHome,
        string HooksPath,
        string Command);

    internal sealed record WslInstallResult(
        WslEnvironment Environment,
        string? BackupPath);

    internal sealed record InstallResult(
        string NativeHooksPath,
        string? NativeBackupPath,
        string? WslHooksPath,
        string? WslBackupPath,
        string? WslError);

    public static string HooksPath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
        ".codex",
        "hooks.json");

    public static bool IsInstalled() => CodexHookConfiguration.IsInstalled(HooksPath);

    public static InstallResult Install()
    {
        var nativeBackup = CodexHookConfiguration.Install(HooksPath, BuildHookCommand());
        try
        {
            var wsl = InstallWsl();
            return new InstallResult(HooksPath, nativeBackup, wsl.Environment.HooksPath, wsl.BackupPath, null);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or InvalidOperationException or System.ComponentModel.Win32Exception)
        {
            return new InstallResult(HooksPath, nativeBackup, null, null, exception.Message);
        }
    }

    public static void Uninstall()
    {
        CodexHookConfiguration.Uninstall(HooksPath);
    }

    private static string BuildHookCommand()
    {
        var hookExecutable = Path.Combine(AppContext.BaseDirectory, "Zommi.Hook.exe");
        if (File.Exists(hookExecutable))
        {
            return $"{Quote(hookExecutable)} {CodexHookConfiguration.CommandMarker}";
        }

        var processPath = Environment.ProcessPath
            ?? Process.GetCurrentProcess().MainModule?.FileName
            ?? throw new InvalidOperationException("Zommi cannot determine its executable path.");

        if (string.Equals(Path.GetFileNameWithoutExtension(processPath), "dotnet", StringComparison.OrdinalIgnoreCase))
        {
            var assemblyPath = Path.Combine(AppContext.BaseDirectory, "Zommi.dll");
            return $"{Quote(processPath)} {Quote(assemblyPath)} {CodexHookConfiguration.CommandMarker}";
        }

        return $"{Quote(processPath)} {CodexHookConfiguration.CommandMarker}";
    }

    public static WslInstallResult InstallWsl(
        string? launchToken = null,
        string? stateRoot = null,
        string? channel = null)
    {
        var environment = ResolveWslHook(launchToken, stateRoot, channel);
        var backupPath = CodexHookConfiguration.Install(environment.HooksPath, environment.Command);
        return new WslInstallResult(environment, backupPath);
    }

    internal static WslEnvironment ResolveWslHook(
        string? launchToken = null,
        string? stateRoot = null,
        string? channel = null)
    {
        var wrapperPath = Path.Combine(AppContext.BaseDirectory, "Zommi.WslHook.ps1");
        var hookExecutable = Path.Combine(AppContext.BaseDirectory, "Zommi.Hook.exe");
        if (!File.Exists(wrapperPath) || !File.Exists(hookExecutable))
        {
            throw new InvalidOperationException("The packaged WSL hook files are missing.");
        }

        if (wrapperPath.StartsWith(@"\\", StringComparison.Ordinal))
        {
            throw new InvalidOperationException("Extract Zommi to a local Windows folder before installing the WSL hook.");
        }

        var startInfo = new ProcessStartInfo
        {
            FileName = "wsl.exe",
            Arguments = "-e sh -lc \"printf '%s\\n%s\\n' \\\"$WSL_DISTRO_NAME\\\" \\\"$HOME\\\"\"",
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
        };
        using var process = Process.Start(startInfo) ?? throw new InvalidOperationException("Could not start the default WSL distribution.");
        var standardOutput = process.StandardOutput.ReadToEnd();
        var standardError = process.StandardError.ReadToEnd();
        if (!process.WaitForExit(5000))
        {
            process.Kill(entireProcessTree: true);
            throw new InvalidOperationException("The default WSL distribution did not respond.");
        }

        if (process.ExitCode != 0)
        {
            throw new InvalidOperationException($"WSL discovery failed: {standardError.Trim()}");
        }

        var lines = standardOutput.Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        if (lines.Length < 2 || !lines[1].StartsWith("/", StringComparison.Ordinal))
        {
            throw new InvalidOperationException("WSL did not return its distribution name and Linux home directory.");
        }

        var distroName = lines[0];
        var linuxHome = lines[1].TrimStart('/').Replace('/', '\\');
        var wslHooksPath = $@"\\wsl.localhost\{distroName}\{linuxHome}\.codex\hooks.json";
        var command = $"/init /mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe -NoProfile -ExecutionPolicy Bypass -File {QuoteForPosixShell(wrapperPath)}";
        command = AppendPowerShellArgument(command, "StateRoot", stateRoot);
        command = AppendPowerShellArgument(command, "Channel", channel);
        command = AppendPowerShellArgument(command, "LaunchToken", launchToken);
        return new WslEnvironment(distroName, lines[1], wslHooksPath, command);
    }

    private static string AppendPowerShellArgument(string command, string name, string? value) =>
        string.IsNullOrWhiteSpace(value)
            ? command
            : $"{command} -{name} {QuoteForPosixShell(value)}";

    private static string QuoteForPosixShell(string value) => $"'{value.Replace("'", "'\"'\"'", StringComparison.Ordinal)}'";

    private static string Quote(string value) => $"\"{value.Replace("\"", "\\\"", StringComparison.Ordinal)}\"";
}
