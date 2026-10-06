/* Native GTK selection ownership lets Capture wait until the destination reads
 * the image before replacing it with its text. No display polling or key hooks. */
#include <gtk/gtk.h>
#include <string.h>
typedef struct {
  GBytes *bytes, *html;
  gint64 read_at;
} Payload;
static Payload *current;
static void clear(GtkClipboard *board, gpointer data) {
  (void)board;
  Payload *payload = data;
  /* A delayed clear for the previous selection must not erase its successor. */
  if (current == payload) current = NULL;
  g_clear_pointer(&payload->bytes, g_bytes_unref);
  g_clear_pointer(&payload->html, g_bytes_unref);
  g_free(payload);
}
static void provide(GtkClipboard *board, GtkSelectionData *selection, guint info, gpointer data) {
  (void)board;
  Payload *payload = data;
  GBytes *bytes = info == 2 ? payload->html : payload->bytes;
  if (!bytes) return;
  gsize size;
  const guchar *content = g_bytes_get_data(bytes, &size);
  if (info == 1) gtk_selection_data_set_text(selection, (const gchar *)content, (gint)size);
  else gtk_selection_data_set(selection, gtk_selection_data_get_target(selection), 8, content, (gint)size);
  payload->read_at = g_get_monotonic_time();
}
gboolean focalet_clipboard_set(const void *data, int size, gboolean image, const char *markup) {
  GtkClipboard *board = gtk_clipboard_get(GDK_SELECTION_CLIPBOARD);
  Payload *next = g_new0(Payload, 1);
  next->bytes = g_bytes_new(data, size);
  if (markup) next->html = g_bytes_new(markup, strlen(markup));
  GtkTargetList *list = gtk_target_list_new(NULL, 0);
  if (image) gtk_target_list_add(list, gdk_atom_intern_static_string("image/png"), 0, 0);
  else gtk_target_list_add_text_targets(list, 1);
  if (markup) gtk_target_list_add(list, gdk_atom_intern_static_string("text/html"), 0, 2);
  gint count;
  GtkTargetEntry *targets = gtk_target_table_new_from_list(list, &count);
  gboolean owned = gtk_clipboard_set_with_data(board, targets, count, provide, clear, next);
  gtk_target_table_free(targets, count); gtk_target_list_unref(list);
  if (owned) current = next;
  else clear(board, next);
  return owned;
}
gboolean focalet_clipboard_owned(void) { return current != NULL; }
gint64 focalet_clipboard_read_at(void) { return current ? current->read_at : 0; }
