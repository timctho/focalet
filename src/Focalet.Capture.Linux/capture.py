#!/usr/bin/env python3
"""Standalone Focalet Capture for Ubuntu GNOME Wayland."""
from pathlib import Path
import ctypes
import json
import os
import shutil
import subprocess
import sys
import threading
import time
import gi
gi.require_version('Gtk', '3.0')
gi.require_version('Atspi', '2.0')
from gi.repository import Gtk, Gio, GLib, Gdk, Atspi
from capture_context import Helper, Item, Batch, snapshot, enrich, png_bytes
from selector import Selector, pixels, pixbuf

BUS, OBJECT = 'com.focalet.Desktop', '/com/focalet/Desktop'


class Clipboard:
    def __init__(self, path):
        self.lib = ctypes.CDLL(str(path))
        self.lib.focalet_clipboard_set.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int, ctypes.c_char_p]
        self.lib.focalet_clipboard_set.restype = ctypes.c_int
        self.lib.focalet_clipboard_read_at.restype = ctypes.c_int64
        self.lib.focalet_clipboard_owned.restype = ctypes.c_int

    def set(self, data, image=False, html=None):
        return bool(self.lib.focalet_clipboard_set(data, len(data), image, html.encode() if html else None))

    @property
    def owned(self):
        return bool(self.lib.focalet_clipboard_owned())

    @property
    def read_at(self):
        return self.lib.focalet_clipboard_read_at() / 1_000_000


class Capture(Gtk.Application):
    def __init__(self):
        super().__init__(application_id='com.focalet.capture', flags=Gio.ApplicationFlags.FLAGS_NONE)
        self.root = Path(__file__).resolve().parent
        self.batch = self.native = self.browser = self.selector = self.proxy = None
        self.busy, self.connected = False, False
        self.preference_file = Path(os.environ.get('XDG_CONFIG_HOME', str(Path.home()/'.config'))) / 'focalet-capture/preferences.json'
        try:
            self.preferences = json.loads(self.preference_file.read_text())
        except (OSError, ValueError):
            self.preferences = {}
        if not isinstance(self.preferences, dict): self.preferences = {}
        self.token, self.source_token = '', ''
        self.focus_changed, self.focused = False, None
        self.clipboard = Clipboard(self.root / 'libfocalet-clipboard.so')
        self.connect('activate', self.activate)
        self.connect('shutdown', self.shutdown)

    @property
    def busy(self):
        return self._busy

    @busy.setter
    def busy(self, value):
        self._busy = value
        if getattr(self, 'connected', False):
            try:
                self.call('SetCaptureBusy', (value,))
            except GLib.Error:
                self.connected = False

    def activate(self, *_):
        if not hasattr(self, 'held'):
            self.hold(); self.held = True
            Atspi.init()
            Atspi.set_timeout(200, 200)
            self.listener = Atspi.EventListener.new(self.focus_event, None)
            self.listener.register('object:state-changed:focused')
            GLib.timeout_add_seconds(3, self.reconnect)
        if not self.reconnect():
            return
        if not self.connected:
            self.settings()

    def reconnect(self):
        if self.proxy is None:
            try:
                self.proxy = Gio.DBusProxy.new_for_bus_sync(Gio.BusType.SESSION, Gio.DBusProxyFlags.DO_NOT_AUTO_START,
                    None, BUS, OBJECT, BUS, None)
                self.proxy.connect('g-signal', self.signal)
                self.proxy.connect('notify::g-name-owner', self.owner_changed)
            except GLib.Error:
                return True
        if self.proxy.get_name_owner() and not self.connected:
            try:
                status = json.loads(self.call('Status')[0])
                if status.get('integrationVersion', 0) >= 3:
                    self.connected = self.call('RegisterCapture')[0]
                    if self.connected:
                        self.report('Ready · Shift+Alt+A to capture')
            except (GLib.Error, ValueError):
                pass
        return True

    def owner_changed(self, *_):
        self.connected = False
        self.focus_changed = True
        if self.selector:
            self.selector.cancel(); self.selector = None

    def call(self, method, value=None):
        signature = '(b)' if method == 'SetCaptureBusy' else '(s)'
        params = GLib.Variant(signature, value) if value is not None else None
        return self.proxy.call_sync(method, params, Gio.DBusCallFlags.NONE, 1500, None).unpack()

    def report(self, text):
        if os.environ.get("FOCALET_CAPTURE_DIAGNOSTICS") == "1": print(text, flush=True)
        if self.connected:
            try:
                self.call('CaptureState', (text,))
            except GLib.Error:
                self.connected = False
        if getattr(self, 'status_label', None):
            self.status_label.set_text(text)

    def signal(self, proxy, sender, signal, params):
        if signal != 'CaptureAction': return
        action, token = params.unpack()
        actions = {'capture': lambda: self.capture(token), 'paste': lambda: self.paste(token),
                   'copy': self.copy, 'copy-text': lambda: self.copy(text=True),
                   'preferences': self.settings, 'about': self.about, 'quit': self.quit}
        if action in actions: actions[action]()

    def work(self, action, complete):
        def run():
            try: value, error = action(), None
            except Exception as caught: value, error = None, caught
            GLib.idle_add(complete, value, error)
        threading.Thread(target=run, daemon=True).start()

    def capture(self, token):
        if self.busy: return
        self.busy, self.source_token = True, token
        self.report('Select regions…')
        def start():
            if self.native is None:
                self.native = Helper(self.root/'native/focalet-linux-capture', '--capture-host')
            return self.native.request('selectContent', timeout=120)
        def ready(result, error):
            if error:
                self.failed(error); return False
            if not result.get('frames'):
                self.busy = False; self.release_helpers(); return False
            try:
                self.selector = Selector(self, result['frames'], self.selected)
            except Exception as error:
                self.failed(error)
            return False
        self.work(start, ready)

    def selected(self, selected):
        self.selector = None
        try:
            self.call('RestoreCapture', (self.source_token,))
        except GLib.Error:
            pass
        if not selected:
            self.busy = False; self.release_helpers(); return
        def collect():
            time.sleep(.2)  # Let the closing overlay leave the compositor frame.
            if self.browser is None:
                try: self.browser = Helper(self.root/'native/focalet-browser-capture')
                except OSError: pass
            items = []
            for region in selected:
                try:
                    observed = enrich(self.browser, self.native, region['source'], region['bounds'], region['width'], region['height'],
                                      lambda url: pixels(pixbuf(png_bytes(url))) == pixels(region['original']))
                except (OSError, ValueError, TimeoutError, EOFError):
                    observed = None
                metadata = snapshot(region['bounds'], region['width'], region['height'], observed,
                                    annotations=region['annotations'], limitation=None if observed else
                                    'The source changed or no aligned structure was available. The selected image is retained.')
                items.append(Item(region['png'], region['width'], region['height'], metadata))
            return Batch(items)
        def ready(batch, error):
            self.release_helpers(); self.busy = False
            if error: self.report(str(error))
            else:
                self.batch = batch; self.report(f'{len(batch.items)} regions ready · Alt+A to paste')
            return False
        self.work(collect, ready)

    def release_helpers(self):
        native, browser = self.native, self.browser
        self.native = self.browser = None
        def close():
            for helper in (native, browser):
                if helper: helper.close()
        threading.Thread(target=close, daemon=True).start()

    def failed(self, error):
        self.busy = False; self.release_helpers(); self.report(f'Capture unavailable: {error}')

    def focus_event(self, event, *_):
        if not self.busy or not self.token or not event.detail1: return
        if self.focused is not None and event.source != self.focused:
            self.focus_changed = True
        elif event.source.get_role() == Atspi.Role.PASSWORD_TEXT:
            self.focus_changed = True

    def focused_element(self):
        try:
            desktop = Atspi.get_desktop(0)
            # Expand one child at a time so a slow accessibility provider cannot
            # multiply the per-call timeout by a whole subtree on the GTK thread.
            stack = [(desktop, -1)]; count = 0; deadline = time.monotonic()+.4
            while stack and count < 800 and time.monotonic() < deadline:
                element, index = stack.pop(); count += 1
                if index == -1:
                    states = element.get_state_set()
                    if states.contains(Atspi.StateType.FOCUSED): return element
                    if element.get_role() == Atspi.Role.PASSWORD_TEXT: continue
                    children = min(200, element.get_child_count())
                    if children: stack.append((element, children-1))
                else:
                    if index: stack.append((element, index-1))
                    child = element.get_child_at_index(index)
                    if child is not None: stack.append((child, -1))
        except (GLib.Error, AttributeError):
            pass
        return None

    def paste(self, token):
        if self.busy: return
        if self.batch is None:
            self.report('Capture first with Shift+Alt+A'); return
        self.busy, self.token, self.focus_changed = True, token, False
        self.focused = self.focused_element()
        if self.focused is not None and self.focused.get_role() == Atspi.Role.PASSWORD_TEXT:
            self.stop('Choose an editable destination.'); return
        self.steps = []
        for index, item in enumerate(self.batch.items):
            if not self.preferences.get('textOnly'): self.steps.append((item.png, True))
            self.steps.append((item.text(index, len(self.batch.items)).encode(), False))
        self.wait_started = time.monotonic()
        GLib.timeout_add(20, self.wait_keys)

    def ready(self):
        try:
            return not self.focus_changed and self.call('PasteReady', (self.token,))[0]
        except GLib.Error:
            return False

    def wait_keys(self):
        if self.ready():
            self.next_step(); return False
        if time.monotonic()-self.wait_started > 2:
            self.stop('Paste stopped. Focus the input and press Alt+A again.'); return False
        return True

    def next_step(self):
        if not self.steps:
            self.stop(); return
        if not self.ready():
            self.stop('Paste stopped. Focus the input and press Alt+A again.'); return
        data, self.image_step = self.steps.pop(0)
        if not self.clipboard.set(data, self.image_step):
            self.stop('Clipboard busy. Press Alt+A to try again.'); return
        try:
            if not self.call('Paste', (self.token,))[0]:
                self.stop('Paste stopped. Focus the input and press Alt+A again.'); return
        except GLib.Error:
            self.stop('Desktop integration disconnected.'); return
        self.sent_at = time.monotonic()
        GLib.timeout_add(20, self.settle)

    def settle(self):
        elapsed = time.monotonic()-self.sent_at
        if elapsed < .04: return True  # Let injected modifier-up reach Mutter.
        owned, ready = self.clipboard.owned, self.ready()
        if not owned or not ready:
            if os.environ.get('FOCALET_CAPTURE_DIAGNOSTICS') == '1':
                print(f'Paste guard: owned={owned}, ready={ready}, inputChanged={self.focus_changed}', flush=True)
            self.stop('Paste stopped. Focus the input and press Alt+A again.'); return False
        minimum = (3 if self.preferences.get('slowerImages') else .5) if self.image_step else .15
        read_at = self.clipboard.read_at
        if read_at and elapsed >= minimum and time.monotonic()-read_at >= .12:
            self.next_step(); return False
        if elapsed > (minimum+.3 if self.image_step else 2):
            if self.image_step: self.next_step()  # Text fallback even if images are unsupported.
            else: self.stop('The destination did not read the text. Choose an input and try again.')
            return False
        return True

    def stop(self, message=None):
        self.busy, self.token, self.focused = False, '', None
        if message: self.report(message)
        # Successful repeatable paste is silent.

    def copy(self, text=False):
        if self.busy or self.batch is None: return
        self.clipboard.set(self.batch.text().encode(), html=None if text or self.preferences.get('textOnly') else self.batch.html())

    def settings(self):
        if getattr(self, 'settings_window', None):
            self.settings_window.present(); return
        window = Gtk.ApplicationWindow(application=self, title='Focalet Capture')
        self.settings_window = window
        window.set_icon_from_file(str(self.root/'app-icon.png')); window.set_default_size(510, 280)
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12, margin=24); window.add(box)
        box.pack_start(Gtk.Label(label='Capture regions with Shift+Alt+A.\nFocus your destination, then press Alt+A to paste.'), False, False, 0)
        self.status_label = Gtk.Label(label='Ready' if self.connected else 'Enable GNOME integration to use shortcuts and the panel menu.', wrap=True)
        box.pack_start(self.status_label, False, False, 0)
        enable = Gtk.Button(label='Enable desktop integration'); enable.connect('clicked', self.enable_integration)
        box.pack_start(enable, False, False, 0)
        for title, key in (('Text only', 'textOnly'), ('Slower image paste for apps that need extra time', 'slowerImages')):
            button = Gtk.CheckButton(label=title); button.set_active(bool(self.preferences.get(key)))
            button.connect('toggled', self.preference, key); box.pack_start(button, False, False, 0)
        close = Gtk.Button(label='Close'); close.connect('clicked', lambda _: window.destroy()); box.pack_start(close, False, False, 0)
        window.connect('destroy', self.closed_settings); window.show_all(); window.present()

    def closed_settings(self, *_):
        self.settings_window = self.status_label = None

    def preference(self, button, key):
        self.preferences[key] = button.get_active()
        self.preference_file.parent.mkdir(parents=True, exist_ok=True)
        temporary = self.preference_file.with_suffix('.tmp')
        temporary.write_text(json.dumps(self.preferences)); temporary.replace(self.preference_file)

    def enable_integration(self, *_):
        # A user extension avoids file ownership conflicts between two independent
        # .deb installers. An already current shared extension is reused.
        if self.connected:
            self.report('Desktop integration is enabled.'); return
        destination = Path(os.environ.get('XDG_DATA_HOME', str(Path.home()/'.local/share'))) / 'gnome-shell/extensions/focalet@focalet'
        shutil.copytree(self.root/'gnome-extension/focalet@focalet', destination, dirs_exist_ok=True)
        subprocess.run(['gnome-extensions', 'enable', 'focalet@focalet'], capture_output=True, timeout=10)
        self.reconnect()
        self.report('Desktop integration enabled.' if self.connected else 'Sign out and sign in to load the extension, then reopen Focalet Capture.')

    def about(self):
        dialog = Gtk.AboutDialog(program_name='Focalet Capture', version=(self.root/'VERSION').read_text().strip(),
            comments='Selected pixels and context for the app you already use.', website='https://github.com/timctho/focalet')
        dialog.set_logo(pixbuf((self.root/'app-icon.png').read_bytes())); dialog.run(); dialog.destroy()

    def shutdown(self, *_):
        if self.selector: self.selector.close()
        if self.connected:
            try: self.call('ReleaseCapture')
            except GLib.Error: pass
        for helper in (self.native, self.browser):
            if helper: helper.close()
        if hasattr(self, 'listener'): self.listener.deregister('object:state-changed:focused')


if __name__ == '__main__':
    raise SystemExit(Capture().run(sys.argv))
