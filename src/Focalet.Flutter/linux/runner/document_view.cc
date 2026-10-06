#include "document_view.h"

#include <webkit2/webkit2.h>
#include <cmath>
#include <cstdint>
#include <memory>
#include <string>
#include <unordered_map>
#include <vector>

namespace {
struct Documents;
struct Page : std::enable_shared_from_this<Page> {
  Documents* owner;
  int64_t id;
  GtkWidget* view = nullptr;
  GtkWidget* offscreen = nullptr;
  FlMethodCall* pending = nullptr;
  GCancellable* cancel = g_cancellable_new();
  guint timeout = 0;
  bool ready = false;
  bool closed = false;
  GdkRectangle bounds = {0, 0, 1, 1};
  std::string prefix;
  Page(Documents* manager, int64_t number) : owner(manager), id(number) {}
  ~Page();
  void Close();
  void Event(const char* event, const char* message = nullptr);
  void Finish(FlValue* bytes, const char* error = nullptr);
  void Snapshot();
};
using PagePtr = std::shared_ptr<Page>;
struct Documents {
  GtkWidget* overlay;
  FlMethodChannel* channel;
  WebKitWebContext* context;
  FlView* flutter_view;
  bool suspended = false;
  std::unordered_map<int64_t, PagePtr> pages;
  int64_t next_thumbnail = 0;
  ~Documents() {
    fl_method_channel_set_method_call_handler(channel, nullptr, nullptr, nullptr);
    for (auto& entry : pages) { entry.second->Close(); entry.second->owner = nullptr; }
    pages.clear();
    g_object_unref(context);
    g_object_unref(channel);
  }
};

FlValue* Field(FlValue* args, const char* key) {
  return args && fl_value_get_type(args) == FL_VALUE_TYPE_MAP ? fl_value_lookup_string(args, key) : nullptr;
}
double Number(FlValue* args, const char* key) {
  FlValue* value = Field(args, key);
  if (!value) return 0;
  if (fl_value_get_type(value) == FL_VALUE_TYPE_INT) return fl_value_get_int(value);
  return fl_value_get_type(value) == FL_VALUE_TYPE_FLOAT ? fl_value_get_float(value) : 0;
}
const char* Text(FlValue* args, const char* key) {
  FlValue* value = Field(args, key);
  return value && fl_value_get_type(value) == FL_VALUE_TYPE_STRING ? fl_value_get_string(value) : "";
}
void Respond(FlMethodCall* call, FlValue* value = nullptr, const char* error = nullptr) {
  if (error) fl_method_call_respond_error(call, "document-unavailable", error, nullptr, nullptr);
  else fl_method_call_respond_success(call, value, nullptr);
}
void Page::Event(const char* event, const char* message) {
  if (!owner || closed) return;
  g_autoptr(FlValue) args = fl_value_new_map();
  fl_value_set_string_take(args, "id", fl_value_new_int(id));
  fl_value_set_string_take(args, "event", fl_value_new_string(event));
  if (message) fl_value_set_string_take(args, "message", fl_value_new_string(message));
  fl_method_channel_invoke_method(owner->channel, "event", args, nullptr, nullptr, nullptr);
}
void Page::Close() {
  if (closed) return;
  closed = true;
  if (timeout) { g_source_remove(timeout); timeout = 0; }
  g_cancellable_cancel(cancel);
  if (pending) { Respond(pending, nullptr, "Document preview was closed."); g_clear_object(&pending); }
  if (view) {
    g_signal_handlers_disconnect_by_data(view, this);
    gtk_widget_destroy(view);
    g_clear_object(&view);
  }
  if (offscreen) { gtk_widget_destroy(offscreen); g_clear_object(&offscreen); }
}
Page::~Page() { Close(); g_object_unref(cancel); }
void Page::Finish(FlValue* bytes, const char* error) {
  if (closed) return;
  if (pending) {
    Respond(pending, bytes, error);
    g_clear_object(&pending);
    // Do not destroy a GTK widget from within its own load signal emission.
    auto* keep = new PagePtr(shared_from_this());
    g_idle_add_full(G_PRIORITY_DEFAULT_IDLE, [](gpointer data) -> gboolean {
      auto page = *static_cast<PagePtr*>(data);
      page->Close();
      if (page->owner) page->owner->pages.erase(page->id);
      return G_SOURCE_REMOVE;
    }, keep, [](gpointer data) { delete static_cast<PagePtr*>(data); });
  } else if (error) Event("error", error);
}
void Page::Snapshot() {
  if (closed || !view) return;
  auto* keep = new PagePtr(shared_from_this());
  webkit_web_view_get_snapshot(WEBKIT_WEB_VIEW(view), WEBKIT_SNAPSHOT_REGION_VISIBLE,
    WEBKIT_SNAPSHOT_OPTIONS_NONE, cancel, [](GObject* object, GAsyncResult* result, gpointer data) {
      std::unique_ptr<PagePtr> held(static_cast<PagePtr*>(data));
      auto page = *held;
      g_autoptr(GError) error = nullptr;
      cairo_surface_t* surface = webkit_web_view_get_snapshot_finish(WEBKIT_WEB_VIEW(object), result, &error);
      if (page->closed) { if (surface) cairo_surface_destroy(surface); return; }
      if (!surface) { page->Finish(nullptr, error ? error->message : "Could not render the document."); return; }
      std::vector<uint8_t> bytes;
      auto status = cairo_surface_write_to_png_stream(surface, [](void* target, const unsigned char* chunk, unsigned int length) {
        auto* output = static_cast<std::vector<uint8_t>*>(target);
        output->insert(output->end(), chunk, chunk + length);
        return CAIRO_STATUS_SUCCESS;
      }, &bytes);
      cairo_surface_destroy(surface);
      if (status != CAIRO_STATUS_SUCCESS || bytes.empty()) { page->Finish(nullptr, "Could not encode the preview."); return; }
      g_autoptr(FlValue) value = fl_value_new_uint8_list(bytes.data(), bytes.size());
      page->Finish(value);
    }, keep);
}
std::string OriginPrefix(const char* uri) {
  g_autoptr(GUri) parsed = g_uri_parse(uri, G_URI_FLAGS_NONE, nullptr);
  if (!parsed || g_strcmp0(g_uri_get_scheme(parsed), "http") != 0 ||
      g_strcmp0(g_uri_get_host(parsed), "127.0.0.1") != 0 || g_uri_get_port(parsed) <= 0) return {};
  std::string path = g_uri_get_path(parsed) ? g_uri_get_path(parsed) : "";
  auto slash = path.find('/', 1);
  if (slash == std::string::npos || slash <= 1) return {};
  return "http://127.0.0.1:" + std::to_string(g_uri_get_port(parsed)) + path.substr(0, slash + 1);
}
void SetBounds(Page* page, FlValue* args) {
  const double x = Number(args, "x"), y = Number(args, "y");
  const double width = Number(args, "width"), height = Number(args, "height");
  if (!std::isfinite(x) || !std::isfinite(y) || !std::isfinite(width) || !std::isfinite(height) ||
      width < 1 || height < 1 || width > 16384 || height > 16384) return;
  page->bounds = {std::max(0, static_cast<int>(std::round(x))),
                  std::max(0, static_cast<int>(std::round(y))),
                  static_cast<int>(std::round(width)), static_cast<int>(std::round(height))};
  gtk_widget_queue_resize(page->view);
}
PagePtr Open(Documents* owner, int64_t id, FlValue* args, FlMethodCall* thumbnail) {
  auto page = std::make_shared<Page>(owner, id);
  const char* uri = Text(args, "uri");
  page->prefix = OriginPrefix(uri);
  if (page->prefix.empty()) return nullptr;
  owner->pages[id] = page;
  page->view = GTK_WIDGET(g_object_ref_sink(webkit_web_view_new_with_context(owner->context)));
  auto* web = WEBKIT_WEB_VIEW(page->view);
  auto* settings = webkit_web_view_get_settings(web);
  webkit_settings_set_enable_javascript(settings, TRUE);
  webkit_settings_set_allow_file_access_from_file_urls(settings, FALSE);
  webkit_settings_set_allow_universal_access_from_file_urls(settings, FALSE);
  webkit_settings_set_javascript_can_open_windows_automatically(settings, FALSE);
  webkit_settings_set_enable_developer_extras(settings, FALSE);
  if (thumbnail) {
    page->pending = FL_METHOD_CALL(g_object_ref(thumbnail));
    // GTK's offscreen widget supplies pixels without a visible native window.
    webkit_settings_set_hardware_acceleration_policy(settings, WEBKIT_HARDWARE_ACCELERATION_POLICY_NEVER);
    page->offscreen = GTK_WIDGET(g_object_ref_sink(gtk_offscreen_window_new()));
    gtk_widget_set_size_request(page->view, 1280, 720);
    gtk_container_add(GTK_CONTAINER(page->offscreen), page->view);
    gtk_widget_show_all(page->offscreen);
  } else {
    gtk_widget_set_halign(page->view, GTK_ALIGN_FILL);
    gtk_widget_set_valign(page->view, GTK_ALIGN_FILL);
    SetBounds(page.get(), args);
    gtk_overlay_add_overlay(GTK_OVERLAY(owner->overlay), page->view);
    if (!owner->suspended) gtk_widget_show(page->view);
  }
  g_signal_connect(web, "decide-policy", G_CALLBACK(+[](WebKitWebView*, WebKitPolicyDecision* decision, WebKitPolicyDecisionType type, gpointer data) -> gboolean {
    auto* page = static_cast<Page*>(data);
    if (type == WEBKIT_POLICY_DECISION_TYPE_NEW_WINDOW_ACTION) { webkit_policy_decision_ignore(decision); return TRUE; }
    if (type == WEBKIT_POLICY_DECISION_TYPE_NAVIGATION_ACTION) {
      auto* action = webkit_navigation_policy_decision_get_navigation_action(WEBKIT_NAVIGATION_POLICY_DECISION(decision));
      const char* target = webkit_uri_request_get_uri(webkit_navigation_action_get_request(action));
      if (!target || std::string(target).rfind(page->prefix, 0) != 0) { webkit_policy_decision_ignore(decision); return TRUE; }
    }
    return FALSE;
  }), page.get());
  g_signal_connect(web, "create", G_CALLBACK(+[](WebKitWebView*, WebKitNavigationAction*, gpointer) -> GtkWidget* { return nullptr; }), page.get());
  g_signal_connect(web, "permission-request", G_CALLBACK(+[](WebKitWebView*, WebKitPermissionRequest* request, gpointer) -> gboolean {
    webkit_permission_request_deny(request); return TRUE;
  }), page.get());
  g_signal_connect(web, "context-menu", G_CALLBACK(+[](WebKitWebView*, WebKitContextMenu*, GdkEvent*, WebKitHitTestResult*, gpointer) -> gboolean { return TRUE; }), page.get());
  g_signal_connect(web, "key-press-event", G_CALLBACK(+[](GtkWidget*, GdkEventKey* event, gpointer data) -> gboolean {
    if (event->keyval != GDK_KEY_Escape) return FALSE;
    static_cast<Page*>(data)->Event("dismiss"); return TRUE;
  }), page.get());
  g_signal_connect(web, "load-failed", G_CALLBACK(+[](WebKitWebView*, WebKitLoadEvent, const gchar*, GError* error, gpointer data) -> gboolean {
    static_cast<Page*>(data)->Finish(nullptr, error->message); return TRUE;
  }), page.get());
  g_signal_connect(web, "web-process-terminated", G_CALLBACK(+[](WebKitWebView*, WebKitWebProcessTerminationReason, gpointer data) {
    static_cast<Page*>(data)->Finish(nullptr, "Document renderer stopped. Retry to recover.");
  }), page.get());
  g_signal_connect(web, "load-changed", G_CALLBACK(+[](WebKitWebView* view, WebKitLoadEvent event, gpointer data) {
    auto* page = static_cast<Page*>(data);
    if (event != WEBKIT_LOAD_FINISHED || page->closed || page->ready) return;
    page->ready = true;
    if (!page->pending) { if (page->timeout) { g_source_remove(page->timeout); page->timeout = 0; } page->Event("ready"); return; }
    auto* keep = new PagePtr(page->shared_from_this());
    webkit_web_view_call_async_javascript_function(view, "await document.fonts.ready; return true;", -1, nullptr, nullptr, nullptr,
      page->cancel, [](GObject* object, GAsyncResult* result, gpointer data) {
        std::unique_ptr<PagePtr> held(static_cast<PagePtr*>(data));
        auto page = *held;
        g_autoptr(GError) error = nullptr;
        g_autoptr(JSCValue) value = webkit_web_view_call_async_javascript_function_finish(WEBKIT_WEB_VIEW(object), result, &error);
        if (page->closed) return;
        if (error) { page->Finish(nullptr, error->message); return; }
        auto* keep = new PagePtr(page);
        g_timeout_add_full(G_PRIORITY_DEFAULT, 150, [](gpointer data) -> gboolean {
          (*static_cast<PagePtr*>(data))->Snapshot(); return G_SOURCE_REMOVE;
        }, keep, [](gpointer data) { delete static_cast<PagePtr*>(data); });
      }, keep);
  }), page.get());
  page->timeout = g_timeout_add_seconds(15, [](gpointer data) -> gboolean {
    auto* page = static_cast<Page*>(data); page->timeout = 0;
    page->Finish(nullptr, "Document loading timed out. Retry to recover."); return G_SOURCE_REMOVE;
  }, page.get());
  webkit_web_view_load_uri(web, uri);
  return page;
}
void Handle(FlMethodChannel*, FlMethodCall* call, gpointer data) {
  auto* owner = static_cast<Documents*>(data);
  const char* method = fl_method_call_get_name(call);
  auto* args = fl_method_call_get_args(call);
  const int64_t id = static_cast<int64_t>(Number(args, "id"));
  auto found = owner->pages.find(id);
  if (g_str_equal(method, "suspend")) {
    FlValue* value = Field(args, "value");
    owner->suspended = value && fl_value_get_type(value) == FL_VALUE_TYPE_BOOL && fl_value_get_bool(value);
    for (auto& entry : owner->pages) {
      if (entry.second->offscreen || entry.second->closed) continue;
      if (owner->suspended) gtk_widget_hide(entry.second->view);
      else gtk_widget_show(entry.second->view);
    }
    if (owner->suspended) gtk_widget_grab_focus(GTK_WIDGET(owner->flutter_view));
    Respond(call);
  } else if (g_str_equal(method, "evaluate") && found != owner->pages.end()) {
    struct Evaluation {
      PagePtr page;
      FlMethodCall* call;
      ~Evaluation() { g_object_unref(call); }
    };
    auto* evaluation = new Evaluation{found->second, FL_METHOD_CALL(g_object_ref(call))};
    webkit_web_view_evaluate_javascript(WEBKIT_WEB_VIEW(found->second->view), Text(args, "source"), -1, nullptr, nullptr,
      found->second->cancel, [](GObject* object, GAsyncResult* result, gpointer data) {
        std::unique_ptr<Evaluation> evaluation(static_cast<Evaluation*>(data));
        g_autoptr(GError) error = nullptr;
        g_autoptr(JSCValue) value = webkit_web_view_evaluate_javascript_finish(WEBKIT_WEB_VIEW(object), result, &error);
        if (error) { Respond(evaluation->call, nullptr, error->message); return; }
        g_autofree char* json = value ? jsc_value_to_json(value, 0) : nullptr;
        g_autoptr(FlValue) encoded = json ? fl_value_new_string(json) : fl_value_new_null();
        Respond(evaluation->call, encoded);
      }, evaluation);
  } else if (g_str_equal(method, "thumbnail")) {
    if (!Open(owner, --owner->next_thumbnail, args, call)) Respond(call, nullptr, "The document origin is not allowed.");
  } else if (g_str_equal(method, "open")) {
    if (found != owner->pages.end()) { found->second->Close(); owner->pages.erase(found); }
    if (!Open(owner, id, args, nullptr)) Respond(call, nullptr, "The document origin is not allowed.");
    else Respond(call);
  } else if (g_str_equal(method, "bounds")) {
    if (found != owner->pages.end()) SetBounds(found->second.get(), args);
    Respond(call);
  } else if (g_str_equal(method, "close")) {
    if (found != owner->pages.end()) { found->second->Close(); owner->pages.erase(found); }
    Respond(call);
  } else {
    fl_method_call_respond_not_implemented(call, nullptr);
  }
}
}  // namespace

GtkWidget* focalet_document_container_new(FlView* view) {
  GtkWidget* overlay = gtk_overlay_new();
  gtk_container_add(GTK_CONTAINER(overlay), GTK_WIDGET(view));
  auto* documents = new Documents();
  documents->overlay = overlay;
  documents->flutter_view = view;
  // WebKit can retain a larger natural size after the app was maximized.
  // Allocate exactly the Flutter panel rectangle instead of treating it as
  // only a minimum request that GTK is free to expand.
  g_signal_connect(overlay, "get-child-position", G_CALLBACK(+[](GtkOverlay*, GtkWidget* child, GdkRectangle* bounds, gpointer data) -> gboolean {
    auto* owner = static_cast<Documents*>(data);
    for (const auto& entry : owner->pages) {
      if (entry.second->view == child && !entry.second->offscreen) {
        *bounds = entry.second->bounds;
        return TRUE;
      }
    }
    return FALSE;
  }), documents);
  documents->context = webkit_web_context_new_ephemeral();
  g_signal_connect(documents->context, "download-started", G_CALLBACK(+[](WebKitWebContext*, WebKitDownload* download, gpointer) { webkit_download_cancel(download); }), nullptr);
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  documents->channel = fl_method_channel_new(fl_engine_get_binary_messenger(fl_view_get_engine(view)), "focalet/linux_document", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(documents->channel, Handle, documents, nullptr);
  g_object_set_data_full(G_OBJECT(overlay), "focalet-documents", documents, [](gpointer data) { delete static_cast<Documents*>(data); });
  gtk_widget_show(overlay);
  return overlay;
}
