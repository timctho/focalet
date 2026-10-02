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
   recent foreground window and native focus, with the input/caret when exposed
   by Windows accessibility.
3. Switch to the source window and press **Alt+A**. Drag a rectangle, then use
   **Add region**, **S**, or **Ctrl-drag** for additional regions, up to eight.
   Annotate any region.
4. Choose **Paste** or press **Enter** in the selector. Zommi returns to the
   remembered input and pastes **image A → text A → image B → text B** in order.
   Each image keeps its original pixels and dimensions. Images are never merged.
   Zommi does not inject Enter into the destination.

There is no destination hotkey. With an input focused, Alt+A uses that window.
After switching from an input to a read-only source page/button, it returns to
the immediately previous window. Every foreground visit has its own native
bookmark, including console and custom chat inputs without a UIA `Edit` or
`ValuePattern`; late accessibility replies cannot replace a newer window's
bookmark. It does not search older windows for a previously recognized browser.
The selector displays **Paste to: window title** before confirmation, and the
tray also shows the destination and offers **Clear destination**.

Bookmarks exist only while the tool runs, so use your input once after starting
it. Known password and read-only editors are excluded. Tracking reads control
identity and selection ranges, not input values, document text, or screenshots.
Accessibility enhances the native bookmark: browsers retain editor identity
inside a shared native window, and supported editors restore their saved caret.
Custom inputs keep the app's own caret when refocused. Classic console and
Windows Terminal inputs are accepted without requiring a native child HWND or
an `Edit` role. Their rendered-output selection is never restored as an input
caret, which could put the terminal in selection mode.

A native bookmark is not an agent session identity. Without an accessible editor,
Zommi can restore the window/native control but cannot identify a chat or tab
inside it. Changing chats in the same input can change its draft. Closed/replaced
processes are not rebound silently. If the destination cannot be restored,
**Copy text** and **Copy last batch** remain available for manual recovery.

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
focus or clipboard. The routing regression seeds a real browser input, switches through an opaque
custom chat and a fresh Windows console host, then back to a read-only browser
Group inside an ARIA dialog. It verifies that paste reaches those inputs while
the old browser draft stays unchanged. Unit tests also replay
the observed Windows Terminal `Text`/`TermControl` identity and stale-provider
replies. Actual ChatGPT app acceptance remains separate from the custom fixture.
The Chromium receiver chooses text first, reproducing the
previous missing-image failure when both formats were offered together. These
fixtures verify OS/browser behavior, not a particular agent client's composer.
The test replaces the clipboard and should not run on a personal desktop.
