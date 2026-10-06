# Focalet Linux hotkey plugin

This is an API-compatible Linux implementation for `hotkey_manager` 0.2.x.
It retains the upstream package name and MIT license, but replaces Keybinder
with exact X11 passive grabs so `Alt+A` and `Alt+Shift+A` can coexist.

Non-X11 sessions return an explicit unsupported-platform error. Wayland global
shortcuts remain compositor/portal dependent and are not reported as ready.
