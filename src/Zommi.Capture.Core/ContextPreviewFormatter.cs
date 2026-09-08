using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Zommi.Capture;

public static class ContextPreviewFormatter
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

    public static string Format(ContextSnapshot snapshot)
    {
        var builder = new StringBuilder();
        builder.AppendLine($"Surface: {Clean(snapshot.SurfaceKind, 40)} in {Clean(snapshot.Application, 80)}");
        AppendSnapshotDetails(builder, snapshot);
        return builder.ToString().TrimEnd();
    }

    private static void AppendSnapshotDetails(StringBuilder builder, ContextSnapshot snapshot)
    {
        if (snapshot.Region is { } region)
        {
            builder.AppendLine(region.Status == "aligned" ? "Image with text from the selected region" :
                region.Mapping is not null ? $"Image with screen location — {region.Reason}" : $"Image only — {region.Reason}");
        }
        if (snapshot.Selection.Count > 0 || snapshot.SelectionElements.Count > 0)
        {
            builder.AppendLine("PRIMARY SURFACE SELECTION (the user deliberately selected this content):");
            if (snapshot.Selection.Count > 0)
            {
                builder.AppendLine("Selected text or items:");
                foreach (var item in snapshot.Selection.Take(8))
                {
                    builder.AppendLine(snapshot.Dom?.SelectedText.Contains(item) == true
                        ? $"- {item}" : $"- {Clean(item, 1_000)}");
                }
            }

            if (snapshot.SelectionElements.Count > 0)
            {
                var totalCount = Math.Max(
                    snapshot.SelectionElements.Count,
                    snapshot.SelectionElementCount ?? snapshot.SelectionElements.Count);
                builder.AppendLine(totalCount > snapshot.SelectionElements.Count
                    ? $"Selected accessibility elements (showing {snapshot.SelectionElements.Count} of {totalCount}):"
                    : "Selected accessibility elements:");
                builder.AppendLine(JsonSerializer.Serialize(
                    snapshot.SelectionElements.Select(CompactSelectedElement),
                    AccessibilityJsonOptions));
            }
        }

        if (!string.IsNullOrWhiteSpace(snapshot.WindowTitle))
        {
            builder.AppendLine($"Window: {Clean(snapshot.WindowTitle, 240)}");
        }
        if (snapshot.Locator is { } locator)
        {
            builder.AppendLine($"{Clean(locator.Kind, 40)}: {Clean(locator.Value, 1_000)}");
        }

        if (snapshot.Dom is { } dom)
        {
            var shownLinks = new HashSet<string>(StringComparer.Ordinal);
            builder.AppendLine(dom.Mode == "region" ? "Inside the image region:" : "Selected browser content:");
            foreach (var element in dom.Elements)
            {
                builder.AppendLine($"{element.Role}: {element.Text}");
                if (!string.IsNullOrEmpty(element.Value)) builder.AppendLine(element.Value);
                if (!string.IsNullOrEmpty(element.Label)) builder.AppendLine($"Label: {element.Label}");
                if (!string.IsNullOrEmpty(element.Href) && shownLinks.Add(element.Href)) builder.AppendLine($"Link: {Clean(element.Href, 4_000)}");
            }
            if (dom.Nearby is { } nearby) builder.AppendLine($"Nearby content:\n{nearby.Text}");
            if (dom.Truncated) builder.AppendLine("Some content was omitted; choose a smaller range for complete text.");
        }

        var accessibilityTree = snapshot.AccessibilityTree;
        var hasAccessibilityTree = accessibilityTree is { Roots.Count: > 0 };
        if (hasAccessibilityTree)
        {
            builder.AppendLine("Nearby accessibility structure (compact JSON with semantic roles, selected state, necessary text, and provider grid coordinates only):");
            builder.AppendLine(JsonSerializer.Serialize(
                CompactAccessibilityTree(accessibilityTree!),
                AccessibilityJsonOptions));
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

        if (snapshot.IndicatedTarget is { } target)
        {
            builder.Append($"Mouse pointer: {Clean(target.ControlType ?? "unknown control", 80)}");
            if (!string.IsNullOrWhiteSpace(target.Name))
            {
                builder.Append($" named \"{Clean(target.Name, 240)}\"");
            }
            if (target.Row is not null || target.Column is not null)
            {
                builder.Append($" grid(row={target.Row?.ToString() ?? "?"}, column={target.Column?.ToString() ?? "?"})");
            }
            if (!string.IsNullOrWhiteSpace(target.Bounds))
            {
                builder.Append($" box={Clean(target.Bounds, 80)}");
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
        return cleaned.Length <= maximumLength
            ? cleaned
            : string.Concat(cleaned.AsSpan(0, maximumLength - 1), "…");
    }

    private static bool IsBidirectionalControl(char character) =>
        character is >= '\u202A' and <= '\u202E' or >= '\u2066' and <= '\u2069';

    private static CompactSelectedElementInfo CompactSelectedElement(SelectedElementInfo element)
    {
        var name = string.IsNullOrWhiteSpace(element.Name) ? null : Clean(element.Name, 1_000);
        var value = string.IsNullOrWhiteSpace(element.Value) ? null : Clean(element.Value, 2_000);
        if (string.Equals(name, value, StringComparison.Ordinal))
        {
            value = null;
        }

        return new CompactSelectedElementInfo
        {
            Role = Clean(element.ControlType, 80),
            Name = name,
            Value = value,
            Formula = string.IsNullOrWhiteSpace(element.Formula) ? null : Clean(element.Formula, 1_000),
            Box = string.IsNullOrWhiteSpace(element.Bounds) ? null : Clean(element.Bounds, 80),
            Row = element.Row,
            Column = element.Column,
            RowSpan = element.RowSpan is > 1 ? element.RowSpan : null,
            ColumnSpan = element.ColumnSpan is > 1 ? element.ColumnSpan : null,
        };
    }

    private static CompactAccessibilityTreeInfo CompactAccessibilityTree(AccessibilityTreeInfo tree) => new()
    {
        Truncated = tree.Truncated ? true : null,
        Roots = tree.Roots.SelectMany(CompactAccessibilityNodes).ToArray(),
    };

    private static IReadOnlyList<CompactAccessibilityNodeInfo> CompactAccessibilityNodes(AccessibilityNodeInfo node)
    {
        var name = string.IsNullOrWhiteSpace(node.Name) ? null : Clean(node.Name, 1_000);
        var value = string.IsNullOrWhiteSpace(node.Value) ? null : Clean(node.Value, 2_000);
        if (string.Equals(name, value, StringComparison.Ordinal))
        {
            value = null;
        }

        var role = Clean(node.Role, 80);
        var children = node.Children is { Count: > 0 }
            ? node.Children.SelectMany(CompactAccessibilityNodes).ToArray()
            : [];
        var hasSemanticPayload = name is not null || value is not null ||
                                 node.IsSelected is true ||
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
                Selected = node.IsSelected is true ? true : null,
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
                foreach (var header in node.RowHeaders)
                {
                    AddAccessibilityText(result, header);
                }
            }
            if (node.ColumnHeaders is not null)
            {
                foreach (var header in node.ColumnHeaders)
                {
                    AddAccessibilityText(result, header);
                }
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
        if (!string.IsNullOrWhiteSpace(value))
        {
            values.Add(Clean(value, 2_000));
        }
    }

    private sealed record CompactAccessibilityTreeInfo
    {
        public bool? Truncated { get; init; }

        public required IReadOnlyList<CompactAccessibilityNodeInfo> Roots { get; init; }
    }

    private sealed record CompactSelectedElementInfo
    {
        public required string Role { get; init; }

        public string? Name { get; init; }

        public string? Value { get; init; }

        public string? Formula { get; init; }

        public string? Box { get; init; }

        public int? Row { get; init; }

        public int? Column { get; init; }

        public int? RowSpan { get; init; }

        public int? ColumnSpan { get; init; }
    }

    private sealed record CompactAccessibilityNodeInfo
    {
        public required string Role { get; init; }

        public string? Name { get; init; }

        public string? Value { get; init; }

        public bool? Selected { get; init; }

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
