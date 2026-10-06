import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import GIRepository from 'gi://GIRepository?version=2.0';
import Meta from 'gi://Meta';
import Shell from 'gi://Shell';
import Clutter from 'gi://Clutter';
import St from 'gi://St';
import * as PanelMenu from 'resource:///org/gnome/shell/ui/panelMenu.js';
import * as PopupMenu from 'resource:///org/gnome/shell/ui/popupMenu.js';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as Config from 'resource:///org/gnome/shell/misc/config.js';

const INTERFACE = `<node><interface name="com.focalet.Desktop">
  <method name="Status"><arg type="s" direction="out"/></method>
  <method name="Snapshot"><arg type="s" direction="out"/></method>
  <method name="Present"><arg type="u" direction="in"/><arg type="b" direction="out"/></method>
  <method name="RegisterCapture"><arg type="b" direction="out"/></method>
  <method name="SetCaptureClipboard"><arg type="s" direction="in"/><arg type="b" direction="in"/><arg type="ay" direction="in"/><arg type="s" direction="in"/><arg type="b" direction="out"/></method>
  <method name="CaptureClipboardState"><arg type="s" direction="in"/><arg type="s" direction="out"/></method>
  <method name="SetCaptureBusy"><arg type="b" direction="in"/></method>
  <method name="CaptureState"><arg type="s" direction="in"/></method>
  <method name="RestoreCapture"><arg type="s" direction="in"/><arg type="b" direction="out"/></method>
  <method name="Paste"><arg type="s" direction="in"/><arg type="b" direction="out"/></method>
  <method name="PasteReady"><arg type="s" direction="in"/><arg type="b" direction="out"/></method>
  <method name="ReleaseCapture"/>
  <signal name="CaptureAction"><arg type="s"/><arg type="s"/></signal>
  <signal name="SelectContent"/>
</interface></node>`;

function rectangle(rect) {
    return {x: rect.x, y: rect.y, width: rect.width, height: rect.height};
}

export default class FocaletExtension extends Extension {
    enable() {
        this._sessionId = GLib.uuid_string_random();
        this._tracker = Shell.WindowTracker.get_default();
        this._service = Gio.DBusExportedObject.wrapJSObject(INTERFACE, this);
        this._service.export(Gio.DBus.session, '/com/focalet/Desktop');
        this._owner = Gio.bus_own_name_on_connection(Gio.DBus.session,
            'com.focalet.Desktop', Gio.BusNameOwnerFlags.NONE, null, null);
        this._settings = this.getSettings();
        Main.wm.addKeybinding('select-content', this._settings,
            Meta.KeyBindingFlags.IGNORE_AUTOREPEAT, Shell.ActionMode.NORMAL,
            () => this._captureOwner ? this._captureAction('paste') : this._service?.emit_signal('SelectContent', new GLib.Variant('()', [])));
        this._lease = null; this._captureSession = null;
    }

    _status() {
        return {schemaVersion: 1, integrationVersion: 4, sessionId: this._sessionId,
            sessionType: Meta.is_wayland_compositor() ? 'wayland' : 'x11',
            shellVersion: Config.PACKAGE_VERSION, captureConnected: Boolean(this._captureOwner),
            captureStatus: this._captureStatus?.label.text ?? '',
            available: !Main.overview.visible && !Main.sessionMode.isLocked && Main.modalCount === 0};
    }

    Status() {
        return JSON.stringify(this._status());
    }

    Snapshot() {
        const status = this._status();
        if (!status.available)
            return JSON.stringify({...status, monitors: [], windows: []});
        const windows = [];
        const workspace = global.workspace_manager.get_active_workspace();
        const ordered = global.display.sort_windows_by_stacking(
            global.get_window_actors().map(actor => actor.meta_window)).reverse();
        for (const window of ordered) {
            if (window.minimized || window.is_hidden() ||
                !window.located_on_workspace(workspace))
                continue;
            const frame = window.get_frame_rect();
            const buffer = window.get_buffer_rect();
            if (frame.width <= 0 || frame.height <= 0)
                continue;
            windows.push({
                nativeWindowId: `${this._sessionId}:${window.get_stable_sequence()}`,
                processId: window.get_pid(),
                windowTitle: window.get_title() ?? '',
                application: this._tracker.get_window_app(window)?.get_name() ?? 'Application',
                appId: window.get_gtk_application_id() ?? window.get_wm_class() ?? '',
                bounds: rectangle(frame),
                bufferBounds: rectangle(buffer),
                monitor: window.get_monitor(),
            });
        }
        // Shell chrome is not a Meta.Window. Treat it as an obstruction rather
        // than attaching context from an application behind it.
        for (const tracked of Main.layoutManager._trackedActors) {
            const actor = tracked.actor;
            if (!tracked.affectsInputRegion || !actor.get_paint_visibility())
                continue;
            const [x, y] = actor.get_transformed_position();
            const [width, height] = actor.get_transformed_size();
            if ([x,y,width,height].every(Number.isFinite) && width > 0 && height > 0)
                windows.unshift({bounds: {x,y,width,height}, obstruction: true});
        }
        global.stage.queue_redraw();
        return JSON.stringify({...status,
            monitors: Main.layoutManager.monitors.map(rectangle), windows});
    }

    Present(pid) {
        // This interface can present Focalet, never activate an arbitrary app.
        for (const actor of global.get_window_actors()) {
            const window = actor.meta_window;
            const appId = window.get_gtk_application_id() ?? window.get_wm_class() ?? '';
            if (window.get_pid() === pid && appId === 'com.focalet.desktop') {
                window.activate(global.get_current_time());
                return true;
            }
        }
        return false;
    }

    async RegisterCaptureAsync(_args, invocation) {
        // Load only installed integration code, never a path supplied over D-Bus.
        // Desktop alone does not need this optional Capture component.
        if (!this._clipboardAPI) {
            const directories = [`${this.path}/native`, '/opt/focalet-capture/gnome-extension/focalet@focalet/native'];
            const directory = directories.find(path => GLib.file_test(`${path}/FocaletClipboard-1.0.typelib`, GLib.FileTest.IS_REGULAR));
            if (!directory) { invocation.return_value(new GLib.Variant('(b)', [false])); return; }
            try {
                GIRepository.Repository.prepend_search_path(directory);
                GIRepository.Repository.prepend_library_path(directory);
                this._clipboardAPI = (await import('gi://FocaletClipboard?version=1.0')).default;
            } catch (error) {
                console.error(`Focalet Capture clipboard could not load: ${error}`);
                invocation.return_value(new GLib.Variant('(b)', [false])); return;
            }
        }
        const owner = invocation.get_sender();
        if (this._captureOwner && this._captureOwner !== owner) {
            invocation.return_value(new GLib.Variant('(b)', [false])); return;
        }
        if (!this._captureOwner) {
            this._captureOwner = owner;
            this._watch = Gio.bus_watch_name_on_connection(Gio.DBus.session, owner,
                Gio.BusNameWatcherFlags.NONE, null, () => this._releaseCapture());
            this._keyboard = Clutter.get_default_backend().get_default_seat().create_virtual_device(Clutter.InputDeviceType.KEYBOARD_DEVICE);
            this._pointer = Clutter.get_default_backend().get_default_seat().create_virtual_device(Clutter.InputDeviceType.POINTER_DEVICE);
            Main.wm.addKeybinding('capture-content', this._settings,
                Meta.KeyBindingFlags.IGNORE_AUTOREPEAT, Shell.ActionMode.NORMAL, () => this._captureAction('capture'));
            this._panel = new PanelMenu.Button(0.0, 'Focalet Capture');
            this._panel.add_child(new St.Icon({gicon: Gio.icon_new_for_string(`${this.path}/focalet-symbolic.svg`), style_class: 'system-status-icon'}));
            this._captureStatus = new PopupMenu.PopupMenuItem('No capture ready', {reactive: false});
            this._panel.menu.addMenuItem(this._captureStatus);
            for (const [title, action] of [['Capture · Shift+Alt+A', 'capture'], ['Copy last batch', 'copy'],
                ['Copy text', 'copy-text'], ['Preferences…', 'preferences'], ['About Focalet Capture', 'about'], ['Quit', 'quit']]) {
                const item = new PopupMenu.PopupMenuItem(title);
                item.connect('activate', () => GLib.idle_add(GLib.PRIORITY_DEFAULT, () => { this._captureAction(action); return GLib.SOURCE_REMOVE; })); this._panel.menu.addMenuItem(item);
            }
            Main.panel.addToStatusArea('focalet-capture', this._panel);
        }
        invocation.return_value(new GLib.Variant('(b)', [true]));
    }

    _captureAction(action) {
        if (!this._captureOwner || !this._status().available) return;
        if (this._captureBusy && (action === 'capture' || action === 'paste')) return;
        let token = '';
        if (action === 'paste' || action === 'capture') {
            const window = global.display.focus_window;
            if (!window) return;
            token = GLib.uuid_string_random();
            const state = {token, window, until: GLib.get_monotonic_time() + 60000000};
            if (action === 'paste') this._lease = state;
            else this._captureSession = {...state, pointer: global.get_pointer().slice(0, 2)};
        }
        if (action === 'copy' || action === 'copy-text') {
            token = GLib.uuid_string_random();
            this._copyLease = {token, until: GLib.get_monotonic_time() + 10000000};
        }
        Gio.DBus.session.emit_signal(this._captureOwner, '/com/focalet/Desktop',
            'com.focalet.Desktop', 'CaptureAction', new GLib.Variant('(ss)', [action, token]));
    }
    _authorized(invocation) { return this._captureOwner && invocation.get_sender() === this._captureOwner; }
    SetCaptureClipboardAsync([token, image, bytes, markup], invocation) {
        const copy = this._copyLease?.token === token && this._copyLease.until > GLib.get_monotonic_time();
        if (!this._authorized(invocation) || (!copy && !this._pasteReady(token, invocation)) ||
            bytes.length > 33554432 || markup.length > 70000000 || (image && markup.length)) {
            invocation.return_value(new GLib.Variant('(b)', [false])); return;
        }
        try {
            const source = this._clipboardAPI.Source.new();
            const data = GLib.Bytes.new(bytes);
            if (image) source.add('image/png', data);
            else {
                for (const mime of ['text/plain;charset=utf-8', 'UTF8_STRING', 'text/plain']) source.add(mime, data);
                if (markup) source.add('text/html', GLib.Bytes.new(new TextEncoder().encode(markup)));
            }
            global.display.get_selection().set_owner(Meta.SelectionType.SELECTION_CLIPBOARD, source);
            this._captureClipboard = source; this._clipboardToken = token; this._copyLease = null;
            invocation.return_value(new GLib.Variant('(b)', [source.is_active()]));
        } catch (error) {
            console.error(`Focalet Capture clipboard write failed: ${error}`);
            invocation.return_value(new GLib.Variant('(b)', [false]));
        }
    }
    CaptureClipboardStateAsync([token], invocation) {
        const source = this._authorized(invocation) && this._clipboardToken === token ? this._captureClipboard : null;
        invocation.return_value(new GLib.Variant('(s)', [JSON.stringify({owned: Boolean(source?.is_active()), readAt: source?.get_read_at() ?? 0})]));
    }
    SetCaptureBusyAsync([busy], invocation) {
        if (this._authorized(invocation)) this._captureBusy = busy;
        invocation.return_value(null);
    }
    CaptureStateAsync([text], invocation) {
        if (this._authorized(invocation)) this._captureStatus.label.text = text.slice(0, 180);
        invocation.return_value(null);
    }
    RestoreCaptureAsync([token], invocation) {
        const state = this._captureSession;
        const valid = this._authorized(invocation) && state?.token === token && this._status().available &&
            global.get_window_actors().some(a => a.meta_window === state.window);
        this._captureSession = null;
        if (valid) {
            state.window.activate(global.get_current_time());
            this._pointer.notify_absolute_motion(GLib.get_monotonic_time(), ...state.pointer);
        }
        invocation.return_value(new GLib.Variant('(b)', [Boolean(valid)]));
    }
    _pasteReady(token, invocation) {
        const state = this._lease;
        const mask = Clutter.ModifierType.SHIFT_MASK | Clutter.ModifierType.CONTROL_MASK |
            Clutter.ModifierType.MOD1_MASK | Clutter.ModifierType.SUPER_MASK;
        const valid = this._authorized(invocation) && state?.token === token && this._status().available &&
            state.until > GLib.get_monotonic_time() && state.window === global.display.focus_window;
        if (!valid) { this._lease = null; return false; }
        return (global.get_pointer()[2] & mask) === 0;
    }
    PasteReadyAsync([token], invocation) {
        invocation.return_value(new GLib.Variant('(b)', [this._pasteReady(token, invocation)]));
    }
    PasteAsync([token], invocation) {
        const ready = this._pasteReady(token, invocation);
        if (ready) {
            const now = GLib.get_monotonic_time();
            // Balanced virtual key events leave physical modifier state alone.
            this._keyboard.notify_keyval(now, Clutter.KEY_Control_L, Clutter.KeyState.PRESSED);
            this._keyboard.notify_keyval(now+1, Clutter.KEY_v, Clutter.KeyState.PRESSED);
            this._keyboard.notify_keyval(now+2, Clutter.KEY_v, Clutter.KeyState.RELEASED);
            this._keyboard.notify_keyval(now+3, Clutter.KEY_Control_L, Clutter.KeyState.RELEASED);
        }
        invocation.return_value(new GLib.Variant('(b)', [ready]));
    }
    ReleaseCaptureAsync(_args, invocation) {
        if (this._authorized(invocation)) this._releaseCapture();
        invocation.return_value(null);
    }
    _releaseCapture() {
        Main.wm.removeKeybinding('capture-content');
        if (this._watch) Gio.bus_unwatch_name(this._watch);
        this._watch = 0; this._captureOwner = null; this._lease = null; this._captureSession = null;
        this._panel?.destroy(); this._panel = null; this._captureBusy = false; this._captureStatus = null;
        this._captureClipboard = null; this._clipboardToken = null; this._copyLease = null; this._keyboard = null; this._pointer = null;
    }

    disable() {
        this._releaseCapture();
        Main.wm.removeKeybinding('select-content');
        this._service?.unexport();
        this._service = null;
        if (this._owner)
            Gio.bus_unown_name(this._owner);
        this._owner = 0;
        this._tracker = null;
        this._settings = null;
    }
}
