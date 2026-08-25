namespace Zommi.Windows;

internal static class RuntimeOptions
{
    public static void Apply(IReadOnlyList<string> args)
    {
        ApplyEnvironmentOption(args, "--state-root", "ZOMMI_STATE_ROOT");
        ApplyEnvironmentOption(args, "--channel", "ZOMMI_CHANNEL");
    }

    public static string? Read(IReadOnlyList<string> args, string name)
    {
        for (var index = 0; index < args.Count - 1; index++)
        {
            if (args[index].Equals(name, StringComparison.OrdinalIgnoreCase))
            {
                return args[index + 1];
            }
        }

        return null;
    }

    private static void ApplyEnvironmentOption(IReadOnlyList<string> args, string optionName, string environmentName)
    {
        var value = Read(args, optionName);
        if (!string.IsNullOrWhiteSpace(value))
        {
            Environment.SetEnvironmentVariable(environmentName, value);
        }
    }
}
