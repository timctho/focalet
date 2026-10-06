# Capture desktop context on Ubuntu Wayland

Focalet's Linux release targets **Ubuntu 24.04 LTS x64 with GNOME Wayland**.
Other Linux desktops and display servers are not covered by this support claim.

1. Install the `.deb` from [Focalet releases](https://github.com/timctho/focalet/releases/latest).
2. Enable **Focalet Desktop Integration** in App settings for the global shortcut
   and reliable window identity and geometry.
3. Grant the screen-sharing authorization requested by the desktop portal.
4. Connect your agent, press **Alt+A**, select a region and review the attachment.

Capture can include AT-SPI accessibility context and optional Chrome or Edge
browser context. If integration, authorization or alignment is unavailable,
the attachment reports the limit. Application accessibility coverage varies.

See [Ubuntu installation and native testing](../ubuntu-testing.md),
[browser connections](chrome-edge.md), and [privacy](../privacy.md).
