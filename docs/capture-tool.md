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

## Select several regions and paste back

1. Quit the full Zommi app or another tool using Alt+A. Open the capture tool.
2. Use the destination input normally. Zommi automatically remembers the most
   recent editable input and its caret when exposed by Windows accessibility.
3. Switch to the source window and press **Alt+A**. Drag a rectangle, then use
   **Add region**, **S**, or **Ctrl-drag** for additional regions, up to eight.
   Annotate any region.
4. Choose **Paste** or press **Enter** in the selector. Zommi returns to the
   remembered input and pastes **image A → text A → image B → text B** in order.
   Each image keeps its original pixels and dimensions. Images are never merged.
   Zommi does not inject Enter into the destination.

There is no destination hotkey. Focusing another editable input updates the
bookmark; switching to a page, button, or other non-editor retains the previous
input. The tray shows the destination and has **Clear destination**. The bookmark
exists only while the tool runs, so use your input once after starting it.
Password and read-only fields are excluded. Tracking reads control identity and
selection ranges, not input values, document contents, or screenshots.

The bookmark includes the accessible editor inside the window, so separate
browser inputs sharing one native window are distinguished. Where the provider
supports text ranges, Zommi restores the saved caret/selection; other editors
retain their own caret when refocused. This is a Windows input bookmark, not an
agent session identity. Changing chats in the same input can change its draft.
Closed/replaced processes or unavailable editors are not rebound silently. If
Windows cannot expose an editable input, **Capture to clipboard** and manual
paste remain available.

## Images and text

Automatic paste uses separate clipboard transfers:

- Each image step offers native PNG/DIB and an image-only RTF representation,
  with no competing plain-text format. Each image is limited to 32 megapixels
  and 32,767 pixels per dimension.
- The next step offers only Unicode text for that region: its A/B/C label,
  readable context and the complete bounded snapshot JSON, including DOM/UIA
  IDs, hierarchy, geometry, state, source and alignment.

This fixes the text-first format choice in Orca 1.4.218's terminal: when text
and an image share a clipboard, that terminal chooses text. It can now request
an image on one paste and context on the next. Orca native chat also receives
separate image and text operations. Actual Orca, Codex, Claude Code and Cursor
composers still need individual acceptance; the receiving app controls where
attachment previews appear and how multiline text is inserted.

The tool waits for clipboard data reads and leaves time for asynchronous image
readers before publishing the next step. A clipboard read does not prove that an
app attached/uploaded an image. Images that are not read within three seconds
are skipped, while their context text is still pasted. If text is not read, or
focus, modifiers or clipboard ownership changes, remaining steps stop. Already
dispatched steps are never retried automatically. **Text only** in the tray skips
image operations entirely.

**Copy text** copies the complete context. **Copy last batch** and **Capture to
clipboard** offer a rich HTML/RTF document with separate images and a plain-text
fallback; manual Ctrl+V still depends on the receiver's format support. They do
not create a combined native image. The last batch remains in memory for manual
recovery after interrupted automatic paste. No image files or agent sessions
are created by the tool. Cancelling selection leaves the clipboard and previous
batch unchanged.

The selector restores the source's original focus and pointer location and waits
for the desktop compositor before reading context, so toolbar/drag hover changes
are not mistaken for source changes. Captured pixels must still match the selected
frozen image. Real content changes or unavailable source structure remain explicitly
image-only; the tool does not invent OCR text or attach newer DOM to older pixels.

**Quit** releases Alt+A and discards the input bookmark and last batch. The OS
clipboard retains its last payload until another application replaces it.

## Verification

`tests/Zommi.Capture.Tests` covers ordered per-region text with complete metadata,
safe rich-document encoding, Unicode byte offsets and batch limits.
`tests/Zommi.Windows.Tests` checks rich-document import and individual native
image geometry/pixels.

On a disposable Windows desktop, run the real clipboard/focus acceptance:

```powershell
dotnet run --project tests/Zommi.Windows.Tests --configuration Release -- --paste-acceptance
```

It uses synthetic native plain/rich inputs and a disposable Chromium profile.
Checks cover automatic input tracking across a source-window switch, browser
editor/caret restoration, separate image/text event order, two original-sized
images, text fallback, draft preservation, no Enter, and stopping after changed
focus or clipboard. The Chromium receiver chooses text first, reproducing the
previous missing-image failure when both formats were offered together. These
fixtures verify OS/browser behavior, not a particular agent client's composer.
The test replaces the clipboard and should not run on a personal desktop.
