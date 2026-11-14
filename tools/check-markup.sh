#!/usr/bin/env bash
# Pango markup is XML. The text that would go into it is filenames, and an
# unescaped "&" makes Pango reject the whole string so the label renders
# empty — losing the one thing the row existed to show.
#
# So there is exactly one place allowed to call gtk_label_set_markup:
# Gtk.setStyledText, which escapes through PangoMarkup.span and takes the
# text rather than prepared markup. This fails the build if a second one
# appears. A rule a script enforces beats a rule in a comment, which is the
# lesson of a traversal defence that had three passing tests and no caller.
set -euo pipefail

cd "$(dirname "$0")/.."

offenders=$(grep -rn "gtk_label_set_markup" --include="*.swift" Sources/ \
  | grep -v "GtkSupport.swift:" || true)

if [ -n "$offenders" ]; then
  echo "FAIL: gtk_label_set_markup is called outside Gtk.setStyledText."
  echo "      Use Gtk.setStyledText(widget, text, weight:) — it escapes."
  echo "$offenders"
  exit 1
fi

# And the one allowed call must still go through the escaper.
if ! grep -q "PangoMarkup.span" Sources/MediaIdentifierGtk/GtkSupport.swift; then
  echo "FAIL: Gtk.setStyledText no longer escapes through PangoMarkup."
  exit 1
fi

echo "ok    : Pango markup is only produced by PangoMarkup.span"
