#!/usr/bin/env python3
"""Synthetic native Wayland application for GNOME capture acceptance."""

import json
import os
from pathlib import Path
import sys


def fixture(directory, version="3.0"):
    import gi

    gi.require_version("Gtk", version)
    from gi.repository import Gtk, Gdk, GLib

    gtk4 = version == "4.0"
    if gtk4:
        Gtk.init()
    Gtk.Settings.get_default().set_property("gtk-cursor-blink", False)
    window = Gtk.Window(title="Zommi Wayland context probe")
    window.set_default_size(720, 400)
    fixed = Gtk.Fixed()
    if gtk4:
        window.set_child(fixed)
    else:
        window.add(fixed)

    def place(widget, x, y, width=300, height=40):
        widget.set_size_request(width, height)
        fixed.put(widget, x, y)
        return widget

    label = place(Gtk.Label(label="WAYLAND_VISIBLE_LABEL"), 20, 20)
    css = Gtk.CssProvider()
    css.load_from_data(b".capture-label { background: #246080; color: white; }")
    if gtk4:
        label.add_css_class("capture-label")
        Gtk.StyleContext.add_provider_for_display(Gdk.Display.get_default(), css, 600)
    else:
        label.get_style_context().add_class("capture-label")
        Gtk.StyleContext.add_provider_for_screen(Gdk.Screen.get_default(), css, 600)
    value = place(Gtk.Entry(), 20, 80)
    value.set_text("WAYLAND_EDITABLE_VALUE")
    check = place(Gtk.CheckButton(label="Wayland selected option"), 20, 140)
    check.set_active(True)
    secret = place(Gtk.Entry(), 20, 200)
    secret.set_text("SYNTHETIC_SECRET_MUST_BE_FILTERED")
    secret.set_visibility(False)
    hidden = place(Gtk.Label(label="SYNTHETIC_HIDDEN_MUST_BE_FILTERED"), 20, 260)
    place(Gtk.Label(label="WAYLAND_OUTSIDE_CROP"), 390, 30)
    if gtk4:
        window.present()
    else:
        window.show_all()
    hidden.set_visible(False)

    def ready():
        display = Gdk.Display.get_default()
        (directory / "fixture.json").write_text(
            json.dumps(
                {
                    "pid": os.getpid(),
                    "displayType": type(display).__name__,
                    "displayName": display.get_name(),
                    "x11Display": os.environ.get("DISPLAY"),
                }
            )
        )
        return False

    GLib.timeout_add(200, ready)

    def update():
        if (directory / "change").exists() and value.get_text() != "CHANGED_VALUE":
            value.set_text("CHANGED_VALUE")
        return True

    GLib.timeout_add(50, update)
    GLib.MainLoop().run()


if __name__ == "__main__":
    fixture(Path(sys.argv[1]), sys.argv[2] if len(sys.argv) > 2 else "3.0")
