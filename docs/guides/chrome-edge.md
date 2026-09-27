# Capture Chrome and Edge DOM context

Zommi supports separate Chrome and Microsoft Edge connections. Both can remain
connected at once, and capture selects the browser that owns the chosen window.
This works with the browser context helper on Windows, macOS and Ubuntu.

## Set up a connection

1. Open **App settings → Browser connections**.
2. Choose **Set up** for Chrome or Edge and follow the instructions for that
   browser and profile. Remote debugging must be available and authorized.
3. Choose **Connect**. A discoverable endpoint alone is not a connected browser.
4. Select a region in that browser and inspect the attachment's Details.

Use **Reconnect** to retry one browser; it preserves the other browser's connection.
Zommi does not restart a browser or change its profile to enable debugging.

## Why DOM is sometimes unavailable

Missing authorization, an unsupported debugging endpoint, ambiguous windows,
changed content or unreliable screen-to-page alignment can prevent structured
capture. Canvas content may exist only as pixels. Zommi preserves the selected
image and reports these limits instead of attaching unverified structure.

Native accessibility may still supply context without a browser connection.
The selected agent's separate browser tools have their own connections and permissions.

See the [complete browser setup and capture contract](../browser-context.md#connecting-a-chromium-browser)
and [privacy controls](../privacy.md#browser-connections-and-permissions).
