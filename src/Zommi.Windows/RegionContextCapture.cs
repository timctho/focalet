using System.Diagnostics;
using System.Globalization;
using System.Text.Json;
using FlaUI.Core.AutomationElements;
using FlaUI.Core.Definitions;
using FlaUI.UIA3;
using Zommi.Capture;

namespace Zommi.Windows;

internal static class RegionContextCapture
{
    public static RegionSelectionResult Capture(Rectangle region)
    {
        var source = SourceAt(region);
        var window = source?.Handle ?? 0;
        if (window == 0) return ImageOnly(region, "The region spans windows or its source could not be confirmed.");
        var title = NativeCaptureWindow.Title(window);
        var windowBounds = NativeCaptureWindow.Bounds(window);
        try
        {
            using var browser = BrowserObservationBridge.TryOpen(window);
            if (browser is not null && browser.Viewport.Contains(BrowserObservationBridge.ToRectangle(region)))
            {
                var observation = browser.Read(new Point(region.X + region.Width / 2, region.Y + region.Height / 2), region);
                var image = browser.CaptureImage(region);
                var png = image.Png;
                if (NativeCaptureWindow.ForRegion(region) != window || image.Stamp != observation.Stamp || !browser.StillMatches(observation))
                    return ImageOnly(region, "The page changed while the image was captured.", png, source);
                var snapshot = browser.Snapshot(observation, region: region);
                snapshot = snapshot with
                {
                    Region = snapshot.Region! with
                    {
                        Mapping = snapshot.Region.Mapping! with
                        {
                            ImageBounds = new CaptureRectangle(0, 0, image.Width, image.Height),
                        },
                    },
                };
                if (!observation.Elements.Any(element => !string.IsNullOrWhiteSpace(element.Text) ||
                    !string.IsNullOrWhiteSpace(element.Value) || !string.IsNullOrWhiteSpace(element.Label) ||
                    !string.IsNullOrWhiteSpace(element.Href)))
                {
                    var reason = observation.Limitation ?? "No complete text or accessible object was exposed inside this region.";
                    snapshot = snapshot with
                    {
                        Dom = null, Confidence = "limited", Limitation = reason,
                        Region = snapshot.Region with { Status = "image-only", Reason = reason },
                    };
                }
                return new RegionSelectionResult(region, png, snapshot, snapshot.Region);
            }

            var before = ReadUiaRegion(window, region);
            var pixels = ScreenCapture.CapturePng(region);
            var after = ReadUiaRegion(window, region);
            if (NativeCaptureWindow.ForRegion(region) != window ||
                NativeCaptureWindow.Title(window) != title || NativeCaptureWindow.Bounds(window) != windowBounds ||
                JsonSerializer.Serialize(before) != JsonSerializer.Serialize(after))
                return ImageOnly(region, "The window or its accessible content changed while the image was captured.", pixels, source);
            var spatial = before.Cells.Count == 0 ? null : new RegionSpatialContext { Cells = before.Cells };
            if (before.Nodes.Count == 0)
                return ImageOnly(region, "No complete accessible text or named object was exposed inside this region. Try enclosing the whole item.", pixels, source, spatial);
            var now = DateTimeOffset.UtcNow;
            var screenBounds = BrowserObservationBridge.ToRectangle(region);
            var alignment = new RegionAlignment
            {
                Status = "aligned", ScreenBounds = screenBounds,
                Mapping = new CaptureMapping
                {
                    CoordinateSpace = "desktop-physical-pixels", ScreenBounds = screenBounds,
                    ViewportBounds = screenBounds, ImageBounds = new CaptureRectangle(0, 0, region.Width, region.Height),
                },
            };
            var context = new ContextSnapshot
            {
                SnapshotId = Guid.NewGuid().ToString("D"), ObservedAtUtc = now, ExpiresAtUtc = now.AddSeconds(30),
                SurfaceKind = "Image region", Application = "Window", ProcessName = "window", WindowTitle = title,
                Source = new ObservationSource
                {
                    Provider = "windows-uia-region", NativeWindowId = window.ToString(CultureInfo.InvariantCulture),
                    ProcessId = NativeCaptureWindow.ProcessId(window), WindowBounds = windowBounds,
                },
                AccessibilityTree = new AccessibilityTreeInfo { Source = "windows-uia-region", Roots = before.Nodes, NodeCount = before.Nodes.Count },
                SpatialContext = spatial,
                Region = alignment, Confidence = "medium",
                Limitation = "Only fully enclosed accessible elements are included; partially clipped text and pixels without accessibility data remain in the image.",
            };
            return new RegionSelectionResult(region, pixels, context, alignment);
        }
        catch (Exception exception) when (BrowserObservationBridge.IsUnavailable(exception))
        {
            return ImageOnly(region, "The source could not be aligned with this image. The selected image is attached.");
        }
    }

    private sealed record WindowIdentity(nint Handle, int ProcessId, string Title, CaptureRectangle Bounds);

    private static WindowIdentity? SourceAt(Rectangle region)
    {
        var window = NativeCaptureWindow.ForRegion(region);
        return window == 0 ? null : new(window, NativeCaptureWindow.ProcessId(window),
            NativeCaptureWindow.Title(window), NativeCaptureWindow.Bounds(window));
    }

    private static RegionSelectionResult ImageOnly(Rectangle region, string reason, byte[]? png = null,
        WindowIdentity? source = null, RegionSpatialContext? spatial = null)
    {
        // Geometry is useful even when the app exposes no accessibility text.
        // A source identity is retained only across this exact image capture.
        if (png is null)
        {
            source = SourceAt(region);
            png = ScreenCapture.CapturePng(region);
        }
        if (source != SourceAt(region)) source = null;
        var screen = BrowserObservationBridge.ToRectangle(region);
        var width = System.Buffers.Binary.BinaryPrimitives.ReadInt32BigEndian(png.AsSpan(16, 4));
        var height = System.Buffers.Binary.BinaryPrimitives.ReadInt32BigEndian(png.AsSpan(20, 4));
        var alignment = new RegionAlignment
        {
            Status = "image-only", Reason = reason, ScreenBounds = screen,
            Mapping = new CaptureMapping
            {
                CoordinateSpace = "desktop-physical-pixels", ScreenBounds = screen,
                ViewportBounds = screen, ImageBounds = new CaptureRectangle(0, 0, width, height),
            },
        };
        var now = DateTimeOffset.UtcNow;
        var processName = "screen";
        if (source is not null)
        {
            try { using var process = Process.GetProcessById(source.ProcessId); processName = process.ProcessName; }
            catch (ArgumentException) { source = null; }
        }
        var snapshot = new ContextSnapshot
        {
            SnapshotId = Guid.NewGuid().ToString("D"), ObservedAtUtc = now, ExpiresAtUtc = now.AddSeconds(30),
            SurfaceKind = "Image region", Application = source is null ? "Screen" : processName,
            ProcessName = processName, WindowTitle = source?.Title ?? "",
            Source = source is null ? null : new ObservationSource
            {
                Provider = "windows-screen-region", NativeWindowId = source.Handle.ToString(CultureInfo.InvariantCulture),
                ProcessId = source.ProcessId, WindowBounds = source.Bounds,
            },
            Region = alignment, SpatialContext = source is null ? null : spatial,
            Confidence = "limited", Limitation = reason,
        };
        return new(region, png, snapshot, alignment);
    }

    private sealed record UiaRegion(IReadOnlyList<AccessibilityNodeInfo> Nodes, IReadOnlyList<RegionCellContext> Cells);

    private static UiaRegion ReadUiaRegion(nint window, Rectangle region)
    {
        using var automation = new UIA3Automation
        {
            ConnectionTimeout = TimeSpan.FromMilliseconds(300), TransactionTimeout = TimeSpan.FromMilliseconds(400),
        };
        var root = automation.FromHandle(window);
        var area = BrowserObservationBridge.ToRectangle(region);
        var nodes = new List<AccessibilityNodeInfo>();
        var cells = new List<RegionCellContext>();
        var firstDataRows = new Dictionary<CaptureRectangle, int?>();
        var queue = new Queue<AutomationElement>();
        queue.Enqueue(root);
        var start = Stopwatch.GetTimestamp();
        var visited = 0;
        var characters = 0;
        while (queue.Count > 0 && visited++ < 800 && nodes.Count < 128 && characters < 24000 &&
               Stopwatch.GetElapsedTime(start).TotalMilliseconds < 500)
        {
            var element = queue.Dequeue();
            if (element.Properties.IsPassword.ValueOrDefault || element.Properties.IsOffscreen.ValueOrDefault) continue;
            var bounds = BrowserObservationBridge.ToRectangle(element.Properties.BoundingRectangle.ValueOrDefault);
            if (!bounds.Intersects(area)) continue;
            var type = element.Properties.ControlType.ValueOrDefault;
            // A crop may cut a cell's text or border. Keep its table location
            // separate from text claimed to be fully inside the selected pixels.
            if (cells.Count < 32 && TryReadCell(element, area, firstDataRows) is { } cell &&
                !cells.Any(existing => existing.TableBounds == cell.TableBounds &&
                    existing.RowIndex == cell.RowIndex && existing.ColumnIndex == cell.ColumnIndex))
                cells.Add(cell);
            if (area.Contains(bounds) && type is ControlType.Text or ControlType.Edit or ControlType.Button or
                ControlType.CheckBox or ControlType.RadioButton or ControlType.Hyperlink or ControlType.Image or
                ControlType.DataItem or ControlType.HeaderItem or ControlType.ListItem)
            {
                var name = element.Properties.Name.ValueOrDefault;
                var value = type == ControlType.Edit ? element.Patterns.Value.PatternOrDefault?.Value.ValueOrDefault : null;
                if (!string.IsNullOrWhiteSpace(name) || !string.IsNullOrWhiteSpace(value))
                {
                    var length = (name?.Length ?? 0) + (value?.Length ?? 0);
                    if (length + characters > 24000) break;
                    nodes.Add(new AccessibilityNodeInfo
                    {
                        Role = type.ToString(), Name = name, Value = value,
                        Bounds = BrowserObservationBridge.FormatBounds(bounds),
                    });
                    characters += length;
                }
            }
            foreach (var child in element.FindAllChildren().Take(128)) queue.Enqueue(child);
        }
        return new(nodes, cells);
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
