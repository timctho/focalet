using FlaUI.Core.AutomationElements;
using FlaUI.Core.Definitions;
using FlaUI.UIA3;

namespace Focalet.CaptureTool;

/// <summary>Per-paste editor identity, without retaining a stale UIA provider or reading its text.</summary>
internal sealed class CaptureInputIdentity
{
    private int[] runtimeId;
    private readonly Replacement? replacement;

    private CaptureInputIdentity(int[] runtimeId, Replacement? replacement)
        => (this.runtimeId, this.replacement) = (runtimeId, replacement);

    internal static AutomationElement Editor(UIA3Automation automation, AutomationElement focused)
    {
        var walker = automation.TreeWalkerFactory.GetRawViewWalker();
        var depth = 0;
        for (var node = focused; node is not null; node = walker.GetParent(node))
        {
            if (node.Properties.ControlType.ValueOrDefault == ControlType.Edit) return node;
            if (node.Properties.ControlType.ValueOrDefault is ControlType.Document or ControlType.Window) break;
            // Do not walk outside the focused control's bounded local ancestry.
            if (++depth >= 8) break;
        }
        return focused;
    }

    internal static CaptureInputIdentity Remember(UIA3Automation automation, AutomationElement editor)
    {
        var id = Id(editor);
        Replacement? replacement = null;
        var shape = Shape.Read(editor);
        if (shape.Type == ControlType.Edit && (shape.AutomationId.Length > 0 || shape.ClassName.Length > 0))
        {
            var parent = automation.TreeWalkerFactory.GetRawViewWalker().GetParent(editor);
            if (parent is not null && parent.Properties.ControlType.ValueOrDefault is not (ControlType.Document or ControlType.Window))
            {
                var children = Children(automation, parent);
                if (children is not null && children.Count(child => Shape.Read(child) == shape) == 1)
                    replacement = new(Id(parent), shape, children.Select(Id).ToArray());
            }
        }
        return new(id, replacement);
    }

    internal bool Matches(UIA3Automation automation, AutomationElement editor)
    {
        var id = Id(editor);
        if (Same(runtimeId, id)) return true;
        if (replacement is not { } previous || previous.Shape != Shape.Read(editor) ||
            previous.Siblings.Any(sibling => Same(sibling, id))) return false;
        var parent = automation.TreeWalkerFactory.GetRawViewWalker().GetParent(editor);
        if (parent is null || !Same(previous.ParentId, Id(parent))) return false;
        var children = Children(automation, parent);
        // A new provider may represent a remounted editor. Accept only the unique
        // replacement of our removed editor in its original, still-live container.
        // A pre-existing sibling, a second matching editor or a new container is
        // never treated as the selected input, even if its labels look identical.
        if (children is null || children.Any(child => Same(runtimeId, Id(child))) ||
            children.Count(child => previous.Shape == Shape.Read(child)) != 1 ||
            !children.Any(child => Same(id, Id(child)))) return false;
        runtimeId = id;
        return true;
    }

    private static List<AutomationElement>? Children(UIA3Automation automation, AutomationElement parent)
    {
        var result = new List<AutomationElement>();
        var walker = automation.TreeWalkerFactory.GetRawViewWalker();
        for (var child = walker.GetFirstChild(parent); child is not null; child = walker.GetNextSibling(child))
        {
            if (result.Count == 64) return null;
            result.Add(child);
        }
        return result;
    }

    private static int[] Id(AutomationElement element) => element.Properties.RuntimeId.Value;
    private static bool Same(int[] first, int[] second) => first.Length > 0 && first.SequenceEqual(second);
    private sealed record Replacement(int[] ParentId, Shape Shape, int[][] Siblings);
    private sealed record Shape(ControlType Type, string AutomationId, string ClassName, string Framework)
    {
        internal static Shape Read(AutomationElement element) => new(element.Properties.ControlType.ValueOrDefault,
            element.Properties.AutomationId.ValueOrDefault ?? "", element.Properties.ClassName.ValueOrDefault ?? "",
            element.Properties.FrameworkId.ValueOrDefault ?? "");
    }
}
