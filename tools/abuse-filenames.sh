#!/usr/bin/env bash
# DAST, the part that can be done: build a folder of hostile file names and
# drive the real window over it.
#
# The review admitted this was missing. There is no Swift toolchain on the
# machine this is developed from, so the only place the binary exists is CI
# — which means the only place it can be attacked is CI. Everything the
# static review said about these inputs was derived by reading, and reading
# is weaker.
#
# Creates the files, prints how many it made. The caller presses Scan.
set -euo pipefail

target="${1:?usage: abuse-filenames.sh DIRECTORY}"
mkdir -p "$target"

made=0
make() {
  # printf %b so the caller can pass \n and \033 and have them be real.
  local name
  name=$(printf '%b' "$1")
  # Refused by the kernel, not by us: a name with a slash or a NUL cannot
  # exist on Linux, so there is nothing to test there.
  if : > "$target/$name" 2>/dev/null; then
    made=$((made + 1))
  else
    echo "  (kernel refused: $(printf '%q' "$name"))"
  fi
}

# Control characters in a name are legal on Linux and routinely arrive from
# a download. They must not reach a proposed path, a label or the journal.
make 'Film.2019.1080p\nmit.Umbruch-GROUP.mkv'
make 'Film.2019.1080p\ttab-GROUP.mkv'
make 'Film.2019\033[31mrot\033[0m-GROUP.mkv'
make 'Film.2019\177del-GROUP.mkv'

# Pango markup, which is XML. An unescaped & makes a label render EMPTY.
make 'Film & Sohn.2019.1080p-GROUP.mkv'
make 'Film <b>fett</b>.2019-GROUP.mkv'
make 'Film "zitiert" ''einfach''.2019-GROUP.mkv'
make 'Film&amp;schon.2019-GROUP.mkv'

# Shell and option shapes. Nothing here runs through a shell, and every
# path handed to ffmpeg is absolute — which is the claim being tested.
make '-i.2019.1080p-GROUP.mkv'
make '--config-location.2019-GROUP.mkv'
make 'Film;rm -rf aua.2019-GROUP.mkv'
make 'Film$(whoami).2019-GROUP.mkv'
make 'Film`id`.2019-GROUP.mkv'
make 'Film|pipe.2019-GROUP.mkv'

# Path shapes that cannot climb out but can still confuse a parser.
make '...2019-GROUP.mkv'
make '..dotdot.2019-GROUP.mkv'
make '.hidden.2019-GROUP.mkv'

# Length. ext4 stops at 255 bytes per component, so the name itself is
# capped; what is being tested is the PROPOSAL built from it.
make "$(printf 'A%.0s' {1..200}).2019.1080p-GROUP.mkv"
make "$(printf 'Ä%.0s' {1..100}).2019.1080p-GROUP.mkv"

# Unicode that breaks naive truncation.
make 'Film👨‍👩‍👧‍👦Familie.2019-GROUP.mkv'
make 'Film🇩🇪Flagge.2019-GROUP.mkv'
make 'Filmé́́kombinierend.2019-GROUP.mkv'
make 'Fil‮m.2019-GROUP.mkv'

# Titles that are nothing but strippable characters: the proposal must
# still land somewhere rather than appending nothing to the root.
make '....mkv'
make '   .mkv'
make '?*:|<>.mkv'

# And one perfectly ordinary file, so a run that proposes nothing at all
# is distinguishable from a run that refused everything.
make 'Tenet.2020.1080p.BluRay.x264-GROUP.mkv'

echo "abuse files created: $made"
