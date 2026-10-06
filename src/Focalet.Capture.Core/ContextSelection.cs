namespace Focalet.Capture;

public sealed record ContextSelection(IReadOnlyList<string> Text,
    IReadOnlyList<SelectedElementInfo> Elements, int? ElementCount, bool IncludesNativeSelection)
{
    public static ContextSelection ForBrowser(DomContext dom, ContextSnapshot? native)
    {
        // A canvas app can expose a grid/object selection through its native
        // accessibility provider even when getSelection() contains no text.
        // Explicit element/region picking must never inherit that ambient selection.
        var preserveNative = dom.Mode == "capture" && native is not null;
        var elements = preserveNative ? native!.SelectionElements : [];
        var text = dom.SelectedText.Count > 0 ? dom.SelectedText
            : preserveNative ? native!.Selection : [];
        return new ContextSelection(text, elements,
            elements.Count > 0 ? native?.SelectionElementCount ?? elements.Count : null,
            preserveNative && (elements.Count > 0 || dom.SelectedText.Count == 0 && text.Count > 0));
    }
}
