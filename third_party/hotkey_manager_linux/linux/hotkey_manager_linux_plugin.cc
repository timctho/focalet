#include "include/hotkey_manager_linux/hotkey_manager_linux_plugin.h"

#include <X11/Xlib.h>
#include <gdk/gdkx.h>
#include <flutter_linux/flutter_linux.h>

#include <map>
#include <set>
#include <string>
#include <vector>

#define HOTKEY_MANAGER_LINUX_PLUGIN(obj)                                     \
  (G_TYPE_CHECK_INSTANCE_CAST((obj), hotkey_manager_linux_plugin_get_type(), \
                              HotkeyManagerLinuxPlugin))

struct Registration {
  int keycode;
  unsigned int modifiers;
};

struct _HotkeyManagerLinuxPlugin {
  GObject parent_instance;
  FlEventChannel* event_channel;
  std::map<std::string, Registration>* registrations;
  bool filter_installed;
};

G_DEFINE_TYPE(HotkeyManagerLinuxPlugin,
              hotkey_manager_linux_plugin,
              g_object_get_type())

namespace {

constexpr unsigned int kRelevantModifiers =
    ShiftMask | ControlMask | Mod1Mask | Mod4Mask | Mod5Mask;
bool grab_failed = false;

std::set<unsigned int> grab_variants(unsigned int modifiers) {
  return {
      modifiers,
      modifiers | LockMask,
      modifiers | Mod2Mask,
      modifiers | LockMask | Mod2Mask,
  };
}

unsigned int parse_modifiers(FlValue* values) {
  unsigned int result = 0;
  for (size_t index = 0; index < fl_value_get_length(values); ++index) {
    const std::string modifier =
        fl_value_get_string(fl_value_get_list_value(values, index));
    if (modifier == "alt") {
      result |= Mod1Mask;
    } else if (modifier == "control") {
      result |= ControlMask;
    } else if (modifier == "meta") {
      result |= Mod4Mask;
    } else if (modifier == "shift") {
      result |= ShiftMask;
    }
  }
  return result;
}

Display* x_display() {
  GdkDisplay* display = gdk_display_get_default();
  if (display == nullptr || !GDK_IS_X11_DISPLAY(display)) {
    return nullptr;
  }
  return gdk_x11_display_get_xdisplay(display);
}

int capture_x_error(Display*, XErrorEvent* error) {
  if (error->error_code == BadAccess) {
    grab_failed = true;
  }
  return 0;
}

bool grab_registration(const Registration& registration) {
  Display* display = x_display();
  if (display == nullptr || registration.keycode == 0) {
    return false;
  }
  const Window root = DefaultRootWindow(display);
  XSync(display, False);
  grab_failed = false;
  XErrorHandler previous = XSetErrorHandler(capture_x_error);
  for (const unsigned int modifiers : grab_variants(registration.modifiers)) {
    XGrabKey(display, registration.keycode, modifiers, root, False,
             GrabModeAsync, GrabModeAsync);
  }
  XSync(display, False);
  XSetErrorHandler(previous);
  if (!grab_failed) {
    return true;
  }
  for (const unsigned int modifiers : grab_variants(registration.modifiers)) {
    XUngrabKey(display, registration.keycode, modifiers, root);
  }
  XSync(display, False);
  return false;
}

void ungrab_registration(const Registration& registration) {
  Display* display = x_display();
  if (display == nullptr) {
    return;
  }
  const Window root = DefaultRootWindow(display);
  for (const unsigned int modifiers : grab_variants(registration.modifiers)) {
    XUngrabKey(display, registration.keycode, modifiers, root);
  }
  XSync(display, False);
}

void emit_key_down(HotkeyManagerLinuxPlugin* self,
                   const std::string& identifier) {
  g_autoptr(FlValue) data = fl_value_new_map();
  fl_value_set_string_take(data, "identifier",
                           fl_value_new_string(identifier.c_str()));
  g_autoptr(FlValue) event = fl_value_new_map();
  fl_value_set_string_take(event, "type", fl_value_new_string("onKeyDown"));
  fl_value_set_string_take(event, "data", fl_value_ref(data));
  fl_event_channel_send(self->event_channel, event, nullptr, nullptr);
}

GdkFilterReturn x_event_filter(GdkXEvent* event,
                               GdkEvent*,
                               gpointer user_data) {
  auto* self = HOTKEY_MANAGER_LINUX_PLUGIN(user_data);
  auto* xevent = static_cast<XEvent*>(event);
  if (xevent->type != KeyPress) {
    return GDK_FILTER_CONTINUE;
  }
  const unsigned int modifiers = xevent->xkey.state & kRelevantModifiers;
  for (const auto& entry : *self->registrations) {
    const std::string& identifier = entry.first;
    const Registration& registration = entry.second;
    if (registration.keycode == xevent->xkey.keycode &&
        registration.modifiers == modifiers) {
      emit_key_down(self, identifier);
      return GDK_FILTER_REMOVE;
    }
  }
  return GDK_FILTER_CONTINUE;
}

FlMethodResponse* register_hotkey(HotkeyManagerLinuxPlugin* self,
                                  FlValue* arguments) {
  Display* display = x_display();
  if (display == nullptr) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "unsupported-platform",
        "Global shortcuts require an X11 session; Wayland portal support is unavailable.",
        nullptr));
  }
  const char* identifier =
      fl_value_get_string(fl_value_lookup_string(arguments, "identifier"));
  const KeySym key = static_cast<KeySym>(
      fl_value_get_int(fl_value_lookup_string(arguments, "keyCode")));
  FlValue* modifier_values =
      fl_value_lookup_string(arguments, "modifiers");
  const Registration registration = {
      XKeysymToKeycode(display, key),
      parse_modifiers(modifier_values),
  };
  if (!grab_registration(registration)) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "registration-failed", "The X11 shortcut is already registered.",
        nullptr));
  }
  (*self->registrations)[identifier] = registration;
  return FL_METHOD_RESPONSE(
      fl_method_success_response_new(fl_value_new_bool(true)));
}

FlMethodResponse* unregister_hotkey(HotkeyManagerLinuxPlugin* self,
                                    FlValue* arguments) {
  const char* identifier =
      fl_value_get_string(fl_value_lookup_string(arguments, "identifier"));
  const auto registration = self->registrations->find(identifier);
  if (registration != self->registrations->end()) {
    ungrab_registration(registration->second);
    self->registrations->erase(registration);
  }
  return FL_METHOD_RESPONSE(
      fl_method_success_response_new(fl_value_new_bool(true)));
}

FlMethodResponse* unregister_all(HotkeyManagerLinuxPlugin* self) {
  for (const auto& entry : *self->registrations) {
    ungrab_registration(entry.second);
  }
  self->registrations->clear();
  return FL_METHOD_RESPONSE(
      fl_method_success_response_new(fl_value_new_bool(true)));
}

void method_call_cb(FlMethodChannel*,
                    FlMethodCall* method_call,
                    gpointer user_data) {
  auto* self = HOTKEY_MANAGER_LINUX_PLUGIN(user_data);
  const char* method = fl_method_call_get_name(method_call);
  FlValue* arguments = fl_method_call_get_args(method_call);
  g_autoptr(FlMethodResponse) response = nullptr;
  if (g_strcmp0(method, "register") == 0) {
    response = register_hotkey(self, arguments);
  } else if (g_strcmp0(method, "unregister") == 0) {
    response = unregister_hotkey(self, arguments);
  } else if (g_strcmp0(method, "unregisterAll") == 0) {
    response = unregister_all(self);
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }
  fl_method_call_respond(method_call, response, nullptr);
}

}  // namespace

static void hotkey_manager_linux_plugin_dispose(GObject* object) {
  auto* self = HOTKEY_MANAGER_LINUX_PLUGIN(object);
  if (self->registrations != nullptr) {
    g_autoptr(FlMethodResponse) response = unregister_all(self);
    (void)response;
    delete self->registrations;
    self->registrations = nullptr;
  }
  if (self->filter_installed) {
    gdk_window_remove_filter(nullptr, x_event_filter, self);
    self->filter_installed = false;
  }
  g_clear_object(&self->event_channel);
  G_OBJECT_CLASS(hotkey_manager_linux_plugin_parent_class)->dispose(object);
}

static void hotkey_manager_linux_plugin_class_init(
    HotkeyManagerLinuxPluginClass* klass) {
  G_OBJECT_CLASS(klass)->dispose = hotkey_manager_linux_plugin_dispose;
}

static void hotkey_manager_linux_plugin_init(HotkeyManagerLinuxPlugin* self) {
  self->event_channel = nullptr;
  self->registrations = new std::map<std::string, Registration>();
  self->filter_installed = false;
}

void hotkey_manager_linux_plugin_register_with_registrar(
    FlPluginRegistrar* registrar) {
  auto* plugin = HOTKEY_MANAGER_LINUX_PLUGIN(
      g_object_new(hotkey_manager_linux_plugin_get_type(), nullptr));
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  g_autoptr(FlMethodChannel) channel = fl_method_channel_new(
      fl_plugin_registrar_get_messenger(registrar),
      "dev.leanflutter.plugins/hotkey_manager", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(
      channel, method_call_cb, g_object_ref(plugin), g_object_unref);

  g_autoptr(FlStandardMethodCodec) event_codec =
      fl_standard_method_codec_new();
  plugin->event_channel = fl_event_channel_new(
      fl_plugin_registrar_get_messenger(registrar),
      "dev.leanflutter.plugins/hotkey_manager_event",
      FL_METHOD_CODEC(event_codec));
  gdk_window_add_filter(nullptr, x_event_filter, plugin);
  plugin->filter_installed = true;
  g_object_unref(plugin);
}
