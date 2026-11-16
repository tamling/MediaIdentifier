#!/usr/bin/env python3
"""Keeps the README's table of window modes in step with the window.

    python3 tools/check-modes.py .build/release/mediafin-gtk

The table in "How it is tested" listed four modes for a binary that had
seven. Nobody noticed, because an incomplete list reads exactly like a
complete one -- and the sharper version of the same drift is a table that
names a mode which no longer exists, which a reader will type and be told
is unknown.

Both directions fail here. The modes come from the binary's own `--help`,
because that is what a reader would reach for next.

Not every flag belongs in the table: `--panel`, `--delay` and `--demo`
modify a mode rather than being one, and `--help` is not worth a row. They
are listed below rather than guessed at, so adding a flag means deciding
which kind it is.
"""
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
README = ROOT / "README.md"

# Flags that modify another mode, or are not worth a row of their own.
MODIFIERS = {"--panel", "--delay", "--demo", "--help"}


def modes_from_help(binary):
    try:
        text = subprocess.run([binary, "--help"], capture_output=True,
                              text=True, timeout=60).stdout
    except (OSError, subprocess.SubprocessError) as error:
        sys.exit(f"could not run {binary} --help: {error}")
    found = set(re.findall(r"^\s+mediafin-gtk (--[a-z-]+)", text, re.M))
    return {flag for flag in found if flag not in MODIFIERS}


def modes_from_readme():
    text = README.read_text(encoding="utf-8")
    table = re.search(r"\| `--screenshot FILE`.*?\n\n", text, re.S)
    if not table:
        sys.exit("FAIL  : no table of window modes in README.md")
    return set(re.findall(r"\| `(--[a-z-]+)", table.group(0)))


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__)
        return 64
    built = modes_from_help(sys.argv[1])
    written = modes_from_readme()

    # A check that finds nothing to check is a check that cannot fail.
    if not built:
        print("FAIL  : --help listed no modes at all, so this check asserts "
              "nothing")
        return 1

    missing = sorted(built - written)
    extra = sorted(written - built)
    if missing or extra:
        print("FAIL  : the README's table of window modes and the window "
              "disagree:")
        for flag in missing:
            print(f"        {flag} exists and is not in the table")
        for flag in extra:
            print(f"        {flag} is in the table and the window does not "
                  f"have it -- a reader will type it and be told it is "
                  f"unknown")
        return 1

    print(f"ok    : the README lists all {len(built)} window modes "
          f"({', '.join(sorted(built))})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
