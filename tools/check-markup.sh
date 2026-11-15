#!/usr/bin/env bash
# Pango markup is XML. The text that would go into it is filenames, and an
# unescaped "&" makes Pango reject the whole string, so the label renders
# empty — losing the one thing the row existed to show.
#
# This program does not use markup at all: labels are styled with CSS
# classes through Styling.style, which takes no text and cannot be
# malformed. So the rule is a flat prohibition rather than "one sanctioned
# sink", which is what it was — and that sink had no callers, while eleven
# escaping tests and a green CI line covered a path nothing reached. The
# version before that was an unescaped sink with no callers. Twice is enough.
#
# If a label ever genuinely needs markup: add one function that takes the
# TEXT, escapes it, and is the only caller of gtk_label_set_markup, and
# narrow this rule to that function by name — not by file, which is how the
# previous version let anything else in GtkSupport.swift through.
set -euo pipefail

cd "$(dirname "$0")/.."

# Comment lines are excluded, and only comment lines: the rule is about
# code. The first version of this flagged its own explanation, which is the
# kind of thing that gets a check deleted rather than fixed.
offenders=$(grep -rn "gtk_label_set_markup\|gtk_label_set_use_markup" \
  --include="*.swift" Sources/ \
  | grep -vE "^[^:]+:[0-9]+: *//" || true)

if [ -n "$offenders" ]; then
  echo "FAIL: Pango markup is produced somewhere. The text going into it is"
  echo "      filenames, and one unescaped '&' renders the whole label empty."
  echo "      Style labels with Styling.style instead, or read the comment at"
  echo "      the top of this script."
  echo "$offenders"
  exit 1
fi

echo "ok    : no Pango markup is produced anywhere in Sources"
