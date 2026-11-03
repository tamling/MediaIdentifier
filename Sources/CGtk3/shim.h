#ifndef MEDIAFIN_CGTK3_SHIM_H
#define MEDIAFIN_CGTK3_SHIM_H

// gtk.h pulls in GDK, GLib, GObject, Pango and gdk-pixbuf, which is everything
// the front-end needs. Listing them separately would only risk an include order
// GTK does not support.
#include <gtk/gtk.h>

#endif /* MEDIAFIN_CGTK3_SHIM_H */
