using System.Diagnostics;
using FlaUI.Core;
using FlaUI.Core.AutomationElements;
using FlaUI.Core.Definitions;
using FlaUI.UIA3;
using Focalet.Capture;

namespace Focalet.Windows;

internal sealed record UiaRegion(IReadOnlyList<CapturedElement> Elements, IReadOnlyList<RegionCellContext> Cells, bool Truncated);

internal static class UiaRegionCapture
{
    private static T? StateValue<T>(IAutomationProperty<T>? property) where T : struct =>
        property is not null && property.TryGetValue(out var value) ? value : null;

    public static UiaRegion Read(nint window, Rectangle region)
    {
        using var automation = new UIA3Automation
        {
            ConnectionTimeout = TimeSpan.FromMilliseconds(300), TransactionTimeout = TimeSpan.FromMilliseconds(400),
        };
        var root = automation.FromHandle(window);
        var area = BrowserObservationBridge.ToRectangle(region);
        var elements = new List<CapturedElement>();
        var cells = new List<RegionCellContext>();
        var firstDataRows = new Dictionary<CaptureRectangle, int?>();
        var queue = new Queue<(AutomationElement Element, string? ParentId)>();
        queue.Enqueue((root, null));
        var start = Stopwatch.GetTimestamp();
        var visited = 0;
        var characters = 0;
        var truncated = false;
        var structural = new HashSet<string>();
        var walker = automation.TreeWalkerFactory.GetRawViewWalker();
        bool Exposed(AutomationElement candidate, CaptureRectangle intersection)
        {
            foreach (var (dx, dy) in new[] { (.5, .5), (.1, .1), (.9, .1), (.1, .9), (.9, .9) })
            {
                var point = new Point((int)(intersection.X + intersection.Width * dx), (int)(intersection.Y + intersection.Height * dy));
                var front = automation.FromPoint(point);
                for (var depth = 0; front is not null && depth < 32; depth++, front = walker.GetParent(front))
                {
                    if (automation.Compare(candidate, front)) return true;
                    if (automation.Compare(root, front)) break;
                }
            }
            return false;
        }
        while (queue.Count > 0)
        {
            if (visited++ >= 800 || elements.Count >= 128 || characters >= 24000 || Stopwatch.GetElapsedTime(start).TotalMilliseconds >= 500)
            { truncated = true; break; }
            var (element, parentId) = queue.Dequeue();
            try
            {
                if (element.Properties.IsPassword.ValueOrDefault || element.Properties.IsOffscreen.ValueOrDefault) continue;
                var bounds = BrowserObservationBridge.ToRectangle(element.Properties.BoundingRectangle.ValueOrDefault);
                var visible = RegionContextGeometry.Intersect(bounds, area);
                if (visible is null) continue;
                var type = element.Properties.ControlType.ValueOrDefault;
                var exposed = !automation.Compare(root, element) && Exposed(element, visible);
                if (exposed && cells.Count < 32 && TryReadCell(element, area, firstDataRows) is { } cell &&
                    !cells.Any(existing => existing.TableBounds == cell.TableBounds && existing.RowIndex == cell.RowIndex && existing.ColumnIndex == cell.ColumnIndex))
                    cells.Add(cell);
                var name = element.Properties.Name.ValueOrDefault;
                var valuePattern = element.Patterns.Value.PatternOrDefault;
                var rangePattern = element.Patterns.RangeValue.PatternOrDefault;
                var value = valuePattern?.Value.ValueOrDefault;
                if (value is null && rangePattern is not null)
                    value = StateValue(rangePattern.Value)?.ToString(System.Globalization.CultureInfo.InvariantCulture);
                var nativeId = element.Properties.AutomationId.ValueOrDefault;
                var description = element.Properties.HelpText.ValueOrDefault;
                var meaningful = type is not (ControlType.Pane or ControlType.Group or ControlType.Custom or ControlType.Window) ||
                    !string.IsNullOrWhiteSpace(name) || !string.IsNullOrWhiteSpace(nativeId) || valuePattern is not null;
                if (meaningful && exposed)
                {
                    var elementTruncated = nativeId?.Length > 240;
                    string? Take(string? text)
                    {
                        if (string.IsNullOrWhiteSpace(text)) return null;
                        var length = Math.Min(text.Length, Math.Min(4000, 24000 - characters));
                        if (length < text.Length) elementTruncated = true;
                        characters += length;
                        return text[..length];
                    }
                    var toggle = StateValue(element.Patterns.Toggle.PatternOrDefault?.ToggleState);
                    var expanded = StateValue(element.Patterns.ExpandCollapse.PatternOrDefault?.ExpandCollapseState);
                    var id = $"e{elements.Count + 1}";
                    elements.Add(new CapturedElement
                    {
                        Id = id, ParentId = parentId, Provider = "windows-uia", Role = type.ToString(),
                        NativeIds = string.IsNullOrWhiteSpace(nativeId) || nativeId.Length > 240 ? null : new Dictionary<string, string> { ["uiaAutomationId"] = nativeId },
                        Name = Take(name), Value = Take(value), Description = Take(description),
                        Bounds = RegionContextGeometry.ToImage(bounds, area, region.Width, region.Height),
                        VisibleBounds = RegionContextGeometry.ToImage(visible, area, region.Width, region.Height),
                        Relation = area.Contains(bounds) ? "inside" : "intersects",
                        State = new CapturedElementState
                        {
                            Enabled = StateValue(element.Properties.IsEnabled),
                            Focused = StateValue(element.Properties.HasKeyboardFocus),
                            Selected = StateValue(element.Patterns.SelectionItem.PatternOrDefault?.IsSelected),
                            Editable = valuePattern is not null ? !StateValue(valuePattern.IsReadOnly) :
                                rangePattern is not null ? !StateValue(rangePattern.IsReadOnly) : null,
                            Toggle = toggle switch { ToggleState.On => "on", ToggleState.Off => "off", ToggleState.Indeterminate => "mixed", _ => null },
                            Expanded = expanded switch { ExpandCollapseState.Expanded => "expanded", ExpandCollapseState.Collapsed => "collapsed", ExpandCollapseState.PartiallyExpanded => "partial", _ => null },
                            ValueType = rangePattern is not null ? "number" : valuePattern is not null ? "string" : null,
                        },
                        Truncated = elementTruncated,
                    });
                    truncated |= elementTruncated;
                    if (type is ControlType.Window or ControlType.Pane or ControlType.Group && !area.Contains(bounds)) structural.Add(id);
                    parentId = id;
                }
                var children = element.FindAllChildren();
                if (children.Length > 128) truncated = true;
                foreach (var child in children.Take(128)) queue.Enqueue((child, parentId));
            }
            catch (Exception exception) when (BrowserObservationBridge.IsUnavailable(exception)) { truncated = true; }
        }
        // Partial structural ancestors only add context when a descendant in the
        // crop was read; a window/panel title alone must not align an empty crop.
        for (var index = elements.Count - 1; index >= 0; index--)
            if (structural.Contains(elements[index].Id) && !elements.Any(child => child.ParentId == elements[index].Id)) elements.RemoveAt(index);
        return new(elements, cells, truncated);
    }

    private static RegionCellContext? TryReadCell(AutomationElement element, CaptureRectangle region,
        Dictionary<CaptureRectangle, int?> firstDataRows)
    {
        try
        {
            var bounds = BrowserObservationBridge.ToRectangle(element.Properties.BoundingRectangle.ValueOrDefault);
            bool ContainsCenter(CaptureRectangle outer, CaptureRectangle inner) =>
                inner.X + inner.Width / 2 >= outer.X && inner.X + inner.Width / 2 < outer.Right &&
                inner.Y + inner.Height / 2 >= outer.Y && inner.Y + inner.Height / 2 < outer.Bottom;
            if (!ContainsCenter(bounds, region) && !ContainsCenter(region, bounds)) return null;
            var item = element.Patterns.GridItem.PatternOrDefault;
            if (item is null || element.Properties.ControlType.ValueOrDefault == ControlType.HeaderItem) return null;
            var table = item.ContainingGrid.ValueOrDefault;
            if (table is null) return null;
            var tableBounds = BrowserObservationBridge.ToRectangle(table.Properties.BoundingRectangle.ValueOrDefault);
            var row = item.Row.ValueOrDefault;
            var column = item.Column.ValueOrDefault;
            if (row < 0 || column < 0 || !tableBounds.IsValid) return null;
            var headers = element.Patterns.TableItem.PatternOrDefault?.ColumnHeaderItems.ValueOrDefault ?? [];
            if (!firstDataRows.TryGetValue(tableBounds, out var firstDataRow))
            {
                firstDataRow = ReadFirstDataRow(table, column, headers);
                firstDataRows[tableBounds] = firstDataRow;
            }
            var label = element.Properties.Name.ValueOrDefault;
            return new RegionCellContext
            {
                Bounds = bounds, TableBounds = tableBounds, RowIndex = row, ColumnIndex = column,
                DataRowNumber = firstDataRow is { } count && row >= count ? row + 1 - count : null,
                FirstDataRowIndex = firstDataRow,
                Relation = region.Contains(bounds) ? "enclosed-cell" : bounds.Contains(region) ? "contains-selection" :
                    ContainsCenter(bounds, region) ? "contains-selection-center" : "cell-center-enclosed",
                Label = string.IsNullOrWhiteSpace(label) ? null : label[..Math.Min(label.Length, 500)],
                ColumnHeaders = headers.Take(8).Select(header => header.Properties.Name.ValueOrDefault ?? "")
                    .Where(name => !string.IsNullOrWhiteSpace(name)).Select(name => name[..Math.Min(name.Length, 120)]).Distinct().ToArray(),
            };
        }
        catch (Exception exception) when (BrowserObservationBridge.IsUnavailable(exception)) { return null; }
    }

    private static int? ReadFirstDataRow(AutomationElement table, int column, AutomationElement[] cellHeaders)
    {
        var grid = table.Patterns.Grid.PatternOrDefault;
        if (grid is null) return null;
        var headers = cellHeaders.Concat(table.Patterns.Table.PatternOrDefault?.ColumnHeaders.ValueOrDefault ?? []).ToArray();
        // Chromium can expose a header as DataItem. Use the provider's header
        // identities, including wrappers, instead of inferring from labels or Y.
        bool IsHeader(AutomationElement candidate)
        {
            var walker = table.Automation.TreeWalkerFactory.GetRawViewWalker();
            bool Contains(AutomationElement ancestor, AutomationElement descendant)
            {
                for (var depth = 0; depth < 8 && descendant is not null; depth++, descendant = walker.GetParent(descendant))
                {
                    if (table.Automation.Compare(ancestor, descendant)) return true;
                    if (table.Automation.Compare(table, descendant)) break;
                }
                return false;
            }
            return headers.Any(header => Contains(header, candidate) || Contains(candidate, header));
        }
        for (var row = 0; row < Math.Min(grid.RowCount.ValueOrDefault, 16); row++)
        {
            var cell = grid.GetItem(row, column);
            var type = cell.Properties.ControlType.ValueOrDefault;
            if (type is ControlType.HeaderItem or ControlType.Header || IsHeader(cell)) continue;
            if (type is not (ControlType.DataItem or ControlType.Text or ControlType.Edit)) return null;
            return cell.Patterns.GridItem.PatternOrDefault?.Row.ValueOrDefault;
        }
        return null;
    }
}
