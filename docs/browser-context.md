# Browser context selection

On Windows, Zommi can enrich accessible context with DOM content from a local
Chromium debugging connection. `Alt+A` captures the original text selection,
the pointed element and nearby content. It does not attach pixels.

Use **Select content** beside the composer to open the Windows content picker.
Point at content to see its accessible outline, then click to attach it. Drag
anywhere to choose a rectangle instead. The visible **Larger**, **Smaller** and
**Whole window** controls change the scope without needing another shortcut.
Up/Down and Enter remain available. Escape cancels and returns to the draft.
If an application exposes no usable object, the picker asks you to drag a region.

Hold **Ctrl** while clicking or dragging to collect several selections. Numbered
outlines stay on screen when Ctrl is released. Continue selecting, then press
**Enter** to attach them in order (up to 16); **Escape** discards the whole batch.
Each attachment retains its own image, context and coordinates. Repeating an
identical selection does not add another attachment.

Dragging starts immediately, including over an outlined item. Hover lookup runs
on a separate thread and keeps only the newest pointer position. Ordinary hover
can move from a container into its small children; only a scope you explicitly
expand stays pinned while the pointer remains inside it. The toolbar stays at
the top of the starting screen instead of chasing the outline.

This first version uses Windows accessibility for the interactive outlines;
the final rectangle goes through the existing DOM/UIA region capture pipeline.
Every explicit selection includes an image and aligned text when available.
Free rectangles automatically collect the readable elements they fully enclose,
including multiple elements. Partially clipped UIA elements and DOM text lines
are omitted. Canvas/custom-drawn content, an unconfirmed source window, or a
changing document can produce **Image only** with an explanation in the preview.
Whole-window capture brings the explicitly chosen window forward and includes
its visible desktop portion. Moved sources and covering owned dialogs are
rejected. It is a single snapshot, not a continuing screen share.
Other platforms retain their existing selection providers.

Windows captures without accessible text show **Image with screen location**
and retain the physical screen rectangle and actual image dimensions. A stable source also includes the app/window title, HWND,
process ID and window bounds. A region spanning multiple windows keeps its
screen mapping without guessing one source. The agent receives the capture ID,
time and image-to-screen formula. These coordinates describe that frame; the
agent must observe again after a window, scroll or content change before acting.
This supplies location even when a custom UI exposes no accessible text.

When a crop intersects an accessible table cell, separate spatial context carries
its column header, raw grid indices and, when the first data row can be verified,
the one-based data row number. This can identify a partial Redis cell without
claiming that its complete text is inside the image. Providers without grid
semantics retain coordinates without an invented row number.

Enclosed images and text retain their own wrapping link's URL, including cards
that use background thumbnails. The preview lists each URL once. Region bounds
allow one physical pixel of rounding difference. Viewport scrolling does not
clip against the body's scrolled border box; actual nested overflow still excludes
hidden rows and partially clipped items.

Attachments show a stable A/B reference and a readable excerpt or image preview.
**Adjust** replaces that attachment in place, preserving its reference and the
typed question. Cancellation or a capture failure preserves the old attachment.
References are included in the agent handoff beside the corresponding image
index. Removed references are not reused within the same draft. Image markup
and arrows are not included in this first version.

`Alt+Shift+A` selects an image region. Text is collected from the final region,
not from the location of the pointer before dragging. The preview says **Image
only** when structural data cannot be aligned. A text context can still be
attached separately. Each image and its associated context retains an image
index in the agent handoff, including when other attachments are interleaved.

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

The capture helper binds to the native window under the pointer. CDP must report
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
PNG dimensions are retained in the image mapping. UIA fallback compares the enclosed accessible elements
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
- Region capture includes fully enclosed text ranges and accessible objects.
  A partly clipped line is not sent as though the entire line was selected.
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
that original selection, identity and coordinate mapping survive the agent
handoff. Windows desktop acceptance additionally requires a working native
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
