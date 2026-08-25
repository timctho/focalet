# Windows Electron acceptance walkthrough

Use this walkthrough on a real unlocked Windows 10 or 11 desktop. Unit tests
and package assembly are implementation evidence; the visible run verifies
native capture, global shortcuts, Electron rendering, and Codex handoff.

Record the source revision, Windows version, `codex --version`, `Zommi.exe`
SHA-256, browser version, and any failed check.

## Setup

1. Extract the complete `zommi-win-x64.zip` into a local Windows directory.
2. Verify the root Electron `Zommi.exe` and
   `resources\native\Zommi.exe` against `SHA256SUMS.txt`.
3. Start the root `Zommi.exe`. It should remain tray-resident until invoked.
4. Confirm Codex CLI is installed, signed in, and available in the default WSL
   distribution.

## Structured Alt+A context

1. Open a browser page with selectable text and a semantic table or list.
2. Select a distinctive text fragment, place the pointer over a named control,
   and press **Alt+A**.
3. Verify the rounded translucent Electron window opens beside, not under, the
   unchanged pointer and focuses the composer.
4. Verify a compact host token is added. The composer must not contain the raw
   page text and Alt+A must not add an image.
5. Hover the token. Verify `PRIMARY SELECTION` contains the selected text and
   `Mouse pointer` identifies the hovered control separately.
6. Move the pointer into the preview and scroll it. The preview must stay open,
   its content must move, and no scrollbar should be visible.
7. For a semantic table, inspect the preview JSON and verify it preserves the
   provider's nested roles/coordinates. Do not accept inferred Markdown or a
   model-constructed table as capture proof.

## Multiple contexts and explicit images

1. Change tabs or windows and press **Alt+A** again. Verify another token is
   accumulated in the same composer.
2. Press **Alt+Shift+A**, drag a region, and release. Verify exactly one image
   token is appended and its hover preview shows the selected pixels.
3. Remove a token and verify it no longer participates in the next turn.

## Codex streaming

1. Ask for an exact distinctive value from one attached context and press
   Enter.
2. Verify the user turn shows only compact tokens plus the typed prompt.
3. Verify thinking/tool activity and the answer stream in the same Electron
   surface, and that the answer contains the requested value.
4. Hide and invoke Zommi again. Verify the existing conversation remains.

## Automated controlled checks

Build the package, then run from Windows PowerShell:

```powershell
.\scripts\test-windows-ui-contract.ps1 `
  -ExecutablePath .\artifacts\zommi-win-x64\Zommi.exe `
  -EvidencePath .\artifacts\electron-glass-ui.png

.\scripts\test-windows-runtime.ps1 `
  -ExecutablePath .\artifacts\zommi-win-x64\Zommi.exe
```

The UI contract uses seeded contexts plus the real packaged image selector. The
runtime contract opens an isolated Edge fixture, invokes the real Alt+A path,
checks its accessibility hierarchy and pointer label, and requires Codex to
stream back a random exact token. Neither check proves arbitrary protected,
canvas-only, elevated, or secure-desktop surfaces.
