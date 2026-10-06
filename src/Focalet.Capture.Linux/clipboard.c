/* GNOME owns the selection while the user's destination keeps keyboard focus.
 * Each source retains its bytes for outstanding asynchronous clipboard reads. */
#include "clipboard.h"
struct _FocaletClipboardSource {
  MetaSelectionSource parent_instance;
  GHashTable *formats;
  gint64 read_at;
};
G_DEFINE_TYPE(FocaletClipboardSource, focalet_clipboard_source, META_TYPE_SELECTION_SOURCE)
static GList *mimetypes(MetaSelectionSource *source) {
  FocaletClipboardSource *self = FOCALET_CLIPBOARD_SOURCE(source);
  GList *result = NULL;
  GHashTableIter iterator;
  gpointer key;
  g_hash_table_iter_init(&iterator, self->formats);
  while (g_hash_table_iter_next(&iterator, &key, NULL)) result = g_list_prepend(result, g_strdup(key));
  return result;
}
static void read_async(MetaSelectionSource *source, const gchar *mime, GCancellable *cancel,
                       GAsyncReadyCallback callback, gpointer data) {
  FocaletClipboardSource *self = FOCALET_CLIPBOARD_SOURCE(source);
  GTask *task = g_task_new(source, cancel, callback, data);
  GBytes *bytes = g_hash_table_lookup(self->formats, mime);
  if (bytes) {
    self->read_at = g_get_monotonic_time();
    g_task_return_pointer(task, g_memory_input_stream_new_from_bytes(bytes), g_object_unref);
  } else {
    g_task_return_new_error(task, G_IO_ERROR, G_IO_ERROR_NOT_SUPPORTED, "Clipboard format is unavailable");
  }
  g_object_unref(task);
}
static GInputStream *read_finish(MetaSelectionSource *source, GAsyncResult *result, GError **error) {
  g_return_val_if_fail(g_task_is_valid(result, source), NULL);
  return g_task_propagate_pointer(G_TASK(result), error);
}
static void finalize(GObject *object) {
  g_hash_table_unref(FOCALET_CLIPBOARD_SOURCE(object)->formats);
  G_OBJECT_CLASS(focalet_clipboard_source_parent_class)->finalize(object);
}
static void focalet_clipboard_source_class_init(FocaletClipboardSourceClass *klass) {
  MetaSelectionSourceClass *source = META_SELECTION_SOURCE_CLASS(klass);
  source->get_mimetypes = mimetypes; source->read_async = read_async; source->read_finish = read_finish;
  G_OBJECT_CLASS(klass)->finalize = finalize;
}
static void focalet_clipboard_source_init(FocaletClipboardSource *self) {
  self->formats = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, (GDestroyNotify)g_bytes_unref);
}
FocaletClipboardSource *focalet_clipboard_source_new(void) {
  return g_object_new(FOCALET_CLIPBOARD_TYPE_SOURCE, NULL);
}
void focalet_clipboard_source_add(FocaletClipboardSource *self, const gchar *mime, GBytes *bytes) {
  g_return_if_fail(!meta_selection_source_is_active(META_SELECTION_SOURCE(self)));
  g_hash_table_replace(self->formats, g_strdup(mime), g_bytes_ref(bytes));
}
gint64 focalet_clipboard_source_get_read_at(FocaletClipboardSource *self) { return self->read_at; }
