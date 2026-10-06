#!/usr/bin/python3
"""Synthetic source and real clipboard receiver for native Capture acceptance."""
import gi
gi.require_version('Gtk', '3.0')
from gi.repository import Gtk, Gdk
import hashlib
import json
from pathlib import Path
import sys

output = Path(sys.argv[1]); text_only = '--text-only' in sys.argv
app = Gtk.Window(title='Focalet Capture synthetic fixture')
app.set_default_size(1100, 750); app.set_position(Gtk.WindowPosition.CENTER)
box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=18, margin=30); app.add(box)
for text in ('Capture fixture A · 中文', 'Capture fixture B · Second region', 'Private acceptance data only'):
    label = Gtk.Label(label=text, xalign=0)
    label.set_size_request(900, 100); box.pack_start(label, False, False, 0)
entry = Gtk.TextView(); entry.set_size_request(900, 200); box.pack_end(entry, True, True, 0)
events = []
clipboard = Gtk.Clipboard.get(Gdk.SELECTION_CLIPBOARD)
def pasted(widget, event):
    if event.keyval not in (Gdk.KEY_v, Gdk.KEY_V) or not event.state & Gdk.ModifierType.CONTROL_MASK: return False
    def targets(board, atoms, *_):
        formats = [a.name() for a in atoms]
        if 'image/png' in formats and not text_only:
            def image_received(board, selection, _):
                data = bytes(selection.get_data()); loader = GdkPixbuf.PixbufLoader.new_with_type('png'); loader.write(data); loader.close()
                image = loader.get_pixbuf()
                output.with_name(f'{output.stem}-image-{len(events)}.png').write_bytes(data)
                events.append({'type': 'image', 'width': image.get_width(), 'height': image.get_height(), 'sha256': hashlib.sha256(data).hexdigest()})
                output.write_text(json.dumps(events))
            board.request_contents(Gdk.Atom.intern('image/png', False), image_received, None)
        elif any(name in formats for name in ('UTF8_STRING', 'text/plain;charset=utf-8', 'text/plain')):
            def text_received(board, text, _):
                events.append({'type': 'text', 'text': text}); output.write_text(json.dumps(events))
            board.request_text(text_received, None)
    clipboard.request_targets(targets, None)
    return True
from gi.repository import GdkPixbuf
entry.connect('key-press-event', pasted)
app.connect('destroy', Gtk.main_quit)
app.show_all(); entry.grab_focus(); output.write_text('[]'); Gtk.main()
