import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import Meta from 'gi://Meta';
import Shell from 'gi://Shell';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as Config from 'resource:///org/gnome/shell/misc/config.js';

const INTERFACE = `<node><interface name="com.focalet.Desktop">
  <method name="Status"><arg type="s" direction="out"/></method>
  <method name="Snapshot"><arg type="s" direction="out"/></method>
  <method name="Present"><arg type="u" direction="in"/><arg type="b" direction="out"/></method>
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
            () => this._service?.emit_signal('SelectContent', new GLib.Variant('()', [])));
    }

    _status() {
        return {schemaVersion: 1, integrationVersion: 2, sessionId: this._sessionId,
            sessionType: Meta.is_wayland_compositor() ? 'wayland' : 'x11',
            shellVersion: Config.PACKAGE_VERSION,
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

    disable() {
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
