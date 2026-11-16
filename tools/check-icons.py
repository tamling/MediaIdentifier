#!/usr/bin/env python3
"""Keeps the icon the package installs and the icon the entry asks for in step.

Three files have to agree about one name and one list of sizes:

  * tools/make_icon.py draws them and writes packaging/icons/<n>x<n>/,
  * tools/build-deb.sh installs those into the hicolor theme,
  * the .desktop entry it writes names the icon to look up.

Each pair can drift on its own, and none of the drifts shows up as an error.
A size added to the drawing and not to the packaging simply never ships. A
rename on the entry's side alone leaves a blank tile in the application
menu, which looks exactly like an icon theme that has not refreshed yet --
the application is there, it starts, and only the picture is missing.

This reads the three files rather than re-rendering: a comparison against
freshly drawn pixels would need Pillow, which the release runner does not
have, and the drift this catches is in the lists, not in the drawing.
"""
import pathlib
import re
import struct
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
DRAWER = ROOT / "tools/make_icon.py"
PACKAGER = ROOT / "tools/build-deb.sh"


def png_size(path):
    """Width and height from the IHDR, without decoding the image."""
    with open(path, "rb") as handle:
        header = handle.read(24)
    if len(header) < 24 or header[:8] != b"\x89PNG\r\n\x1a\n":
        return None
    return struct.unpack(">II", header[16:24])


def main() -> int:
    problems = []

    drawer = DRAWER.read_text(encoding="utf-8")
    match = re.search(r"^SIZES = \(([^)]*)\)", drawer, re.M)
    if not match:
        print("FAIL  : no SIZES tuple in tools/make_icon.py")
        return 1
    drawn = [int(n) for n in re.findall(r"\d+", match.group(1))]

    packager = PACKAGER.read_text(encoding="utf-8")
    match = re.search(r"for size in ([\d ]+); do", packager)
    if not match:
        problems.append("tools/build-deb.sh has no `for size in …` loop over "
                        "the icon sizes")
        packaged = []
    else:
        packaged = [int(n) for n in match.group(1).split()]

    if packaged and sorted(drawn) != sorted(packaged):
        problems.append(
            f"make_icon.py draws {sorted(drawn)} but build-deb.sh installs "
            f"{sorted(packaged)} -- a size in one list and not the other "
            f"never reaches a desktop")

    # The name the entry asks for, and the name on disk.
    match = re.search(r"^Icon=(.+)$", packager, re.M)
    wanted = match.group(1).strip() if match else None
    if not wanted:
        problems.append("the .desktop entry in build-deb.sh has no Icon= line")

    for size in drawn:
        path = ROOT / f"packaging/icons/{size}x{size}/{wanted}.png"
        if not path.exists():
            problems.append(f"{path.relative_to(ROOT)} is missing -- run "
                            f"python3.12 tools/make_icon.py")
            continue
        measured = png_size(path)
        if measured is None:
            problems.append(f"{path.relative_to(ROOT)} is not a PNG")
        elif measured != (size, size):
            problems.append(f"{path.relative_to(ROOT)} is "
                            f"{measured[0]}x{measured[1]}, not {size}x{size}")

    # A check that finds nothing to check is a check that cannot fail.
    if not drawn:
        problems.append("SIZES is empty, so this check asserts nothing")

    if problems:
        print("FAIL  : the icon, the package and the desktop entry disagree:")
        for problem in problems:
            print(f"        {problem}")
        return 1

    print(f"ok    : icon `{wanted}` ships at {sorted(drawn)} and the entry "
          f"asks for that name")
    return 0


if __name__ == "__main__":
    sys.exit(main())
