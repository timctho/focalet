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

## Capture first, then paste into the input you choose

1. Quit the full Zommi app or another tool using Alt+A. Open the capture tool.
2. In the source window, press **Shift+Alt+A**. Drag a rectangle, then use
   **Add region**, **S**, or **Ctrl-drag** for more regions, up to eight.
   Annotate any region and choose **Done** (or Enter).
3. Switch to the destination app and click its input at the intended caret.
4. Press **Alt+A** to paste **image A → context A → image B → context B**.
   Each image keeps its original pixels and dimensions. Images are never merged,
   and Zommi does not inject Enter into the destination.

Capture only prepares a batch in memory. It does not choose a destination,
change the clipboard or paste. There is no background input tracking or remembered
window: Alt+A uses the window and control focused at that moment and leaves the
app's caret alone. If focus changes while releasing the hotkey, paste is cancelled.
Known password and read-only inputs are excluded. Accessibility checks inspect
control identity, not input values or document text.

The last capture stays ready until you finish a new capture or quit. Press
**Alt+A** again to paste the same complete batch, either at the current caret or
in a different input you choose. Presses during an active paste are ignored,
never queued. An interrupted paste does not resume automatically; another Alt+A
starts the whole batch again. **Copy text** and **Copy last batch** also remain
available. Alt+A before your first capture asks you to capture first. Cancelling
a new capture preserves the previous batch and clipboard.

## Images and text

Automatic paste uses separate clipboard transfers:

- Each image step offers native PNG/DIB and an image-only RTF representation,
  with no competing plain-text format. Each image is limited to 32 megapixels
  and 32,767 pixels per dimension.
- The next step offers only Unicode text for that region: its A/B/C label,
  readable context and the complete bounded snapshot JSON, including DOM/UIA
  IDs, hierarchy, geometry, state, source and alignment.

Orca's terminal reads clipboard text before trying an image; separate image-only
and text-only transfers let both reach the input. Orca's native chat obtains a
preview and separately calls Electron's `clipboard.readImage()` to save the image.
A first clipboard read alone does not establish that this second read completed.
The receiving app controls attachment placement and multiline text insertion;
client-specific attachment/upload completion remains separate from clipboard reads.

By default, the tool waits at least **0.5 seconds per image** and 0.15 seconds per
text step. It also waits for a clipboard read and a short settling period before
continuing. These are minimum waits, not a guarantee of total paste duration.
If your app loses images at this speed, enable **Slower image paste** in the tray
menu. That mode keeps each image for at least three seconds to accommodate
receivers that read a preview and then read the clipboard again later to save it.
The choice lasts until the tool exits. A clipboard read does not prove that an
app attached/uploaded an image, and the tool cannot automatically detect a slow
second read. Later first reads get additional settling time, up to five seconds.
Images unread after five seconds are skipped, while their context text is still
pasted. If text is not read, or
focus, modifiers or clipboard ownership changes, remaining steps stop. Already
dispatched steps are never retried automatically. **Text only** in the tray skips
image operations entirely.

**Copy text** copies the complete context. **Copy last batch** offers a rich HTML/RTF document with separate images and a plain-text
fallback; manual Ctrl+V still depends on the receiver's format support. They do
not create a combined native image. The last batch remains in memory for manual
reuse after completed or interrupted automatic paste. No image files or agent sessions
are created by the tool. Cancelling selection leaves the clipboard and previous
batch unchanged.

The selector restores the source's original focus and pointer location and waits
for the desktop compositor before reading context, so toolbar/drag hover changes
are not mistaken for source changes. Captured pixels must still match the selected
frozen image. Real content changes or unavailable source structure remain explicitly
image-only; the tool does not invent OCR text or attach newer DOM to older pixels.

**Quit** releases both hotkeys and discards the last batch. The OS
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

It uses synthetic native plain/rich inputs, a disposable Chromium profile, and a
locked Electron fixture (`npm ci --prefix tests/clipboard-electron`). The Electron
fixture exercises both a terminal's text-first native IPC route and a chat's DOM
preview followed by a later native `clipboard.readImage()` save. It verifies
image/context order, original dimensions/pixels, complete metadata, draft/caret
preservation and no Enter. Both routes run at the default speed with asynchronous
reads, and in slower mode with the existing 1.5-second delay between preview and
save. Default-speed tests also reject an unnecessary two-second gap before context.
The hotkey test invokes both real registered shortcuts,
verifies capture leaves the clipboard untouched, changes to a different input,
then confirms that Alt+A inserts the batch only there. Another deliberate Alt+A
reuses the batch at the same or a different input. Busy presses do not queue;
cancellation and interruption retain the batch without automatic retries. Focus
and clipboard interruption tests stop remaining steps. Actual ChatGPT and Orca sessions remain
separate from these isolated fixtures.

The test replaces the clipboard and should run only on a disposable CI desktop.
