#pragma once
#include <gio/gio.h>
#include <meta/meta-selection-source.h>
G_BEGIN_DECLS
#define FOCALET_CLIPBOARD_TYPE_SOURCE (focalet_clipboard_source_get_type())
G_DECLARE_FINAL_TYPE(FocaletClipboardSource, focalet_clipboard_source, FOCALET_CLIPBOARD, SOURCE, MetaSelectionSource)
/**
 * focalet_clipboard_source_new:
 * Returns: (transfer full): an immutable selection source once published
 */
FocaletClipboardSource *focalet_clipboard_source_new(void);
void focalet_clipboard_source_add(FocaletClipboardSource *self, const gchar *mimetype, GBytes *bytes);
gint64 focalet_clipboard_source_get_read_at(FocaletClipboardSource *self);
G_END_DECLS
