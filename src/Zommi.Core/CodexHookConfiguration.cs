using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Zommi.Core;

public static class CodexHookConfiguration
{
    public const string CommandMarker = "--zommi-hook";
    private static readonly string[] Events = ["SessionStart", "UserPromptSubmit", "SessionEnd"];

    public static bool IsInstalled(string hooksPath)
    {
        try
        {
            if (!File.Exists(hooksPath))
            {
                return false;
            }

            var root = JsonNode.Parse(File.ReadAllText(hooksPath, Encoding.UTF8));
            return root?.ToJsonString().Contains(CommandMarker, StringComparison.OrdinalIgnoreCase) == true;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or JsonException)
        {
            return false;
        }
    }

    public static string? Install(string hooksPath, string command)
    {
        if (!command.Contains(CommandMarker, StringComparison.OrdinalIgnoreCase))
        {
            throw new ArgumentException($"The hook command must contain {CommandMarker}.", nameof(command));
        }

        var directory = Path.GetDirectoryName(hooksPath) ?? throw new InvalidOperationException("Codex config path is invalid.");
        Directory.CreateDirectory(directory);

        JsonObject root;
        if (File.Exists(hooksPath))
        {
            root = JsonNode.Parse(File.ReadAllText(hooksPath, Encoding.UTF8)) as JsonObject
                ?? throw new InvalidOperationException("The existing Codex hooks file is not a JSON object.");
        }
        else
        {
            root = new JsonObject();
        }

        var backupPath = File.Exists(hooksPath)
            ? $"{hooksPath}.{DateTimeOffset.UtcNow:yyyyMMddHHmmssfffffff}.bak"
            : null;
        if (backupPath is not null)
        {
            File.Copy(hooksPath, backupPath, overwrite: false);
        }

        var hooks = root["hooks"] as JsonObject;
        if (hooks is null)
        {
            if (root["hooks"] is not null)
            {
                throw new InvalidOperationException("The existing 'hooks' property is not a JSON object.");
            }

            hooks = new JsonObject();
            root["hooks"] = hooks;
        }

        RemoveZommiHandlers(hooks);
        foreach (var eventName in Events)
        {
            var groups = hooks[eventName] as JsonArray;
            if (groups is null)
            {
                if (hooks[eventName] is not null)
                {
                    throw new InvalidOperationException($"The existing '{eventName}' hooks property is not an array.");
                }

                groups = new JsonArray();
                hooks[eventName] = groups;
            }

            var handler = new JsonObject
            {
                ["type"] = "command",
                ["command"] = command,
                ["commandWindows"] = command,
                ["timeout"] = 3,
                ["statusMessage"] = eventName == "UserPromptSubmit" ? "Adding Zommi live context" : "Updating Zommi session binding",
            };
            if (eventName == "UserPromptSubmit")
            {
                handler["additionalContextLimit"] = 1200;
            }

            groups.Add(new JsonObject
            {
                ["hooks"] = new JsonArray { handler },
            });
        }

        WriteAtomically(hooksPath, root);
        return backupPath;
    }

    public static void Uninstall(string hooksPath)
    {
        if (!File.Exists(hooksPath))
        {
            return;
        }

        var root = JsonNode.Parse(File.ReadAllText(hooksPath, Encoding.UTF8)) as JsonObject
            ?? throw new InvalidOperationException("The existing Codex hooks file is not a JSON object.");
        if (root["hooks"] is not JsonObject hooks)
        {
            return;
        }

        RemoveZommiHandlers(hooks);
        WriteAtomically(hooksPath, root);
    }

    private static void RemoveZommiHandlers(JsonObject hooks)
    {
        foreach (var eventName in Events)
        {
            if (hooks[eventName] is not JsonArray groups)
            {
                continue;
            }

            for (var groupIndex = groups.Count - 1; groupIndex >= 0; groupIndex--)
            {
                if (groups[groupIndex] is not JsonObject group || group["hooks"] is not JsonArray handlers)
                {
                    continue;
                }

                for (var handlerIndex = handlers.Count - 1; handlerIndex >= 0; handlerIndex--)
                {
                    var command = ReadString(handlers[handlerIndex]?["command"]);
                    var commandWindows = ReadString(handlers[handlerIndex]?["commandWindows"]);
                    if (command?.Contains(CommandMarker, StringComparison.OrdinalIgnoreCase) == true ||
                        commandWindows?.Contains(CommandMarker, StringComparison.OrdinalIgnoreCase) == true)
                    {
                        handlers.RemoveAt(handlerIndex);
                    }
                }

                if (handlers.Count == 0)
                {
                    groups.RemoveAt(groupIndex);
                }
            }

            if (groups.Count == 0)
            {
                hooks.Remove(eventName);
            }
        }
    }

    private static string? ReadString(JsonNode? node) => node is JsonValue value && value.TryGetValue<string>(out var text) ? text : null;

    private static void WriteAtomically(string hooksPath, JsonObject root)
    {
        var directory = Path.GetDirectoryName(hooksPath) ?? throw new InvalidOperationException("Codex config path is invalid.");
        var temporaryPath = Path.Combine(directory, $".hooks.json.{Guid.NewGuid():N}.tmp");
        try
        {
            var options = new JsonSerializerOptions { WriteIndented = true };
            File.WriteAllText(temporaryPath, root.ToJsonString(options), new UTF8Encoding(false));
            File.Move(temporaryPath, hooksPath, overwrite: true);
        }
        finally
        {
            File.Delete(temporaryPath);
        }
    }
}
