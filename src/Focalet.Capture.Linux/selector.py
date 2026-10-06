"""Frozen multi-display region selection with annotations in native GTK."""
import base64
import math
import gi
gi.require_version('Gtk', '3.0')
from gi.repository import Gtk, Gdk, GdkPixbuf, GLib
from capture_context import png_bytes, source_at


def pixbuf(data):
    loader = GdkPixbuf.PixbufLoader.new_with_type('png')
    loader.write(data); loader.close()
    return loader.get_pixbuf()


def png(image):
    success, data = image.save_to_bufferv('png', [], [])
    if not success:
        raise ValueError('Could not encode the selected image.')
    return bytes(data)


def pixels(image):
    image = image.add_alpha(False, 0, 0, 0)
    data = image.get_pixels()
    stride, row = image.get_rowstride(), image.get_width() * image.get_n_channels()
    return (image.get_width(), image.get_height(), image.get_n_channels(),
            b''.join(data[y*stride:y*stride+row] for y in range(image.get_height())))


def paint_stroke(cr, stroke):
    points, tool, color = stroke['points'], stroke['tool'], stroke['color']
    if not points:
        return
    x, y = points[0]; endx, endy = points[-1]
    cr.set_source_rgb(*color); cr.set_line_width(3); cr.set_line_cap(1); cr.set_line_join(1)
    if tool == 'Box':
        cr.rectangle(min(x, endx), min(y, endy), abs(endx-x), abs(endy-y))
    elif tool == 'Ellipse':
        cr.save(); cr.translate((x+endx)/2, (y+endy)/2)
        cr.scale(max(.1, abs(endx-x)/2), max(.1, abs(endy-y)/2))
        cr.arc(0, 0, 1, 0, 2*math.pi); cr.restore()
    else:
        cr.move_to(x, y)
        if tool == 'Pen':
            for point in points[1:]:
                cr.line_to(*point)
        else:
            cr.line_to(endx, endy)
            angle = math.atan2(endy-y, endx-x)
            for offset in (-math.pi/6, math.pi/6):
                cr.move_to(endx, endy); cr.line_to(endx-14*math.cos(angle+offset), endy-14*math.sin(angle+offset))
    cr.stroke()


class Selector:
    def __init__(self, application, frames, complete):
        self.complete = complete
        self.regions, self.windows, self.areas = [], [], []
        self.tool, self.color, self.drag = 'Select', (1, .15, .15), None
        self.frames = [(f, pixbuf(png_bytes(f['dataUrl']))) for f in frames]
        self.application = application
        for index, (frame, image) in enumerate(self.frames):
            window = Gtk.ApplicationWindow(application=application, title='Focalet Capture selection')
            window.set_decorated(False)
            window.set_icon_from_file(str(application.root / 'app-icon.png'))
            overlay = Gtk.Overlay(); area = Gtk.DrawingArea()
            overlay.add(area); window.add(overlay)
            toolbar = Gtk.Box(spacing=6, margin=16, halign=Gtk.Align.CENTER, valign=Gtk.Align.START)
            toolbar.get_style_context().add_class('toolbar')
            label = Gtk.Label(label='Drag regions · Control adds · Enter finishes'); toolbar.pack_start(label, False, False, 4)
            for name in ('Select', 'Pen', 'Arrow', 'Box', 'Ellipse'):
                button = Gtk.Button(label=name); button.connect('clicked', lambda _, n=name: self.set_tool(n)); toolbar.pack_start(button, False, False, 0)
            color = Gtk.ColorButton(); color.set_rgba(Gdk.RGBA(1, .15, .15, 1))
            color.connect('color-set', lambda b: self.set_color(b.get_rgba())); toolbar.pack_start(color, False, False, 0)
            for title, action in (('Undo', self.undo), ('Cancel', self.cancel), ('Done', self.finish)):
                button = Gtk.Button(label=title); button.connect('clicked', lambda _, a=action: a()); toolbar.pack_start(button, False, False, 0)
            overlay.add_overlay(toolbar)
            area.add_events(Gdk.EventMask.BUTTON_PRESS_MASK | Gdk.EventMask.BUTTON_RELEASE_MASK | Gdk.EventMask.POINTER_MOTION_MASK)
            area.connect('draw', self.draw, index)
            area.connect('button-press-event', self.press, index)
            area.connect('motion-notify-event', self.motion, index)
            area.connect('button-release-event', self.release, index)
            window.connect('key-press-event', self.key)
            window.connect('delete-event', lambda *_: self.cancel() or True)
            self.windows.append(window); self.areas.append(area)
            screen = window.get_screen()
            bounds = frame['bounds']
            monitor = screen.get_monitor_at_point(int(bounds['x']+bounds['width']/2), int(bounds['y']+bounds['height']/2))
            window.fullscreen_on_monitor(screen, monitor); window.show_all(); window.present()
        self.display = Gdk.Display.get_default()
        self.monitor_handler = self.display.connect('monitor-removed', lambda *_: self.cancel())

    def set_tool(self, tool):
        self.tool = tool

    def set_color(self, color):
        self.color = (color.red, color.green, color.blue)

    def refresh(self):
        for area in self.areas:
            area.queue_draw()

    def key(self, window, event):
        if event.keyval in (Gdk.KEY_Control_L, Gdk.KEY_Control_R): self.tool = 'Select'
        elif event.keyval == Gdk.KEY_Escape: self.cancel()
        elif event.keyval in (Gdk.KEY_Return, Gdk.KEY_KP_Enter): self.finish()
        elif event.keyval in (Gdk.KEY_BackSpace, Gdk.KEY_Delete): self.undo()
        return True

    def local_point(self, event, index):
        bounds = self.frames[index][0]['bounds']
        return (min(bounds['width'], max(0, event.x)), min(bounds['height'], max(0, event.y)))

    def press(self, area, event, index):
        if event.button == 3: self.cancel(); return True
        if event.button != 1: return False
        if event.state & Gdk.ModifierType.CONTROL_MASK: self.tool = 'Select'
        point = self.local_point(event, index)
        if self.tool == 'Select': self.drag = (index, point, point, None)
        else:
            for region in reversed(self.regions):
                x, y, w, h = region['rect']
                if region['display'] == index and x <= point[0] <= x+w and y <= point[1] <= y+h and len(region['strokes']) < 200:
                    stroke = {'tool': self.tool, 'color': self.color, 'points': [point]}
                    region['strokes'].append(stroke); self.drag = (index, point, point, stroke); break
        return True

    def motion(self, area, event, index):
        if self.drag is None or self.drag[0] != index: return False
        _, start, _, stroke = self.drag
        end = self.local_point(event, index)
        if stroke is not None and len(stroke['points']) < 4000: stroke['points'].append(end)
        self.drag = (index, start, end, stroke); self.refresh(); return True

    def release(self, area, event, index):
        if event.button != 1 or self.drag is None or self.drag[0] != index: return False
        self.motion(area, event, index)
        _, (x, y), (endx, endy), stroke = self.drag
        self.drag = None
        rect = (min(x, endx), min(y, endy), abs(endx-x), abs(endy-y))
        if stroke is None and len(self.regions) < 8 and min(rect[2:]) >= 4:
            if not any(r['display'] == index and r['rect'] == rect for r in self.regions):
                self.regions.append({'display': index, 'rect': rect, 'strokes': []})
        self.refresh(); return True

    def undo(self):
        if self.drag or not self.regions: return
        if self.regions[-1]['strokes']: self.regions[-1]['strokes'].pop()
        else: self.regions.pop()
        self.refresh()

    def draw(self, area, cr, index):
        frame, image = self.frames[index]; b = frame['bounds']
        cr.save(); cr.scale(b['width']/image.get_width(), b['height']/image.get_height())
        Gdk.cairo_set_source_pixbuf(cr, image, 0, 0); cr.paint(); cr.restore()
        cr.set_source_rgba(0, 0, 0, .3); cr.paint()
        for number, region in enumerate(self.regions):
            if region['display'] != index: continue
            rect = region['rect']; cr.save(); cr.rectangle(*rect); cr.clip()
            cr.save(); cr.scale(b['width']/image.get_width(), b['height']/image.get_height())
            Gdk.cairo_set_source_pixbuf(cr, image, 0, 0); cr.paint(); cr.restore()
            for stroke in region['strokes']: paint_stroke(cr, stroke)
            cr.restore(); cr.set_source_rgb(.1, .8, 1); cr.set_line_width(2); cr.rectangle(*rect); cr.stroke()
            cr.move_to(rect[0]+4, rect[1]+18); cr.set_font_size(16); cr.show_text(chr(65+number))
        if self.drag and self.drag[0] == index and self.drag[3] is None:
            _, (x, y), (endx, endy), _ = self.drag
            cr.set_source_rgb(1, 1, 1); cr.set_line_width(2); cr.rectangle(min(x, endx), min(y, endy), abs(endx-x), abs(endy-y)); cr.stroke()
        return False

    def close(self):
        if self.monitor_handler:
            self.display.disconnect(self.monitor_handler); self.monitor_handler = 0
        for window in self.windows: window.destroy()
        self.windows.clear()

    def cancel(self):
        self.close(); self.complete([]); self.frames.clear()

    def finish(self):
        if self.drag or not self.regions: return
        import cairo
        selected = []
        for region in self.regions:
            frame, image = self.frames[region['display']]; b = frame['bounds']; x, y, w, h = region['rect']
            sx, sy = image.get_width()/b['width'], image.get_height()/b['height']
            px, py = math.floor(x*sx), math.floor(y*sy)
            pw, ph = min(image.get_width(), math.ceil((x+w)*sx))-px, min(image.get_height(), math.ceil((y+h)*sy))-py
            crop = image.new_subpixbuf(px, py, pw, ph)
            surface = cairo.ImageSurface(cairo.FORMAT_ARGB32, pw, ph); cr = cairo.Context(surface)
            Gdk.cairo_set_source_pixbuf(cr, crop, 0, 0); cr.paint()
            cr.scale(sx, sy); cr.translate(-px/sx, -py/sy)
            for stroke in region['strokes']: paint_stroke(cr, stroke)
            rendered = Gdk.pixbuf_get_from_surface(surface, 0, 0, pw, ph)
            bounds = {'x': b['x']+px/sx, 'y': b['y']+py/sy, 'width': pw/sx, 'height': ph/sy}
            selected.append({'png': png(rendered), 'original': crop.copy(), 'width': pw, 'height': ph,
                             'bounds': bounds, 'source': source_at(frame.get('windows', []), bounds),
                             'annotations': [{'tool': s['tool'].lower(), 'coordinateSpace': 'image-pixels',
                                              'points': [{'x': p[0]*sx-px, 'y': p[1]*sy-py} for p in s['points']]} for s in region['strokes']]})
        self.close(); self.complete(selected); self.frames.clear()
