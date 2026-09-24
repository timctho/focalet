// Loaded only in the disposable GNOME acceptance session, never packaged.
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import Clutter from 'gi://Clutter';
import Shell from 'gi://Shell';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
const XML = `<node><interface name="com.zommi.TestDriver">
  <method name="Ready"/><method name="Key"><arg type="u" direction="in"/><arg type="b" direction="in"/></method>
  <method name="Click"><arg type="i" direction="in"/><arg type="i" direction="in"/></method>
  <method name="Motion"><arg type="i" direction="in"/><arg type="i" direction="in"/></method>
  <method name="Button"><arg type="b" direction="in"/></method>
  <method name="Window"><arg type="u" direction="in"/><arg type="s" direction="out"/></method>
  <method name="Activate"><arg type="u" direction="in"/></method>
  <method name="Snapshot"><arg type="s" direction="in"/></method>
</interface></node>`;
export default class Driver extends Extension {
    enable() {
        this.pointer = Clutter.get_default_backend().get_default_seat().create_virtual_device(Clutter.InputDeviceType.POINTER_DEVICE);
        this.keyboard = Clutter.get_default_backend().get_default_seat().create_virtual_device(Clutter.InputDeviceType.KEYBOARD_DEVICE);
        this.service = Gio.DBusExportedObject.wrapJSObject(XML, this);
        this.service.export(Gio.DBus.session, '/com/zommi/TestDriver');
        this.owner = Gio.bus_own_name_on_connection(Gio.DBus.session, 'com.zommi.TestDriver', Gio.BusNameOwnerFlags.NONE, null, null);
    }
    Ready() { Main.overview.hide(); }
    Key(key, pressed) { this.keyboard.notify_keyval(GLib.get_monotonic_time(), key, pressed ? Clutter.KeyState.PRESSED : Clutter.KeyState.RELEASED); }
    Motion(x,y) { this.pointer.notify_absolute_motion(GLib.get_monotonic_time(),x,y); }
    Button(pressed) { this.pointer.notify_button(GLib.get_monotonic_time(),1,pressed ? Clutter.ButtonState.PRESSED : Clutter.ButtonState.RELEASED); }
    Window(pid) {
        const window = global.get_window_actors().map(a => a.meta_window).find(w => w.get_pid() === pid);
        if (!window) return '{}';
        const r = window.get_buffer_rect();
        return JSON.stringify({x:r.x,y:r.y,width:r.width,height:r.height,focused:window.has_focus()});
    }
    Activate(pid) {
        global.get_window_actors().map(a => a.meta_window).find(w => w.get_pid() === pid)?.activate(global.get_current_time());
    }
    SnapshotAsync([path], invocation) {
        const stream = Gio.File.new_for_path(path).replace(null, false, Gio.FileCreateFlags.NONE, null);
        const shot = new Shell.Screenshot();
        shot.screenshot(false, stream, (object, result) => {
            try {
                object.screenshot_finish(result);
                stream.close(null);
                invocation.return_value(new GLib.Variant('()', []));
            } catch (error) { invocation.return_dbus_error('com.zommi.TestDriver.Error', `${error}`); }
        });
    }
    Click(x,y) {
        const now = GLib.get_monotonic_time();
        this.pointer.notify_absolute_motion(now,x,y);
        this.pointer.notify_button(now,1,Clutter.ButtonState.PRESSED);
        this.pointer.notify_button(now+1000,1,Clutter.ButtonState.RELEASED);
    }
    disable() {
        this.service.unexport(); Gio.bus_unown_name(this.owner);
        this.pointer = null; this.keyboard = null;
    }
}
