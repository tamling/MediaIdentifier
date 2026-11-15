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

/* Does NOT call gtk_drag_finish. GTK_DEST_DEFAULT_DROP, which is part of the
   GTK_DEST_DEFAULT_ALL set below, calls it itself once this returns -- the
   documentation is explicit: "Whether or not the drop is successful, GTK+ will
   call gtk_drag_finish()". Calling it here as well finished the same context
   twice, whose state is torn down by the first call. That is the classic
   mistake at this spot, and I made it: the first version of this file did,
   and dropping a file took the window down with it. */
static void mediafin_on_drag_data_received(GtkWidget *widget,
                                           GdkDragContext *context,
                                           gint x, gint y,
                                           GtkSelectionData *data,
                                           guint info, guint time,
                                           gpointer user_data) {
    (void)widget;
    (void)context;
    (void)x;
    (void)y;
    (void)info;
    (void)time;

    /* Traced, on stderr, in stages. A drop is rare, three lines cost
       nothing, and a drop that takes the window down with it leaves the last
       line printed saying how far it got -- which is the difference between
       a cause and a theory. Two releases were spent guessing at this. */
    g_printerr("mediafin: drop: received\n");

    DropTarget *target = (DropTarget *)user_data;
    gchar **uris = gtk_selection_data_get_uris(data);
    if (uris == NULL) {
        g_printerr("mediafin: drop: nothing usable in the selection\n");
        return;
    }

    guint count = 0;
    while (uris[count] != NULL) {
        count++;
    }
    g_printerr("mediafin: drop: %u uri(s)\n", count);

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

    g_printerr("mediafin: drop: %u local path(s)\n", kept);
    if (kept > 0 && target != NULL && target->callback != NULL) {
        target->callback(paths, target->user_data);
        g_printerr("mediafin: drop: handed over\n");
    }

    for (guint i = 0; i < kept; i++) {
        g_free((gchar *)paths[i]);
    }
    g_free(paths);
    g_strfreev(uris);
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

int mediafin_confirm(GtkWidget *parent,
                     const char *heading,
                     const char *body,
                     const char *confirm_label,
                     const char *cancel_label) {
    GtkWindow *window = NULL;
    if (parent != NULL && GTK_IS_WINDOW(parent)) {
        window = GTK_WINDOW(parent);
    }
    /* GTK_MESSAGE_WARNING, not QUESTION: the dialog is not asking out of
       curiosity, it is telling the user that something is about to be thrown
       away. The icon carries that before the text is read. */
    GtkWidget *dialog = gtk_message_dialog_new(window,
                                               GTK_DIALOG_MODAL
                                                   | GTK_DIALOG_DESTROY_WITH_PARENT,
                                               GTK_MESSAGE_WARNING,
                                               GTK_BUTTONS_NONE,
                                               "%s", heading);
    if (dialog == NULL) {
        return 0;
    }
    if (body != NULL && body[0] != '\0') {
        /* _text, not _markup: this project forbids Pango markup everywhere
           (tools/check-markup.sh), because a file name is user data and a
           stray ampersand in one would otherwise take the label out. */
        gtk_message_dialog_format_secondary_text(GTK_MESSAGE_DIALOG(dialog),
                                                 "%s", body);
    }
    gtk_dialog_add_button(GTK_DIALOG(dialog), confirm_label, GTK_RESPONSE_ACCEPT);
    /* Cancel added last so it is the one with the keyboard focus: the safe
       answer should be the one a thoughtless Return gives. */
    GtkWidget *cancel = gtk_dialog_add_button(GTK_DIALOG(dialog),
                                              cancel_label,
                                              GTK_RESPONSE_CANCEL);
    gtk_dialog_set_default_response(GTK_DIALOG(dialog), GTK_RESPONSE_CANCEL);
    if (cancel != NULL) {
        gtk_widget_grab_focus(cancel);
    }

    gint response = gtk_dialog_run(GTK_DIALOG(dialog));
    gtk_widget_destroy(dialog);
    return response == GTK_RESPONSE_ACCEPT ? 1 : 0;
}

int mediafin_answer_dialog(int accept) {
    GList *toplevels = gtk_window_list_toplevels();
    int answered = 0;
    for (GList *node = toplevels; node != NULL; node = node->next) {
        GtkWidget *candidate = GTK_WIDGET(node->data);
        if (candidate == NULL || !GTK_IS_MESSAGE_DIALOG(candidate)) {
            continue;
        }
        if (!gtk_widget_get_visible(candidate)) {
            continue;
        }
        gtk_dialog_response(GTK_DIALOG(candidate),
                            accept ? GTK_RESPONSE_ACCEPT : GTK_RESPONSE_CANCEL);
        answered = 1;
        break;
    }
    /* list_toplevels returns a list the caller owns; the widgets in it are
       not referenced, so only the list itself is freed. */
    g_list_free(toplevels);
    return answered;
}
