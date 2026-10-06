/* Native GTK selection ownership lets Capture wait until the destination reads
 * the image before replacing it with its text. No display polling or key hooks. */
#include <gtk/gtk.h>
#include <string.h>
static GBytes *payload, *html;
static gboolean owned;
static gint64 read_at;
static void clear(GtkClipboard *board, gpointer unused) {
  (void)board; (void)unused;
  owned = FALSE;
  g_clear_pointer(&payload, g_bytes_unref);
  g_clear_pointer(&html, g_bytes_unref);
}
static void provide(GtkClipboard *board, GtkSelectionData *selection, guint info, gpointer unused) {
  (void)board; (void)unused;
  GBytes *bytes = info == 2 ? html : payload;
  if (!bytes) return;
  gsize size;
  const guchar *data = g_bytes_get_data(bytes, &size);
  if (info == 1) gtk_selection_data_set_text(selection, (const gchar *)data, (gint)size);
  else gtk_selection_data_set(selection, gtk_selection_data_get_target(selection), 8, data, (gint)size);
  read_at = g_get_monotonic_time();
}
gboolean focalet_clipboard_set(const void *data, int size, gboolean image, const char *markup) {
  GtkClipboard *board = gtk_clipboard_get(GDK_SELECTION_CLIPBOARD);
  gtk_clipboard_clear(board);
  clear(board, NULL);
  payload = g_bytes_new(data, size);
  if (markup) html = g_bytes_new(markup, strlen(markup));
  GtkTargetList *list = gtk_target_list_new(NULL, 0);
  if (image) gtk_target_list_add(list, gdk_atom_intern_static_string("image/png"), 0, 0);
  else gtk_target_list_add_text_targets(list, 1);
  if (markup) gtk_target_list_add(list, gdk_atom_intern_static_string("text/html"), 0, 2);
  gint count;
  GtkTargetEntry *targets = gtk_target_table_new_from_list(list, &count);
  read_at = 0;
  owned = gtk_clipboard_set_with_data(board, targets, count, provide, clear, NULL);
  gtk_target_table_free(targets, count); gtk_target_list_unref(list);
  return owned;
}
gboolean focalet_clipboard_owned(void) { return owned; }
gint64 focalet_clipboard_read_at(void) { return read_at; }
