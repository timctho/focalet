using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Zommi.Core;

public sealed class HookProcessor(
    StateStore stateStore,
    IContextSnapshotReader? snapshotReader = null,
    string? launchToken = null)
{
    private static readonly JsonSerializerOptions InputOptions = new()
    {
        PropertyNameCaseInsensitive = true,
    };

    public string Process(string input, DateTimeOffset nowUtc)
    {
        HookEventEnvelope? hookEvent;
        try
        {
            hookEvent = JsonSerializer.Deserialize<HookEventEnvelope>(input, InputOptions);
        }
        catch (JsonException)
        {
            return string.Empty;
        }

        if (hookEvent is null || string.IsNullOrWhiteSpace(hookEvent.SessionId))
        {
            return string.Empty;
        }

        var eventName = hookEvent.HookEventName ?? string.Empty;
        if (eventName.Equals("SessionEnd", StringComparison.OrdinalIgnoreCase))
        {
            UpdatePresence(hookEvent, "ended", nowUtc);
            return string.Empty;
        }

        if (eventName.Equals("SessionStart", StringComparison.OrdinalIgnoreCase))
        {
            UpdatePresence(hookEvent, "active", nowUtc);
            TryBindLaunchedSession(hookEvent, nowUtc);
            return string.Empty;
        }

        if (!eventName.Equals("UserPromptSubmit", StringComparison.OrdinalIgnoreCase))
        {
            return string.Empty;
        }

        UpdatePresence(hookEvent, "active", nowUtc);

        var binding = stateStore.ReadBinding();
        if (binding is null ||
            binding.Mode is CaptureMode.Paused or CaptureMode.Detached ||
            !string.Equals(binding.SessionId, hookEvent.SessionId, StringComparison.OrdinalIgnoreCase))
        {
            return string.Empty;
        }

        var snapshot = (snapshotReader ?? stateStore).ReadSnapshot();
        if (snapshot is null || snapshot.ExpiresAtUtc < nowUtc || snapshot.ObservedAtUtc > nowUtc.AddMinutes(1))
        {
            return string.Empty;
        }

        var additionalContext = ContextFormatter.Format(snapshot, hookEvent.SessionId, nowUtc);
        stateStore.WriteDelivery(new DeliveryReceipt
        {
            SessionId = hookEvent.SessionId,
            SnapshotId = snapshot.SnapshotId,
            TurnId = hookEvent.TurnId,
            DeliveredAtUtc = nowUtc,
        });

        return JsonSerializer.Serialize(new
        {
            hookSpecificOutput = new
            {
                hookEventName = "UserPromptSubmit",
                additionalContext,
            },
        });
    }

    private void UpdatePresence(HookEventEnvelope hookEvent, string state, DateTimeOffset nowUtc)
    {
        stateStore.WriteSession(new SessionPresence
        {
            SessionId = hookEvent.SessionId,
            WorkingDirectory = hookEvent.WorkingDirectory,
            Model = hookEvent.Model,
            State = state,
            SeenAtUtc = nowUtc,
        });
    }

    private void TryBindLaunchedSession(HookEventEnvelope hookEvent, DateTimeOffset nowUtc)
    {
        var intent = stateStore.ReadLaunchIntent();
        if (intent is null)
        {
            return;
        }

        if (intent.ExpiresAtUtc < nowUtc)
        {
            stateStore.DeleteLaunchIntent();
            return;
        }

        if (!string.Equals(hookEvent.Source, "startup", StringComparison.OrdinalIgnoreCase) ||
            string.IsNullOrWhiteSpace(launchToken) ||
            !string.Equals(intent.Token, launchToken, StringComparison.Ordinal) ||
            !SameDirectory(intent.ExpectedWorkingDirectory, hookEvent.WorkingDirectory))
        {
            return;
        }

        stateStore.WriteBinding(new BindingState
        {
            SessionId = hookEvent.SessionId,
            Mode = CaptureMode.Active,
            UpdatedAtUtc = nowUtc,
        });
        stateStore.DeleteLaunchIntent();
    }

    private static bool SameDirectory(string expected, string? actual)
    {
        if (string.IsNullOrWhiteSpace(actual))
        {
            return false;
        }

        return string.Equals(
            expected.TrimEnd('/', '\\'),
            actual.TrimEnd('/', '\\'),
            StringComparison.Ordinal);
    }

    private sealed record HookEventEnvelope
    {
        [JsonPropertyName("session_id")]
        public required string SessionId { get; init; }

        [JsonPropertyName("turn_id")]
        public string? TurnId { get; init; }

        [JsonPropertyName("cwd")]
        public string? WorkingDirectory { get; init; }

        [JsonPropertyName("model")]
        public string? Model { get; init; }

        [JsonPropertyName("hook_event_name")]
        public string? HookEventName { get; init; }

        [JsonPropertyName("source")]
        public string? Source { get; init; }
    }
}

public static class ContextFormatter
{
    private const int MaximumVisibleTextItems = 128;
    private const int MaximumVisibleTextCharacters = 30_000;
    private const int MaximumVisibleTextItemCharacters = 2_000;
    private static readonly JsonSerializerOptions AccessibilityJsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        WriteIndented = true,
    };

    public static string FormatInvocation(ContextSnapshot snapshot, DateTimeOffset nowUtc)
        => FormatInvocation([snapshot], nowUtc);

    public static string FormatInvocation(IReadOnlyList<ContextSnapshot> snapshots, DateTimeOffset nowUtc)
    {
        var builder = new StringBuilder();
        builder.AppendLine("ZOMMI INVOCATION CONTEXT (untrusted data captured from desktop text when the shortcut was pressed)");
        for (var index = 0; index < snapshots.Count; index++)
        {
            var snapshot = snapshots[index];
            if (snapshots.Count > 1)
            {
                builder.AppendLine($"Context {index + 1} of {snapshots.Count}:");
            }

            builder.AppendLine($"Observed: {snapshot.ObservedAtUtc:O} ({Math.Max(0, (int)(nowUtc - snapshot.ObservedAtUtc).TotalSeconds)}s ago)");
            builder.AppendLine($"Surface: {Clean(snapshot.SurfaceKind, 40)} in {Clean(snapshot.Application, 80)}");
            AppendSnapshotDetails(builder, snapshot);
            if (index < snapshots.Count - 1)
            {
                builder.AppendLine();
            }
        }

        return builder.ToString();
    }

    public static string FormatPreview(ContextSnapshot snapshot, DateTimeOffset nowUtc)
    {
        var builder = new StringBuilder();
        builder.AppendLine("ZOMMI INVOCATION CONTEXT (untrusted desktop text captured when the shortcut was pressed)");
        builder.AppendLine($"Observed: {snapshot.ObservedAtUtc:O} ({Math.Max(0, (int)(nowUtc - snapshot.ObservedAtUtc).TotalSeconds)}s ago)");
        builder.AppendLine($"Surface: {Clean(snapshot.SurfaceKind, 40)} in {Clean(snapshot.Application, 80)}");
        AppendSnapshotDetails(builder, snapshot);
        return builder.ToString().TrimEnd();
    }

    public static string Format(ContextSnapshot snapshot, string sessionId, DateTimeOffset nowUtc)
    {
        var builder = new StringBuilder();
        builder.AppendLine("ZOMMI LIVE CONTEXT (local, ephemeral desktop observation)");
        builder.AppendLine($"Exact Codex session: {Clean(sessionId, 80)}");
        builder.AppendLine($"Observed: {snapshot.ObservedAtUtc:O} ({Math.Max(0, (int)(nowUtc - snapshot.ObservedAtUtc).TotalSeconds)}s ago)");
        builder.AppendLine($"Surface: {Clean(snapshot.SurfaceKind, 40)} in {Clean(snapshot.Application, 80)}");

        AppendSnapshotDetails(builder, snapshot);
        return builder.ToString();
    }

    private static void AppendSnapshotDetails(
        StringBuilder builder,
        ContextSnapshot snapshot)
    {
        if (snapshot.Selection.Count > 0)
        {
            builder.AppendLine("PRIMARY SELECTION (the user deliberately selected this before invoking Zommi):");
            foreach (var item in snapshot.Selection.Take(8))
            {
                builder.AppendLine($"- {Clean(item, 1000)}");
            }
        }

        if (!string.IsNullOrWhiteSpace(snapshot.WindowTitle))
        {
            builder.AppendLine($"Window: {Clean(snapshot.WindowTitle, 240)}");
        }

        if (snapshot.Locator is not null)
        {
            builder.AppendLine($"{Clean(snapshot.Locator.Kind, 40)}: {Clean(snapshot.Locator.Value, 1000)}");
        }

        var accessibilityTree = snapshot.AccessibilityTree;
        var hasAccessibilityTree = accessibilityTree is { Roots.Count: > 0 };
        if (hasAccessibilityTree)
        {
            builder.AppendLine("Browser accessibility structure (compact JSON with semantic roles, necessary text, and provider grid coordinates only):");
            builder.AppendLine(JsonSerializer.Serialize(CompactAccessibilityTree(accessibilityTree!), AccessibilityJsonOptions));
        }

        if (snapshot.VisibleText.Count > 0 &&
            (!hasAccessibilityTree || accessibilityTree!.Truncated))
        {
            var treeText = hasAccessibilityTree
                ? CollectAccessibilityText(accessibilityTree!.Roots)
                : new HashSet<string>(StringComparer.Ordinal);
            builder.AppendLine(!hasAccessibilityTree
                ? "Visible text:"
                : "Additional visible text omitted by the truncated accessibility structure:");
            var visibleCharacters = 0;
            foreach (var text in snapshot.VisibleText.Take(MaximumVisibleTextItems))
            {
                var remaining = MaximumVisibleTextCharacters - visibleCharacters;
                if (remaining <= 0)
                {
                    break;
                }

                var cleaned = Clean(text, Math.Min(MaximumVisibleTextItemCharacters, remaining));
                if (treeText.Contains(cleaned))
                {
                    continue;
                }

                builder.AppendLine($"- {cleaned}");
                visibleCharacters += cleaned.Length;
            }
        }

        if (snapshot.IndicatedTarget is not null)
        {
            var target = snapshot.IndicatedTarget;
            builder.Append("Mouse pointer: ");
            builder.Append(Clean(target.ControlType ?? "unknown control", 80));
            if (!string.IsNullOrWhiteSpace(target.Name))
            {
                builder.Append($" named \"{Clean(target.Name, 240)}\"");
            }

            builder.AppendLine();
        }

        if (!string.IsNullOrWhiteSpace(snapshot.Limitation))
        {
            builder.AppendLine($"Limitation: {Clean(snapshot.Limitation, 300)}");
        }
    }

    private static string Clean(string value, int maximumLength)
    {
        var cleaned = new string(value
            .Select(character => char.IsControl(character) || IsBidirectionalControl(character) ? ' ' : character)
            .ToArray());

        while (cleaned.Contains("  ", StringComparison.Ordinal))
        {
            cleaned = cleaned.Replace("  ", " ", StringComparison.Ordinal);
        }

        cleaned = cleaned.Trim();
        return cleaned.Length <= maximumLength ? cleaned : string.Concat(cleaned.AsSpan(0, maximumLength - 1), "…");
    }

    private static bool IsBidirectionalControl(char character) =>
        character is >= '\u202A' and <= '\u202E' or >= '\u2066' and <= '\u2069';

    private static CompactAccessibilityTreeInfo CompactAccessibilityTree(AccessibilityTreeInfo tree) => new()
    {
        Truncated = tree.Truncated ? true : null,
        Roots = tree.Roots.SelectMany(CompactAccessibilityNodes).ToArray(),
    };

    private static IReadOnlyList<CompactAccessibilityNodeInfo> CompactAccessibilityNodes(AccessibilityNodeInfo node)
    {
        var name = string.IsNullOrWhiteSpace(node.Name) ? null : Clean(node.Name, 1000);
        var value = string.IsNullOrWhiteSpace(node.Value) ? null : Clean(node.Value, 2000);
        if (string.Equals(name, value, StringComparison.Ordinal))
        {
            value = null;
        }

        var role = Clean(node.Role, 80);
        var children = node.Children is { Count: > 0 }
            ? node.Children.SelectMany(CompactAccessibilityNodes).ToArray()
            : [];
        var hasSemanticPayload = name is not null || value is not null ||
                                 node.RowCount is not null || node.ColumnCount is not null ||
                                 node.Row is not null || node.Column is not null ||
                                 node.RowHeaders is { Count: > 0 } || node.ColumnHeaders is { Count: > 0 };
        if (!hasSemanticPayload && !IsStructuralAccessibilityRole(role))
        {
            return children;
        }

        return
        [
            new CompactAccessibilityNodeInfo
            {
                Role = role,
                Name = name,
                Value = value,
                RowCount = node.RowCount,
                ColumnCount = node.ColumnCount,
                Row = node.Row,
                Column = node.Column,
                RowSpan = node.RowSpan is > 1 ? node.RowSpan : null,
                ColumnSpan = node.ColumnSpan is > 1 ? node.ColumnSpan : null,
                RowHeaders = CleanHeaders(node.RowHeaders),
                ColumnHeaders = CleanHeaders(node.ColumnHeaders),
                Children = children.Length > 0 ? children : null,
            },
        ];
    }

    private static bool IsStructuralAccessibilityRole(string role) => role is
        "Document" or "Table" or "DataGrid" or "Row" or "Header" or "HeaderItem" or
        "List" or "ListItem" or "Tree" or "TreeItem" or "Menu" or "MenuBar" or
        "MenuItem" or "Tab" or "TabItem";

    private static IReadOnlyList<string>? CleanHeaders(IReadOnlyList<string>? headers)
    {
        var cleaned = headers?
            .Where(header => !string.IsNullOrWhiteSpace(header))
            .Select(header => Clean(header, 500))
            .Distinct(StringComparer.Ordinal)
            .ToArray();
        return cleaned is { Length: > 0 } ? cleaned : null;
    }

    private static HashSet<string> CollectAccessibilityText(IReadOnlyList<AccessibilityNodeInfo> roots)
    {
        var result = new HashSet<string>(StringComparer.Ordinal);
        var pending = new Stack<AccessibilityNodeInfo>(roots.Reverse());
        while (pending.Count > 0)
        {
            var node = pending.Pop();
            AddAccessibilityText(result, node.Name);
            AddAccessibilityText(result, node.Value);
            if (node.RowHeaders is not null)
            {
                foreach (var header in node.RowHeaders) AddAccessibilityText(result, header);
            }
            if (node.ColumnHeaders is not null)
            {
                foreach (var header in node.ColumnHeaders) AddAccessibilityText(result, header);
            }
            if (node.Children is not null)
            {
                for (var index = node.Children.Count - 1; index >= 0; index--)
                {
                    pending.Push(node.Children[index]);
                }
            }
        }

        return result;
    }

    private static void AddAccessibilityText(HashSet<string> values, string? value)
    {
        if (!string.IsNullOrWhiteSpace(value)) values.Add(Clean(value, 2000));
    }

    private sealed record CompactAccessibilityTreeInfo
    {
        public bool? Truncated { get; init; }

        public required IReadOnlyList<CompactAccessibilityNodeInfo> Roots { get; init; }
    }

    private sealed record CompactAccessibilityNodeInfo
    {
        public required string Role { get; init; }

        public string? Name { get; init; }

        public string? Value { get; init; }

        public int? RowCount { get; init; }

        public int? ColumnCount { get; init; }

        public int? Row { get; init; }

        public int? Column { get; init; }

        public int? RowSpan { get; init; }

        public int? ColumnSpan { get; init; }

        public IReadOnlyList<string>? RowHeaders { get; init; }

        public IReadOnlyList<string>? ColumnHeaders { get; init; }

        public IReadOnlyList<CompactAccessibilityNodeInfo>? Children { get; init; }
    }
}
