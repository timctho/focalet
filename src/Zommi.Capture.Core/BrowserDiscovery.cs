using System.Net;

namespace Zommi.Capture;

public static class BrowserDiscovery
{
    public static string? Family(string processName)
    {
        var name = Path.GetFileNameWithoutExtension(processName).ToLowerInvariant();
        return name.Contains("brave", StringComparison.Ordinal) ? "brave" :
            name.Contains("edge", StringComparison.Ordinal) ? "edge" :
            name.Contains("chromium", StringComparison.Ordinal) ? "chromium" :
            name.Contains("chrome", StringComparison.Ordinal) ? "chrome" : null;
    }

    public static bool HasExplicitEndpoint => !string.IsNullOrWhiteSpace(
        Environment.GetEnvironmentVariable("ZOMMI_BROWSER_CDP_ENDPOINT"));

    public static IEnumerable<Uri> Endpoints(string processName)
    {
        var configured = Environment.GetEnvironmentVariable("ZOMMI_BROWSER_CDP_ENDPOINT");
        if (!string.IsNullOrWhiteSpace(configured))
        {
            if (Uri.TryCreate(configured, UriKind.Absolute, out var endpoint) && IsLocalEndpoint(endpoint)) yield return endpoint;
            // An explicit endpoint remains exclusive; never prompt another profile.
            yield break;
        }
        var family = Family(processName);
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var root = OperatingSystem.IsWindows() ? Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData) :
            OperatingSystem.IsMacOS() ? Path.Combine(home, "Library/Application Support") :
            Environment.GetEnvironmentVariable("XDG_CONFIG_HOME") ?? Path.Combine(home, ".config");
        var directory = ProfileDirectory(family, OperatingSystem.IsWindows() ? "windows" : OperatingSystem.IsMacOS() ? "macos" : "linux");
        if (directory is null) yield break;
        string[] lines;
        try { lines = File.ReadAllLines(Path.Combine(root, directory, "DevToolsActivePort")); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { yield break; }
        if (lines.Length >= 2 && int.TryParse(lines[0], out var port) && port is > 0 and <= 65535 &&
            lines[1].StartsWith("/devtools/browser/", StringComparison.Ordinal) &&
            Uri.TryCreate($"ws://127.0.0.1:{port}{lines[1]}", UriKind.Absolute, out var discovered))
            yield return discovered;
    }

    public static bool IsLocalEndpoint(Uri endpoint) => endpoint.Scheme is "http" or "https" or "ws" or "wss" &&
        string.IsNullOrEmpty(endpoint.UserInfo) && (endpoint.Host.Equals("localhost", StringComparison.OrdinalIgnoreCase) ||
            IPAddress.TryParse(endpoint.Host, out var address) && IPAddress.IsLoopback(address));

    public static string? ProfileDirectory(string? browser, string platform) => (browser, platform) switch
    {
        ("edge", "windows") => "Microsoft/Edge/User Data",
        ("chrome", "windows") => "Google/Chrome/User Data",
        ("brave", "windows") => "BraveSoftware/Brave-Browser/User Data",
        ("chromium", "windows") => "Chromium/User Data",
        ("edge", "macos") => "Microsoft Edge",
        ("chrome", "macos") => "Google/Chrome",
        ("brave", "macos") => "BraveSoftware/Brave-Browser",
        ("chromium", "macos") => "Chromium",
        ("edge", "linux") => "microsoft-edge",
        ("chrome", "linux") => "google-chrome",
        ("brave", "linux") => "BraveSoftware/Brave-Browser",
        ("chromium", "linux") => "chromium",
        _ => null,
    };
}
