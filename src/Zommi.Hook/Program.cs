using Zommi.Core;

ApplyOption(args, "--state-root", "ZOMMI_STATE_ROOT");
ApplyOption(args, "--channel", "ZOMMI_CHANNEL");

try
{
    var input = Console.In.ReadToEnd();
    var stateStore = new StateStore(StateStore.GetDefaultRoot());
    var launchToken = ReadOption(args, "--launch-token");
    var output = new HookProcessor(stateStore, new SharedSnapshotReader(), launchToken).Process(input, DateTimeOffset.UtcNow);
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

static void ApplyOption(IReadOnlyList<string> arguments, string optionName, string environmentName)
{
    var value = ReadOption(arguments, optionName);
    if (!string.IsNullOrWhiteSpace(value))
    {
        Environment.SetEnvironmentVariable(environmentName, value);
    }
}

static string? ReadOption(IReadOnlyList<string> arguments, string optionName)
{
    for (var index = 0; index < arguments.Count - 1; index++)
    {
        if (arguments[index].Equals(optionName, StringComparison.OrdinalIgnoreCase))
        {
            return arguments[index + 1];
        }
    }

    return null;
}
