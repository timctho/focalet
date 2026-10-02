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

1. Quit the full Zommi app or any other tool using Alt+A / Alt+Shift+A.
2. Place the text caret in the destination input and press **Alt+Shift+A**.
   This remembers that window and focused control until you set another
   destination or choose **Clear destination** in the tray.
3. Switch to the source window and press **Alt+A**. Drag a rectangle, then use
   **Add region**, **S**, or **Ctrl-drag** for additional regions, up to eight.
   Annotate any region.
4. Choose **Paste** or press **Enter** in the selector. The tool copies the whole
   batch, restores the remembered window/input and requests one Ctrl+V. It does
   not press Enter in the destination.

If no destination has been remembered, the first Alt+A uses the currently focused
input and retains it for subsequent captures. Alt+Shift+A changes that destination.
A remembered HWND/control is a Windows focus bookmark, not an agent session API;
changing chats/tabs within the same app can change its draft or caret. Set the
intended destination again after changing chats. Closed/replaced processes are
never silently rebound to a new destination.

Every region keeps its text and image in A/B/C order. The clipboard offers:

- Unicode text with readable context **and the complete bounded snapshot JSON**:
  DOM/UIA provider IDs, hierarchy, geometry, state, source and alignment.
- HTML/RTF documents containing each individual image with its corresponding text.
- Native PNG/DIB for image paste handlers. Multiple regions are stacked into one
  labelled image at original pixel resolution; one region is unchanged. The
  combined image is limited to 32 megapixels and 32,767 pixels per dimension.

The receiving editor chooses a format. Plain inputs retain all available text
when images are unsupported. Image-only chat handlers receive the complete
A/B/C image, but may ignore the accompanying text. **Copy text** in the tray copies
all regions' context without images. A single generic Ctrl+V cannot force an app
to accept both attachments and text; attaching separate images plus inserting text
requires a receiver-specific integration with acknowledgement.

Inspection of Orca 1.4.218 explains the previous prototype's incompatibility:
its native chat reads an image file/native clipboard image, not HTML/RTF embedded
images, and its terminal prefers clipboard text when text exists. The native PNG
fix covers image-file paste handlers; Orca terminal still receives the text.
Actual Codex, Claude Code, Cursor and Orca composer sessions require individual
acceptance. Their handling of multiline paste determines whether text stays in a draft.

The selector restores the source's original focus and pointer location and waits
for the desktop compositor before reading context, so toolbar/drag hover changes
are not mistaken for source changes. Captured pixels must still match the selected
frozen image. Real content changes or unavailable source structure remain explicitly
image-only; the tool does not invent OCR text or attach newer DOM to older pixels.

Use **Text only** in the tray to force plain text, then **Copy last batch** to copy
those same selections again. No image files or agent sessions are created. If the
destination changes or the clipboard is replaced between restoration and dispatch,
automatic paste stops. A possibly accepted paste is never retried automatically.
Cancelling selection leaves the clipboard and previous batch unchanged.

**Capture to clipboard** copies without choosing a destination. **Quit** releases
both hotkeys and discards the destination and last batch in memory. The OS clipboard
retains copied content until another application replaces it.

## Verification

`tests/Zommi.Capture.Tests` covers the ordered text fallback, safe rich-document
encoding, Unicode byte offsets and batch limits. `tests/Zommi.Windows.Tests`
imports the rich document through native RichEdit and checks all image objects,
context and surrounding draft text. It also checks that native PNG/DIB retains
every selected pixel without resizing.

On a disposable Windows desktop, run the real clipboard/focus acceptance:

```powershell
dotnet run --project tests/Zommi.Windows.Tests --configuration Release -- --paste-acceptance
```

It creates synthetic plain/rich inputs, changes focus through a temporary
overlay, dispatches one paste, and checks draft preservation, multiple images,
text fallback, changed-focus/clipboard rejection and absence of an Enter key.
It replaces the clipboard with fixture content and clears its own final value.
It also drives a disposable Chromium profile through an actual image paste
event and a plain textarea using the same clipboard. This verifies browser image
paste formats and text fallback, not a particular agent client's composer.
