using System.Diagnostics;
using System.IO;
using Zommi.Core;

namespace Zommi.Windows;

internal static class HookInstaller
{
    public static string HooksPath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
        ".codex",
        "hooks.json");

    public static bool IsInstalled() => CodexHookConfiguration.IsInstalled(HooksPath);

    public static string? Install()
    {
        return CodexHookConfiguration.Install(HooksPath, BuildHookCommand());
    }

    public static void Uninstall()
    {
        CodexHookConfiguration.Uninstall(HooksPath);
    }

    private static string BuildHookCommand()
    {
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

    private static string Quote(string value) => $"\"{value.Replace("\"", "\\\"", StringComparison.Ordinal)}\"";
}
