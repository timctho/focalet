using System.Text.Json;

namespace Zommi.Core;

public enum CodexStreamKind
{
    Assistant,
    Thinking,
    Plan,
    Tool,
    ToolOutput,
}

public enum CodexStreamLifecycle
{
    Started,
    Delta,
    Completed,
}

public sealed record CodexStreamUpdate
{
    public string? ThreadId { get; init; }

    public required CodexStreamKind Kind { get; init; }

    public required CodexStreamLifecycle Lifecycle { get; init; }

    public required string Title { get; init; }

    public required string Text { get; init; }

    public string? ItemId { get; init; }

    public string? Status { get; init; }
}

public static class CodexStreamProtocol
{
    public static CodexStreamUpdate? ParseNotification(string method, JsonElement parameters) => method switch
    {
        "item/agentMessage/delta" => Delta(CodexStreamKind.Assistant, "Codex", parameters),
        "item/plan/delta" => Delta(CodexStreamKind.Plan, "Plan", parameters),
        "item/reasoning/summaryTextDelta" => Delta(CodexStreamKind.Thinking, "Thinking", parameters),
        "item/reasoning/textDelta" => Delta(CodexStreamKind.Thinking, "Thinking", parameters),
        "item/reasoning/summaryPartAdded" => new CodexStreamUpdate
        {
            Kind = CodexStreamKind.Thinking,
            Lifecycle = CodexStreamLifecycle.Delta,
            Title = "Thinking",
            Text = Environment.NewLine,
            ItemId = ReadString(parameters, "itemId"),
        },
        "item/commandExecution/outputDelta" => Delta(CodexStreamKind.ToolOutput, "Command output", parameters),
        "item/commandExecution/terminalInteraction" => Delta(CodexStreamKind.ToolOutput, "Terminal input", parameters, "stdin"),
        "item/fileChange/outputDelta" => Delta(CodexStreamKind.ToolOutput, "File change output", parameters),
        "item/fileChange/patchUpdated" => new CodexStreamUpdate
        {
            Kind = CodexStreamKind.ToolOutput,
            Lifecycle = CodexStreamLifecycle.Delta,
            Title = "Patch update",
            Text = FormatFileChanges(parameters),
            ItemId = ReadString(parameters, "itemId"),
        },
        "item/mcpToolCall/progress" => Delta(CodexStreamKind.ToolOutput, "Tool progress", parameters, "message"),
        "item/autoApprovalReview/started" => ParseApprovalReview(parameters, CodexStreamLifecycle.Started),
        "item/autoApprovalReview/completed" => ParseApprovalReview(parameters, CodexStreamLifecycle.Completed),
        "item/started" => ParseItem(parameters, CodexStreamLifecycle.Started),
        "item/completed" => ParseItem(parameters, CodexStreamLifecycle.Completed),
        _ => null,
    };

    private static CodexStreamUpdate? Delta(
        CodexStreamKind kind,
        string title,
        JsonElement parameters,
        string propertyName = "delta")
    {
        if (!parameters.TryGetProperty(propertyName, out var delta))
        {
            return null;
        }

        return new CodexStreamUpdate
        {
            Kind = kind,
            Lifecycle = CodexStreamLifecycle.Delta,
            Title = title,
            Text = delta.GetString() ?? delta.ToString(),
            ItemId = ReadString(parameters, "itemId"),
        };
    }

    private static CodexStreamUpdate? ParseItem(JsonElement parameters, CodexStreamLifecycle lifecycle)
    {
        if (!parameters.TryGetProperty("item", out var item) ||
            !item.TryGetProperty("type", out var typeElement))
        {
            return null;
        }

        var type = typeElement.GetString() ?? string.Empty;
        var itemId = ReadString(item, "id");
        var status = ReadString(item, "status");
        return type switch
        {
            "reasoning" => new CodexStreamUpdate
            {
                Kind = CodexStreamKind.Thinking,
                Lifecycle = lifecycle,
                Title = "Thinking",
                Text = lifecycle == CodexStreamLifecycle.Completed ? JoinText(item, "summary", "content") : string.Empty,
                ItemId = itemId,
                Status = status,
            },
            "plan" => new CodexStreamUpdate
            {
                Kind = CodexStreamKind.Plan,
                Lifecycle = lifecycle,
                Title = "Plan",
                Text = ReadString(item, "text") ?? string.Empty,
                ItemId = itemId,
                Status = status,
            },
            "agentMessage" when ReadString(item, "phase") == "commentary" &&
                                lifecycle == CodexStreamLifecycle.Started => new CodexStreamUpdate
            {
                Kind = CodexStreamKind.Thinking,
                Lifecycle = lifecycle,
                Title = "Thinking",
                Text = string.Empty,
                ItemId = itemId,
                Status = status,
            },
            "commandExecution" => Tool(
                lifecycle,
                itemId,
                status,
                "Command",
                lifecycle == CodexStreamLifecycle.Started
                    ? ReadString(item, "command")
                    : ReadString(item, "aggregatedOutput")),
            "fileChange" => Tool(lifecycle, itemId, status, "File change", FormatFileChanges(item)),
            "mcpToolCall" => Tool(
                lifecycle,
                itemId,
                status,
                "MCP tool",
                JoinNonEmpty(" · ", ReadString(item, "server"), ReadString(item, "tool"))),
            "dynamicToolCall" => Tool(lifecycle, itemId, status, "Tool", ReadString(item, "tool")),
            "collabToolCall" or "collabAgentToolCall" => Tool(lifecycle, itemId, status, "Agent tool", ReadString(item, "tool")),
            "subAgentActivity" => Tool(
                lifecycle,
                itemId,
                status,
                "Sub-agent",
                JoinNonEmpty(" · ", ReadString(item, "kind"), ReadString(item, "agentPath"))),
            "webSearch" => Tool(lifecycle, itemId, status, "Web search", ReadString(item, "query")),
            "imageView" => Tool(lifecycle, itemId, status, "View image", ReadString(item, "path")),
            "sleep" => Tool(lifecycle, itemId, status, "Wait", $"{ReadString(item, "durationMs")} ms"),
            "imageGeneration" => Tool(
                lifecycle,
                itemId,
                status,
                "Image generation",
                JoinNonEmpty(Environment.NewLine, ReadString(item, "revisedPrompt"), ReadString(item, "savedPath"))),
            "enteredReviewMode" => Tool(lifecycle, itemId, status, "Review", ReadString(item, "review")),
            "exitedReviewMode" => Tool(lifecycle, itemId, status, "Review completed", ReadString(item, "review")),
            "contextCompaction" => Tool(lifecycle, itemId, status, "Context", "Compacting conversation"),
            _ => null,
        };
    }

    private static CodexStreamUpdate Tool(
        CodexStreamLifecycle lifecycle,
        string? itemId,
        string? status,
        string title,
        string? text) => new()
        {
            Kind = CodexStreamKind.Tool,
            Lifecycle = lifecycle,
            Title = title,
            Text = text ?? string.Empty,
            ItemId = itemId,
            Status = status,
        };

    private static CodexStreamUpdate ParseApprovalReview(
        JsonElement parameters,
        CodexStreamLifecycle lifecycle)
    {
        var reviewText = string.Empty;
        if (parameters.TryGetProperty("review", out var review))
        {
            reviewText = JoinNonEmpty(" · ", ReadString(review, "riskLevel"), ReadString(review, "rationale"));
        }

        return Tool(
            lifecycle,
            ReadString(parameters, "targetItemId") ?? ReadString(parameters, "reviewId"),
            ReadString(parameters, "decisionSource"),
            "Approval review",
            reviewText);
    }

    private static string FormatFileChanges(JsonElement item)
    {
        if (!item.TryGetProperty("changes", out var changes) || changes.ValueKind != JsonValueKind.Array)
        {
            return string.Empty;
        }

        return string.Join(
            Environment.NewLine,
            changes.EnumerateArray()
                .Select(change => JoinNonEmpty(" · ", ReadString(change, "kind"), ReadString(change, "path")))
                .Where(value => value.Length > 0));
    }

    private static string JoinText(JsonElement item, params string[] propertyNames)
    {
        var values = new List<string>();
        foreach (var propertyName in propertyNames)
        {
            if (!item.TryGetProperty(propertyName, out var property))
            {
                continue;
            }

            if (property.ValueKind == JsonValueKind.Array)
            {
                values.AddRange(property.EnumerateArray()
                    .Select(element => element.ValueKind == JsonValueKind.String ? element.GetString() : element.ToString())
                    .Where(value => !string.IsNullOrWhiteSpace(value))!);
            }
            else if (property.ValueKind == JsonValueKind.String)
            {
                var value = property.GetString();
                if (!string.IsNullOrWhiteSpace(value))
                {
                    values.Add(value);
                }
            }
        }

        var distinct = new List<string>();
        foreach (var candidate in values)
        {
            if (distinct.Any(existing =>
                    existing.Equals(candidate, StringComparison.Ordinal) ||
                    existing.Contains(candidate, StringComparison.Ordinal)))
            {
                continue;
            }

            distinct.RemoveAll(existing => candidate.Contains(existing, StringComparison.Ordinal));
            distinct.Add(candidate);
        }

        return string.Join(Environment.NewLine, distinct);
    }

    private static string JoinNonEmpty(string separator, params string?[] values) =>
        string.Join(separator, values.Where(value => !string.IsNullOrWhiteSpace(value)));

    private static string? ReadString(JsonElement element, string propertyName)
    {
        if (!element.TryGetProperty(propertyName, out var property))
        {
            return null;
        }

        return property.ValueKind == JsonValueKind.String ? property.GetString() : property.ToString();
    }
}
