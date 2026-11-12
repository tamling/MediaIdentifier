#include "include/cmediafingtk.h"

typedef struct {
    mediafin_drop_callback callback;
    mediafin_drop_release release;
    void *user_data;
} DropTarget;

/// Freed through the closure's own notify rather than at some later point of
/// our choosing: the signal and the data behind it then go away together, and
/// a drop arriving during teardown cannot reach a freed pointer.
static void mediafin_free_drop_target(gpointer data, GClosure *closure) {
    (void)closure;
    DropTarget *target = (DropTarget *)data;
    if (target == NULL) {
        return;
    }
    if (target->release != NULL) {
        target->release(target->user_data);
    }
    g_free(target);
}

static void mediafin_on_drag_data_received(GtkWidget *widget,
                                           GdkDragContext *context,
                                           gint x, gint y,
                                           GtkSelectionData *data,
                                           guint info, guint time,
                                           gpointer user_data) {
    (void)widget;
    (void)x;
    (void)y;
    (void)info;

    DropTarget *target = (DropTarget *)user_data;
    gchar **uris = gtk_selection_data_get_uris(data);
    if (uris == NULL) {
        /* Nothing usable arrived. Said to be a failure, so the file manager
           draws the "did not take it" animation rather than implying that
           something is now happening. */
        gtk_drag_finish(context, FALSE, FALSE, time);
        return;
    }

    guint count = 0;
    while (uris[count] != NULL) {
        count++;
    }

    const char **paths = g_new0(const char *, count + 1);
    guint kept = 0;
    for (guint i = 0; i < count; i++) {
        /* g_filename_from_uri returns NULL for anything that is not a local
           file, which is exactly what should be skipped: there is no file on
           this machine to rename. */
        gchar *path = g_filename_from_uri(uris[i], NULL, NULL);
        if (path != NULL) {
            paths[kept] = path;
            kept++;
        }
    }
    paths[kept] = NULL;

    if (kept > 0 && target != NULL && target->callback != NULL) {
        target->callback(paths, target->user_data);
    }

    for (guint i = 0; i < kept; i++) {
        g_free((gchar *)paths[i]);
    }
    g_free(paths);
    g_strfreev(uris);
    gtk_drag_finish(context, kept > 0, FALSE, time);
}

void mediafin_accept_file_drops(GtkWidget *widget,
                               mediafin_drop_callback callback,
                               void *user_data,
                               mediafin_drop_release release) {
    if (widget == NULL) {
        return;
    }
    DropTarget *target = g_new0(DropTarget, 1);
    target->callback = callback;
    target->release = release;
    target->user_data = user_data;

    /* No target list of our own: add_uri_targets fills in whatever the
       installed GTK calls text/uri-list, which is one fewer thing to spell
       correctly. GTK_DEST_DEFAULT_ALL lets GTK do the highlighting and the
       data request, so the only thing left to write is what to do with the
       files. */
    gtk_drag_dest_set(widget, GTK_DEST_DEFAULT_ALL, NULL, 0, GDK_ACTION_COPY);
    gtk_drag_dest_add_uri_targets(widget);
    g_signal_connect_data(widget, "drag-data-received",
                          G_CALLBACK(mediafin_on_drag_data_received),
                          target, mediafin_free_drop_target, 0);
}
