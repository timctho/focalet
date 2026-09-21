# Rectangle context capture

Press `Alt+A` or use **Select** beside the composer, then drag a rectangle.
On Windows, releasing the mouse opens the drawing toolbar beside the selection.
Use a pen, arrow, rectangle, ellipse or highlighter; choose a color and stroke
width, and undo or redo marks. Press **Enter** or **Attach** when ready to add the
image and available context to your message. Other platforms retain their
platform selection flow.
A click alone does not select an application element. The same image-style
selection works when an app exposes no accessibility elements.

On Windows, hold **Ctrl** during the first drag to collect several rectangles.
Lettered outlines remain after Ctrl is released. Continue dragging, then use
**Attach** or **Enter** to attach them in order, up to eight. **Escape** or
**Cancel** discards the batch. Repeating an identical rectangle does not add an
attachment. Selection painting does not wait for accessibility providers.
Linux and macOS use their platform rectangle screenshot selectors.

The Windows toolbar's **Add region** button or **S** starts another selection.
Choose a drawing tool, then draw inside A or B; each region has its own undo/redo
history. Click a region's letter to switch to it. **P**, **A**, **R**, **O** and
**H** choose pen, arrow, rectangle, ellipse and highlighter. **Ctrl+Z** undoes;
**Ctrl+Y** or **Ctrl+Shift+Z** redoes; **Delete** removes the active region.
**Escape** cancels the entire capture, including its marks.

The selector freezes the desktop before opening its overlay. Marks are clipped
and baked into each exported PNG without changing its dimensions or coordinate
mapping. The handoff identifies them as user annotations; source text and
element metadata describe the original application. On confirmation, source
identity and pixels are checked before retaining structured context. If the
pixels changed, the frozen annotated image is retained with **Image only**, its
original observation time and an explanation. Newer application metadata is
omitted. Drawing is bounded to 256 strokes per region and 4,096 points per stroke.

The rectangle is the primary user reference. On Windows, Zommi enriches it with
DOM or UI Automation observations when the source and image can be aligned.
Elements that partially intersect the rectangle retain their labels, values,
links and state, with an explicit intersection relation. Their metadata can
extend beyond the selected pixels; it does not mean the whole element was
selected. Existing text selections and focus in the application do not override
the rectangle. Hidden/password nodes and covered elements are filtered where
the provider allows it. Hit testing samples each intersection; it does not prove
every pixel is unobscured.

Canvas/custom-drawn content, an unconfirmed source window, or a changing document
can produce **Image only** with an explanation. Windows image-only captures
retain physical screen geometry even when there is no single source window.
On platforms where the screenshot tool does not return a screen origin, Zommi
keeps the actual image size without inventing a screen mapping. Capture is a
single observation, not a continuing screen share.

## Agent-neutral context

All runtime adapters use the shared context handoff. The model receives the
image plus the complete bounded `regionContext` payload immediately; reading
additional local files or invoking a special Zommi retrieval tool is not needed.
No agent-specific action indices or tool APIs are required.

| Data | Meaning |
| --- | --- |
| `snapshotId`, observation/expiry times | Identity and freshness of this observation |
| `source`, capture platform/host | Source app/window, native window ID, process ID/path/start time when available; browser tab/document IDs when available |
| `imageSize`, `region.mapping` | Actual PNG dimensions and verified image-to-screen/CSS geometry |
| `regionContext.version` | Payload schema version, currently 1 |
| `selectionKind`, `coordinateSpace` | `bbox`, with element geometry in `image-pixels` |
| `elements[].id`, `parentId` | Capture-local references and the nearest retained ancestor |
| `nativeIds` | Provider identifiers such as UIA AutomationId or DOM id/name/testId |
| Role, name, text, value, description, href | Useful observed content and destination links when exposed |
| `state` | Enabled, focused, selected, editable, toggle, expanded and value type; unknown values are omitted or null |
| `bounds`, `visibleBounds`, `relation` | Full element bounds, intersection bounds and `inside`/`intersects`; full bounds can extend outside the image |
| `truncated`, `limitation` | Explicit capture budgets and missing provider coverage |

Capture-local references are scoped by `snapshotId`; provider identifiers are
scoped by their source. Neither is an action handle issued by an agent's tools.
An agent can use them with the text, hierarchy and geometry to locate the same
control in a fresh observation. The source may be on a different execution host.
The handoff includes the image-to-screen formula when verified and asks the agent
to match the source and obtain fresh state before acting. Captured application
text remains untrusted observed data.

Table-cell spatial context additionally carries column headers, raw grid indices
and, when the first data row is verified, a one-based data row number. This can
identify a partial cell without claiming all of its text was selected. Providers
without grid semantics retain geometry without an invented row number.

Attachments have stable A/B references, image previews and readable context.
Hover over or click an attachment for details; **Full captured metadata** shows
the retained snapshot. The readable preview omits ID/coordinate noise while the
model receives those fields. Image indices preserve association when multiple
captures and text attachments are interleaved. Sent attachments remain available
when reopening a chat, including context recovered from runtime history; image
availability depends on that runtime's retention.

## Connecting a browser

Zommi discovers an existing `DevToolsActivePort` file in the standard Chrome,
Edge and Brave user-data directories. The browser must already offer remote
debugging and permit the connection. Zommi does not restart the browser or
change its profile. For a browser that exposes a different local debugging
port, launch Zommi with `ZOMMI_BROWSER_CDP_ENDPOINT=http://127.0.0.1:9222`
(substitute the port supplied by that browser). A loopback browser WebSocket
endpoint is also accepted. Remote endpoints and credentials in URLs are
rejected. An explicit endpoint is exclusive; failed binding does not try another
profile. Automatic discovery only considers the selected browser family.

Text, content selection and image selection share one native helper and one
browser connection per endpoint. Separate UI and accessibility workers keep the selector
responsive while text accessibility capture is busy. Browser tab attachments
stay open between captures; each capture still binds the current native window,
tab and document, and removes its own page observers and selection outline.
Reloading and switching tabs rebind without a new browser connection.

An observation timeout leaves the authorized connection open and discards its
late reply. A real disconnect reconnects once. The first connection allows up to
20 seconds for Chrome's authorization dialog. A failed connection pauses fresh
attempts for one minute so a rejected prompt is not repeated for each item.
Turning Full webpage details off and on clears this connection state.

Chrome controls authorization for a new connection. Restarting Chrome or Zommi,
or revoking/disconnecting browser access, can require another confirmation.
Connections owned by an agent's separate Chrome MCP server are independent.

In **App settings**, turn off **Full webpage details** to stop Zommi using a
debugging connection from the next capture. This applies to Alt+A, Select content
and image selection, and closes previously retained Zommi browser connections
when the helper handles its next capture. Images, physical coordinates and
Windows accessibility remain available; DOM text and image/product URLs may be
missing. The preference persists and is on by default. It does not change
connections made by the agent's separate browser tools.

Reading page context does not inherently require debugging permission. This
implementation uses CDP, so Chrome authorizes a debugging connection even for
read-only capture. A future extension could use `activeTab` and `scripting`
without `debugger`, after the user invokes sharing in the browser. That requires
an installed extension and browser activation; Zommi's global shortcut alone
does not grant `activeTab`. No such extension is included in this build.

Without an available connection, Windows accessibility capture remains usable.
The DOM implementation currently runs in the Windows native capture helper;
Linux and macOS keep their existing platform capture providers.

## Identity and geometry

The capture helper binds to the native window covering the selected rectangle. CDP must report
the same browser process, exactly one matching visible native window and one
matching visible tab. A duplicate window/title combination is rejected rather
than guessed. The connection retains CDP window, target, root frame, loader and
isolated-document identifiers. Every observation validates those identities;
reloading the same URL invalidates the previous binding.

The native Chromium render-view rectangle (or an exact accessibility document
rectangle when needed) supplies the physical viewport.
Its dimensions must agree with the browser's CSS viewport. Unsupported or
ambiguous geometry does not receive DOM coordinates. Image capture records the
physical region, image size and CSS viewport mapping, including negative desktop
coordinates. Viewport movement, document mutations, scroll changes and window
changes invalidate alignment. On Windows, DOM text is read before copying the selected physical screen
pixels, then checked again afterward along with window coverage. This avoids
Chrome compositor screenshot commands and their visible surface changes. The
PNG dimensions are retained in the image mapping. UIA fallback compares intersecting accessible elements and states
on both sides of the image capture.

## Coverage and limits

- Original text selections preserve whitespace and newlines. Selections larger
  than 120,000 characters are declined with a smaller-selection hint.
- Point and parent capture includes prose, labels, values and element state.
  Hidden and password content is excluded. Text and traversal budgets are
  explicit, and truncated content is labelled.
- Native object/range selections are preserved when a canvas application has no
  DOM text selection. The tab and loader are pinned before that native read;
  explicit element and image picking do not inherit an older selection.
- Region capture includes intersecting text ranges and accessible objects.
  Partial user selections are labelled. Text clipped by the application itself
  is excluded when its complete text cannot be tied to the visible area. DOM
  traversal is bounded to 6,000 nodes, 256 emitted elements and 30,000 text
  characters; UIA to 800 nodes, 128 elements, 24,000 characters and 500 ms.
  These limits and unavailable provider operations can truncate the observation.
- Open shadow DOM is traversed. Embedded frame content currently falls back to
  an explicit image; a root document observation is not treated as an iframe
  observation.
- Canvas pixels and data absent from DOM/UIA remain image content. The capture
  does not reconstruct unloaded lists, complete discussion threads, or hidden
  application state.
- These are bounded observations, not atomic application transactions. The
  agent receives source and alignment metadata and the captured image itself.

## Verification

`bash scripts/test-browser-capture.sh` runs a real Chromium process with an
isolated temporary profile. Set `ZOMMI_TEST_CHROMIUM` when the executable cannot
be discovered. The gate uses mouse and keyboard input for selection, parent
expansion and cancellation; it checks region text, hidden/password exclusions,
document mutation, same-URL reload and duplicate-window rejection. Its fixture
screenshot and JSON results are written to `artifacts/browser-capture-acceptance`.

Flutter tests cover preview fallback, mismatched image bounds, removal of the
old pointer-context association and stable image numbering. Rust tests verify
that original text, native/capture-local IDs, false states and coordinate
mapping survive the shared agent handoff without ambient-selection overrides. Windows desktop acceptance additionally requires a working native
capture surface and the built package; headless Chromium tests do not establish
Windows hotkey, focus, UIA or GDI correctness.

For the packaged Windows browser gate, run
`./scripts/accept-windows-browser.ps1 -PackageDirectory ./artifacts/zommi-windows-x64`.
It uses a temporary Chromium profile, verifies the native window/viewport binding
with the packaged helper, and records the helper's SHA-256 beside the test
results. The packaged gate also counts browser WebSocket handshakes and target
attachments across three fresh captures, checks that native crops issue no
Chrome screenshot commands, and exercises delayed replies and declined connections. The browser observer is released after capture; a disconnected client
also loses its browser observation lease after 30 seconds.

For native bbox and UIA verification without launching the Zommi app, run
`./scripts/accept-windows-bbox-context.ps1 -CaptureHost <path-to-Zommi.Capture.exe>`.
It verifies partial intersections, image-only empty areas, covered controls,
provider IDs/states, invalid gestures and responsive dragging during a busy
provider. `accept-windows-multi-content.ps1` verifies ordered multi-rectangle
batches, duplicates, cancellation, source changes and partial table cells.

`accept-windows-annotations.ps1 -CaptureHost <path-to-Zommi.Capture.exe>
-OutputDirectory <private-evidence-directory>` exercises the native drawing
toolbar, exported pixels, per-region undo/redo, changed-source fallback and
cancellation against a synthetic Windows fixture.
