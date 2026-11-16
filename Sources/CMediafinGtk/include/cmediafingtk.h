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

/// Asks the user to confirm something, and waits for the answer.
///
/// In C for the same reason the drop handler is: `gtk_message_dialog_new` and
/// `gtk_dialog_new_with_buttons` are both C variadics, which Swift cannot
/// call at all, and GTK offers no va_list form of either.
///
/// Returns 1 when the user chose the confirming button, 0 for anything else --
/// Cancel, Escape, or closing the window. Defaulting to 0 is the point: every
/// way of not answering has to mean no.
///
/// `confirm_label` is the affirmative button's text. It says what will happen
/// rather than "OK", because "OK" in a dialog somebody is dismissing reads as
/// "go away". Both labels come from the caller so they are translated by the
/// same `Text.s` as the rest of the interface; nothing here is in English by
/// accident.
int mediafin_confirm(GtkWidget *parent,
                     const char *heading,
                     const char *body,
                     const char *confirm_label,
                     const char *cancel_label);

/// Answers whatever confirmation dialog is on screen, for the smoke modes.
///
/// `accept` non-zero answers as the confirming button, zero as Cancel.
/// Returns 1 if a dialog was found and answered, 0 if none was on screen.
///
/// This exists so CI can press a button whose handler blocks in
/// `gtk_dialog_run`. Without it the confirmation could not be tested at all,
/// and an untestable guard is one somebody deletes without noticing -- which
/// is the failure this project keeps meeting. It only ever sends a response
/// to a dialog that is already up; it cannot create one, suppress one, or
/// make `mediafin_confirm` return without one.
int mediafin_answer_dialog(int accept);

#endif
