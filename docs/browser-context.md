# Browser context selection

On Windows, Zommi can enrich accessible context with DOM content from a local
Chromium debugging connection. `Alt+A` captures the original text selection,
the pointed element and nearby content. It does not attach pixels.

Use the composer's context picker to click content, inspect its outline, and
adjust the scope. In a connected browser, move the pointer to another element,
press Up to select a parent or Down to return to a smaller element, then click
or press Enter to attach. Escape cancels. Other Windows applications use an
accessible-element outline with the same parent/smaller/confirm keys.

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
rejected.

Each native capture helper keeps its browser connection open for later captures.
Closing a capture removes its page observers, selection outline and tab session;
the next capture binds the current native window, tab and document again over the
same browser connection. Reloading or switching tabs does not require a new
browser connection. An interrupted connection is discarded and reconnected once.
The first connection allows up to 20 seconds for Chrome's authorization dialog.

Chrome controls authorization for a new connection. The text-capture and selector
helpers are separate processes, so each may request authorization on first use.
Restarting Chrome or Zommi, or revoking/disconnecting browser access, may require
another confirmation. This does not change connections owned by an agent's
separate Chrome MCP server.

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
changes invalidate alignment. DOM text is read before requesting a compositor
crop from that same browser tab, and checked again afterward. The PNG's actual
dimensions are retained in the image mapping. UIA fallback compares the enclosed accessible elements
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
results. The packaged gate also counts browser WebSocket handshakes across three fresh
captures. The browser observer is released after capture; a disconnected client
also loses its browser observation lease after 30 seconds.
