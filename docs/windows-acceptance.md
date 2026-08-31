# Windows Flutter acceptance walkthrough

Run this walkthrough on a real, unlocked Windows 10 or 11 desktop. Widget tests
and package smoke prove implementation contracts; they do not prove physical
hotkeys, z-order, pointer behavior, permissions, UI Automation, or GPU capture.

Record the source revision, Windows version, Flutter/Rust/.NET versions,
`release-manifest.json`, archive SHA-256, selected runtime version, and whether
the package is Authenticode-signed.

## Package identity

1. Extract the complete `zommi-windows-x64.zip` to a local folder.
2. Run:

   ```powershell
   python .\scripts\verify_release.py `
     .\artifacts\zommi-windows-x64 `
     --expected-platform windows `
     --expected-commit <40-character-sha>
   ```

3. Confirm the package contains `Zommi.exe`, `zommi-core-host.exe`,
   `native\Zommi.Capture.exe`, manifest, and checksums, with no Electron or
   Node payload.
4. If signing is required, verify all three executable signatures and require
   manifest status `distribution-signed`.

Before the physical walkthrough, run the packaged helper gate:

```powershell
.\scripts\accept-windows-capture.ps1 `
  -PackageDirectory .\artifacts\zommi-windows-x64
```

It verifies an exact selected-text UIA fixture, selector cancellation, a
DPI-aware region within one physical pixel of 40 by 30, and exact agreement
between the reported bounds and returned PNG dimensions. It then launches the
exact packaged Flutter application and checks topmost compact/expanded window
bounds, real operating-system shortcut registration, injected
`Alt+A`/`Alt+Shift+A` activation, context attachment, image cancellation,
image-plus-pointer pairing, and the adjacent Flutter/Rust/two-helper process
topology. Run it from an interactive desktop PowerShell; a process launched
through WSL interop does not inherit an authoritative screen device context.

Every local Windows release job runs the same script with `-NonVisualOnly`,
which requires selected-text UIA capture and selector cancellation without
claiming desktop pixels or shortcuts. Run the full gate explicitly from an
unlocked, visible user session with:

```sh
gh workflow run ci.yml --ref <branch-or-sha> -f windows_interactive=true
```

That dispatch also runs the non-visual subset first, then executes the full
command above. The full step is skipped when `windows_interactive` is false; a
green ordinary push therefore does not claim interactive Windows acceptance.
RDP sessions can remain `Active` while losing their GDI surface when the client
is minimized or hidden, so silently attempting the full gate on every push is
not authoritative. Injected keys validate native registration and event
delivery; they are still not physical keyboard evidence.

## Window and interaction

1. Start the exact extracted `Zommi.exe`.
2. Confirm a small quiet orb appears centered just above the work-area edge and
   stays topmost without taking over the taskbar.
3. Hover it: the translucent panel expands from the same bottom-center anchor
   and focuses the composer.
4. Move outside: it remains expanded for 499 ms and collapses at 500 ms.
5. Verify blank header space drags the window while controls, transcript,
   composer, session list, and scrollable activity remain interactive.
6. With reduced motion enabled, verify working state remains visually distinct
   without continuous animation.

## Structured context (`Alt+A`)

1. Put the pointer over a browser or native control and press `Alt+A`.
2. Verify capture finishes before Zommi shows/focuses and the window does not
   jump to the pointer.
3. Confirm exactly one context chip appears and its preview shows the intended
   selection/window/URL/pointer evidence without confidence metadata.
4. Repeat on a second surface and confirm chips accumulate with unique labels.
5. Exercise selected browser text, files, a grid cell/range, and PowerPoint
   shape/text where those providers are installed.

## Explicit image (`Alt+Shift+A`)

1. Press `Alt+Shift+A` and confirm the selector appears without waiting for a
   slow UIA capture.
2. Cancel once and verify no attachment is added.
3. Select a region and verify one image chip, dimensions, preview, removal, and
   pointer-context pairing.
4. Treat blank/different GPU-composited Chrome pixels as a documented fidelity
   limitation, not a gesture or attachment failure.

## Runtime and conversation

1. Confirm runtime discovery shows the exact native/WSL host and protocol.
2. If authentication is missing, use the runtime-owned sign-in action and
   verify no credential is copied into Zommi settings.
3. Send a turn with context and confirm thinking/tool/final blocks stream once.
4. Draft while streaming, interrupt the exact active turn, switch sessions,
   and verify background running/unread state.
5. Exercise approval and structured-question responses, Markdown/code/image
   copy, and local image/HTML artifact previews.
6. Restart and confirm the exact Session Binding is restored only when safe.

## Acceptance boundary

Do not call Windows accepted until the exact packaged revision passes the
physical walkthrough above. Package assembly, JSONL process smoke, widget
goldens, and cross-compilation are supporting evidence only. Locked-RDP gestures
and hardware-composited capture require their own direct evidence.
