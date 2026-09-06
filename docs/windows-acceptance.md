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
exact packaged Flutter application with an isolated temporary `APPDATA` profile,
so saved user size preferences cannot change the normal-window test baseline.
It checks stable normal/expanded taskbar
window bounds, taskbar minimize/restore behavior, real operating-system shortcut
registration, injected
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
2. Confirm one complete chat window appears in the taskbar and is not topmost.
3. Click its taskbar icon to minimize it, then click again to restore it.
4. Expand and restore the large window without moving its bottom-center anchor.
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

1. Minimize Zommi, press `Alt+Shift+A`, and confirm the selector appears without
   waiting for a slow UIA capture.
2. Cancel once and verify no attachment is added and the chat is restored,
   foreground, and ready for composer input.
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
# Message and window-size regressions

- Known limitation: Standard/Wide now switch immediately, but a stale client frame can still shift or clip before Flutter presents the new layout. This remains a failing visual regression, not a completed resize fix. Passing build, unit, capture, or deployment checks does not waive this limitation.
- Native-animation validation limitation: Windows' maximize/restore transition cross-fades and scales the old and new client images. The current fixed violet-button threshold can therefore lose the marker even while the whole window remains visible and moves continuously. Preserve the full frames and distinguish this detector failure from a disappearing window; do not treat the existing marker gate as native-animation acceptance. A separate visible-surface diagnostic is supporting evidence only. The Standard/Wide stale-content checks still apply unchanged.
- The contrast fixture owns a dedicated Windows message-loop thread. Pixel sampling must not starve its paint or synchronous window messages. Frame copies retained during the gesture are GPU-only; analysis afterward reuses one CPU-readable texture. Keep a known-bad package as a negative control for the same, unchanged pixel and latency assertions.
- Max uses the operating system's maximize operation. Restoring to a selected normal size updates WINDOWPLACEMENT once, including its normal bounds, rather than first restoring an obsolete size. Native Restore must retain the pre-Max placement.
- Message paragraphs, lists, and code use regular weight. Explicit Markdown emphasis and headings retain their formatting. The compact maximize choice is `Max` and must remain on one line.
- Exercise Standard -> Wide -> Standard -> Max -> Wide -> Max -> Standard. Inspect the rendered content, not just `GetWindowRect`: native bounds can be monotonic while stale client pixels move backward or clip. Max must respect the monitor work area, and native Restore must return to the previous normal bounds.
- Run `powershell.exe -NoProfile -File scripts/accept-windows-window-size.ps1 -PackageDirectory artifacts/zommi-windows-x64 -ExpectedCommit <packaged-sha>` on an attached desktop. MSAA locates the real controls; complete DXGI Desktop Duplication frames track the violet send button with no disappearance, reversal, or endpoint excursion; enabled native Max/Restore transitions additionally require at least five distinct positions. A controlled contrast window sits behind Zommi; background RGB is sampled beside the control from the same bitmap and may change by at most three levels per channel. Meaningful movement must be presented within 250 ms of mouse release: the input and DXGI presentation timestamps use the same system QPC clock. The probe records immutable GPU copies during interaction, then maps and analyzes every captured frame afterward. `firstObservedMotionMs` records capture completion; each frame's separate `processedMs` records the later pixel analysis. Neither substitutes for the presentation timestamp. Both rendered content and native bounds must settle within 800 ms. Native endpoint, trajectory, Max, and Restore assertions remain. Captured desktop frames, background measurements, and response/settling times are retained beside the result JSON, including unsuccessful transitions. CI runs this gate before deployment when `windows_interactive=true`.
- The pixel gate requires an unrotated output that contains the sampled area and supports Desktop Duplication. It fails rather than falling back to unsynchronized GDI copying, which can combine rows from different frames during motion. No presented image is discarded or smoothed; the 3-pixel tolerance applies to every sample, including control dimensions. Pointer-only notifications have no updated desktop image: initialization waits up to two seconds for the first nonzero presentation timestamp. Later pointer-only notifications or timeouts reuse the unchanged previous frame, not a predicted position.
- Windows resizes the actual native window and its Flutter child together. WM_SIZE follows the standard Flutter runner's MoveWindow path, allowing the engine's own resize/render synchronization to run. Flutter layout uses the real client constraints, not a separate monitor-sized canvas. The application has no resize screenshot, overlay window, CPU readback, custom DXGI swap chain, or forced compositor-frame handshake. Desktop Duplication remains in the acceptance probe only, to observe the real output.
- Window bounds, monitor work area, DPI, and maximized state are read in one native call. Normal-size endpoints are aligned to physical pixels. Max is checked against physical client bounds: native overlapped windows have invisible resize borders outside the work area. Native maximize/restore state is not synthesized with a separately animated Flutter panel.
- Standard/Wide changes apply one native endpoint immediately, as approved by the owner. Max/Restore use Windows' own transition and respect the system animation setting. The application does not change that setting or emulate disabled animations. The gate records it and requires intermediate positions only for enabled native transitions, while retaining disappearance, reversal, background, and latency assertions for every size choice. It samples the entire work area rather than assuming that a missing control in a bottom strip disappeared from the desktop. Bridge tests verify one bounds operation per choice, including returning from Max; widget tests retain the editor and draft under actual client-size changes. These tests do not replace packaged visual acceptance.
- The context point selector must retain pointer ownership and its crosshair after painting, including away from its instruction pill. The capture gate checks both continuously before sending a real mouse click; direct window messages cannot establish that transparent areas intercept input.
- The Codex completion item ID may differ from the started/delta item ID. Correlate only the unique unfinished agent item in the same thread and phase; do not guess when multiple candidates exist. Explicit delta text must be appended literally, including repeated characters. Completed snapshots remain authoritative.
- `core_bridge_process_test.dart` replays rekeyed completion and repeated ASCII/CJK fragments through the actual Rust host into the Flutter controller. `history_mapper_test.dart` protects literal delta assembly and snapshot replacement. `desktop_bridge_test.dart` covers the non-Windows bounds fallback; `thinking_capture_regressions_test.dart` checks the Max label, size request, and settings persistence. These tests do not replace packaged Windows gesture and rendered-pixel checks.
