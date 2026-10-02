# Standalone capture tool for Windows

This prototype runs the capture selector independently of Zommi's chat UI and
agent broker. It needs no agent sign-in. The current public Zommi installer does
not include this separate tool.

Build from a committed checkout on Windows with .NET 8 and PowerShell 7:

```powershell
./scripts/package-capture-tool.ps1
```

Extract `artifacts/zommi-capture-tool-win-x64.zip` and open
`Zommi.CaptureTool.exe`. The package includes its .NET runtime. This prototype
is unsigned and Windows may require opening confirmation.

## Select several regions and paste once

1. Quit the full Zommi app or any other tool using Alt+A.
2. Place the text caret in the input where the capture belongs.
3. Press **Alt+A**. Drag a rectangle, then use **Add region**, **S**, or
   **Ctrl-drag** for additional regions, up to eight. Annotate any region.
4. Choose **Paste** or press **Enter** in the selector. The tool copies the whole
   batch, restores the original window/input and requests one Ctrl+V. It does
   not press Enter in the destination.

Each region keeps its own image and text, in A/B/C order. The clipboard offers
one document as Unicode plain text, HTML and RTF. The plain-text version retains
all regions' captured text, links and context even when images are unsupported.
Images are embedded in the rich versions; no image files or agent sessions are
created. Missing or unreliable source structure is described explicitly;
the tool does not invent OCR text for an image-only region.

The receiving editor chooses a clipboard format. A plain input receives text;
an editor that accepts the rich document can receive all images and text in one
paste. Supporting image attachments does not necessarily mean a chat accepts
multi-image HTML/RTF paste. Codex, Claude Code, Cursor and browser chat surfaces
need separate compatibility acceptance before claiming image insertion there.
Their handling of multiline paste also determines whether text stays in a draft.

Use **Text only** in the tray menu to force the plain version, then **Copy last
batch** to copy the same selections again. This also provides a manual fallback
when focus restoration or automatic paste is unavailable. If you select another
input or replace the clipboard between restoration and dispatch, automatic paste
is abandoned. A closed/replaced destination is not reused, and a possibly accepted
paste is never retried automatically. Cancelling selection leaves the clipboard
and previous batch unchanged.

**Capture to clipboard** in the tray menu deliberately copies without choosing a
destination. **Quit** releases Alt+A and discards the tool's last batch in memory.
The OS clipboard retains copied content until another application replaces it.

## Verification

`tests/Zommi.Capture.Tests` covers the ordered text fallback, safe rich-document
encoding, Unicode byte offsets and batch limits. `tests/Zommi.Windows.Tests`
imports the rich document through native RichEdit and checks all image objects,
context and surrounding draft text.

On a disposable Windows desktop, run the real clipboard/focus acceptance:

```powershell
dotnet run --project tests/Zommi.Windows.Tests --configuration Release -- --paste-acceptance
```

It creates synthetic plain/rich inputs, changes focus through a temporary
overlay, dispatches one paste, and checks draft preservation, multiple images,
text fallback, changed-focus/clipboard rejection and absence of an Enter key.
It replaces the clipboard with fixture content and clears its own final value.
This verifies Windows editors, not a particular agent client's composer.
