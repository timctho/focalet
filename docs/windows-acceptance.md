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

It verifies an exact selected-text UIA fixture, selector cancellation, native
element selection with parent expansion and shrinking, a DPI-aware region
within one physical pixel of 40 by 30, and exact agreement
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
The native context fixture runs its own message loop and sets its thread DPI
mode so waiting for the capture helper cannot stall UIA or move the test target.
The gate checks the selected parent and both of its text children; merely
opening and confirming an unspecified scope is not a pass.

Every local Windows release job runs the same script with `-NonVisualOnly`,
which compiles the native context fixture and requires selected-text UIA
capture and selector cancellation without claiming desktop pixels or shortcuts.
Fixture compilation is supported by Windows PowerShell 5.1 and PowerShell 7;
the non-visual PR gate checks it before interactive deployment is requested.
Run the full gate explicitly from an
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

## Select content: overlapping items and image links

The unified selector uses the source application's hit test to choose the
frontmost item under the pointer. It follows that item's parent scopes for
Larger/Smaller; accessibility sibling order does not establish stacking order.
Ordinary stationary hover refreshes when the layout changes. An explicitly
expanded scope stays pinned until the pointer leaves it.

The native gesture gate covers an 18-pixel control, a quick return click while
the provider is busy, overlapping controls, and changing their stacking order
without moving the pointer. It checks painted outlines and returned bounds.
Dragging and cancelling must remain responsive during provider timeouts.

A browser image fully enclosed by a drawn region includes its directly
wrapping link's URL, even when the caption is outside the region or the image
has no alt text. The preview and agent context retain that URL. This requires
a DOM connection bound to the same browser window and document; UIA cannot
recover links for images that the page omits from its accessibility tree.
Partially enclosed images do not claim their whole object's context.

Run `scripts/accept-windows-browser.ps1` against the package to exercise both
the DOM extraction and native region pipeline for two linked images, empty-alt
images, excluded captions, and a neighboring product. Those fixture checks
do not establish behavior on a live shopping site; record its actual crop and
captured URLs separately when validating one.

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

- Validation status (2026-09-07): this CPU handoff is not yet Windows-size-accepted. Flutter formatting and analysis, 152 Flutter tests, 30 release contracts, and the Windows build pass. Fresh desktop verification is available: a nine-transition diagnostic matrix has no sampled partial/duplicate markers, reversals, or background RGB change, and native Restore retains its placement. However, Max takes 270-290 ms in that matrix and 361 ms in a separate direct gate; returning from Max to Standard takes 262 ms. These exceed the unchanged 250 ms guard. The diagnostic exits with failure, not acceptance. Downloads remains at `469c260`; local checks do not authorize deployment.
- The previous immediate native-sizing build (`469c260`) exposes shifted or clipped stale client pixels before the new Flutter layout arrives. Its fresh GDI negative-control run fails with a missing send control during Standard; the saved image confirms missing content rather than just a timing failure. Keep it as a negative control; passing builds or unit tests does not waive the rendered-pixel checks.
- Standard/Wide/Max and native Restore use one retained CPU frame without a resize animation. The application disables transitions for its own HWND, not the global Windows animation preference. Every sampled marker must match either the complete old frame or the complete new frame, within the existing three-pixel tolerance; intermediate, duplicated, or partial frames fail. The detector self-tests both one-marker and duplicate-marker bitmaps before desktop interaction.
- The contrast fixture owns a dedicated Windows message-loop thread. Pixel sampling must not starve its paint or synchronous window messages. The CPU observer retains GDI copies during the gesture and analyzes them afterward. The optional existing Desktop Duplication observer retains GPU textures instead; it is separate from the product's CPU-only handoff.
- Max uses the operating system's maximize operation. Restoring to a selected normal size updates WINDOWPLACEMENT once, including its normal bounds, rather than first restoring an obsolete size. Native Restore must retain the pre-Max placement.
- Verification also caught native Restore being discarded while the Max frame was pending. Native Max/Restore commands now retain the latest request and replay it after the handoff, rather than returning a swallowed busy error. Hide, minimize, and destruction discard pending commands. The packaged capture gate checks Max/Restore followed by an immediate Max/Restore/Max/Restore burst without waiting for frame completion between commands.
- After that fix, the full candidate Windows shortcut/capture walkthrough passes, including rapid native Restore, taskbar lifecycle, Alt+A context attachment, Alt+Shift+A image selection, cancellation, and restoring from minimized state. This diagnostic candidate is not an exact committed release package; it does not replace final size acceptance or exact-head CI and deployment verification.
- The final candidate's direct size rerun records Wide 171 ms, Standard 169 ms, and Max 275 ms. Max still fails the unchanged 250 ms threshold, so the resize fix remains unaccepted despite the separate capture walkthrough passing.
- Message paragraphs, lists, and code use regular weight. Explicit Markdown emphasis and headings retain their formatting. The compact maximize choice is `Max` and must remain on one line.
- Exercise Standard -> Wide -> Standard -> Max -> Wide -> Max -> Standard. Inspect the rendered content, not just `GetWindowRect`: native bounds can be monotonic while stale client pixels move backward or clip. Max must respect the monitor work area, and native Restore must return to the previous normal bounds.
- Run `powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts/accept-windows-window-size.ps1 -PackageDirectory artifacts/zommi-windows-x64 -ExpectedCommit <packaged-sha> -CaptureBackend Gdi` on an attached desktop. MSAA locates the real controls; the violet send button must not disappear, reverse, or leave its endpoints. A controlled contrast window sits behind Zommi; background RGB from the same bitmap may change by at most three levels per channel. First visible movement must be captured within 250 ms of mouse release, and content and native bounds must settle within 800 ms. Native Restore is sampled as a transition, not just checked at its endpoint. Foreground ownership must remain with Zommi. Captured frames, coordinates, background measurements, and timings are retained beside the result JSON, including failures. CI selects this CPU observer before deployment when `windows_interactive=true`.
- GDI capture-start and copy-completion times are QPC-based observation bounds, not presentation timestamps. `captureStartedMs`, `captureCompletedMs`, and the later `processedMs` remain distinct; GDI reports no invented presentation timestamp. The capture region includes both expected marker endpoints and adjacent background, with margins; a missing marker fails instead of being predicted or dropped. Every retained sample is checked without smoothing. GDI can combine rows from different presentations, so inspect saved images when diagnosing a partial frame and do not claim exhaustive per-presentation coverage from these samples.
- `-CaptureBackend DesktopDuplication` explicitly selects the existing presentation-timestamp observer. It requires an unrotated output containing the sampled area, fails rather than silently changing backends, and reuses an unchanged previous image only for pointer-only notifications or timeouts. Its presentation times are not interchangeable with GDI copy-completion times.
- Windows resizes the real HWND and Flutter child using the stock runner's `WM_SIZE`/`MoveWindow` path. A single CPU/GDI bitmap temporarily covers the union of old and target bounds in an opaque, non-activating owned window. `ULW_OPAQUE` avoids double alpha composition. The original Flutter window is never hidden or cloaked. Physical-metrics feedback arms the official next-frame callback during resize; a two-second timer, minimize/hide, and destruction all clean up the mask. The bitmap stays in memory and is discarded, not saved or sent anywhere by the product. There is no engine fork, custom DXGI swap chain, GPU capture API, or monitor-sized Flutter animation canvas. Ordinary Flutter/DWM rendering is unchanged.
- Window bounds, monitor work area, DPI, and maximized state are read in one native call. Normal-size endpoints are aligned to physical pixels. Max is checked against physical client bounds: native overlapped windows have invisible resize borders outside the work area. Native maximize/restore state is not synthesized with a separately animated Flutter panel.
- Button release commits a size; cancellation never changes it. Bridge tests verify physical-metrics feedback, one native endpoint per choice, queue coalescing, error recovery, and protected Max/Restore toggles. Widget tests exercise press/cancel/release and retain the same editor, focus, draft, and font size across Standard/Wide/Max client constraints. These tests do not replace packaged visual acceptance or prove exact presentation latency.
- The context point selector must retain pointer ownership and its crosshair after painting, including away from its instruction pill. The capture gate checks both continuously before sending a real mouse click; direct window messages cannot establish that transparent areas intercept input.
- The Codex completion item ID may differ from the started/delta item ID. Correlate only the unique unfinished agent item in the same thread and phase; do not guess when multiple candidates exist. Explicit delta text must be appended literally, including repeated characters. Completed snapshots remain authoritative.
- `core_bridge_process_test.dart` replays rekeyed completion and repeated ASCII/CJK fragments through the actual Rust host into the Flutter controller. `history_mapper_test.dart` protects literal delta assembly and snapshot replacement. `desktop_bridge_test.dart` covers the non-Windows bounds fallback; `thinking_capture_regressions_test.dart` checks the Max label, size request, and settings persistence. These tests do not replace packaged Windows gesture and rendered-pixel checks.
