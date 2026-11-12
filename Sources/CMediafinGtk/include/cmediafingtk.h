#ifndef CMEDIAFINGTK_H
#define CMEDIAFINGTK_H

#include <gtk/gtk.h>

/// Accepting dropped files, in C.
///
/// Not in Swift, and deliberately. GTK's drag protocol hands the callback a
/// `GdkDragContext *` and a `GtkSelectionData *`, and how those arrive in
/// Swift depends on the module map and the GTK version: an opaque pointer
/// here, a struct pointer there. Writing the handler in C means the types are
/// whatever the installed GTK says they are, and Swift only ever sees a
/// function pointer and a list of strings.

/// Called with the dropped files as a NULL-terminated array of local paths.
///
/// Only local files appear. A URI that is not a file — a web address dragged
/// out of a browser — has no path to rename and is left out.
typedef void (*mediafin_drop_callback)(const char *const *paths, void *user_data);

/// Called once, when the widget goes away, so the caller can let go of
/// whatever `user_data` was.
typedef void (*mediafin_drop_release)(void *user_data);

/// Makes `widget` accept files dragged from a file manager.
///
/// `text/uri-list` is the one thing every Linux file manager sends — Nautilus,
/// Dolphin, Thunar, Nemo all do. Nothing else is accepted, so dragging a
/// selection of text onto the window does nothing at all rather than something
/// surprising.
void mediafin_accept_file_drops(GtkWidget *widget,
                                mediafin_drop_callback callback,
                                void *user_data,
                                mediafin_drop_release release);

#endif
