#!/usr/bin/env python3
"""Draws the Mediafin app icon and every size the package installs.

    python3.12 tools/make_icon.py

Python 3.12 on purpose: Pillow here is built for it, and plain `python3` is
3.11, where `from PIL import Image` fails on the C extension.

The icon is a white card with the M on it and a few coloured cards peeking
out from behind -- the library the program sorts, with the one you are
looking at on top. It replaces a dark green clapperboard that only ever
appeared in the README: nothing installed it, and the application menu
showed a stock icon from the user's theme instead.

The restraint in the cards is the whole design. An earlier pass had seven of
them all round the tile, which looks lively at 1024 px and turns to noise at
48 -- which is the size an icon is actually seen at. These five peek by a
sliver each, so the silhouette stays a rounded square.

Everything is drawn, not loaded: no font to install, no asset to keep in
step with the code, and the weight of the letter is ours to choose.
"""
import os
import sys

try:
    from PIL import Image, ImageDraw, ImageFilter
except ImportError as error:                              # pragma: no cover
    sys.exit(f"{error}\n\nTry: python3.12 {sys.argv[0]}")

S = 1024
INSET = 104
RADIUS = int((S - 2 * INSET) * 0.2237)

AMBER = (245, 166, 35)
BLUE = (56, 130, 246)
PINK = (233, 70, 148)
GREEN = (31, 201, 143)
TEAL = (45, 170, 190)
# Darker than the interface's accent: the accent is for lamps and bars on a
# dark window, and on white it reads as washed out.
INK = (10, 117, 88)

# x, y, width, height, angle, colour. Each one peeks past the tile by a
# sliver; see the note above about why they are not bigger.
CARDS = [
    (250, 74, 150, 70, -12, AMBER),
    (560, 66, 176, 72, 10, PINK),
    (66, 338, 88, 190, -5, BLUE),
    (66, 584, 88, 150, 5, GREEN),
    (872, 430, 86, 210, 6, TEAL),
]

# The sizes an icon theme looks for, plus 512 for anything that scales.
SIZES = (512, 256, 128, 64, 48, 32)


def card(icon, x, y, w, h, angle, colour):
    """One card behind the tile, rotated about its own middle."""
    # Rotation without `expand` crops to the layer, so the layer is padded
    # wide enough that a corner cannot be cut off.
    pad = 220
    layer = Image.new("RGBA", (w + 2 * pad, h + 2 * pad), (0, 0, 0, 0))
    ImageDraw.Draw(layer).rounded_rectangle(
        [pad, pad, pad + w, pad + h], radius=int(min(w, h) / 2.4),
        fill=colour + (255,))
    layer = layer.rotate(angle, resample=Image.BICUBIC, expand=False)
    icon.alpha_composite(layer, (x - pad, y - pad))


def make():
    icon = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    for one in CARDS:
        card(icon, *one)

    # A shadow tight enough to read as a card lying on the cards behind it,
    # rather than as a tile floating above the desktop.
    shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle(
        [INSET + 8, INSET + 16, S - INSET - 8, S - INSET + 16],
        radius=RADIUS, fill=(12, 26, 21, 95))
    icon.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(20)))

    # Not flat white: a breath of warmth downward, so the card has a surface.
    tile = Image.new("RGBA", (S, S))
    pixels = tile.load()
    for y in range(S):
        t = y / (S - 1)
        colour = (int(255 - 10 * t), int(255 - 8 * t), int(253 - 9 * t), 255)
        for x in range(S):
            pixels[x, y] = colour
    mask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        [INSET, INSET, S - INSET, S - INSET], radius=RADIUS, fill=255)
    icon.paste(tile, (0, 0), mask)

    # The M as a stroked path. Round terminals, because the cards behind it
    # are rounded too and a flat-cut letter sat oddly among them.
    draw = ImageDraw.Draw(icon)
    width = 78
    left, right, top, bottom, valley = 368, 656, 392, 688, 596
    points = [(left, bottom), (left, top), ((left + right) // 2, valley),
              (right, top), (right, bottom)]
    draw.line(points, fill=INK + (255,), width=width, joint="curve")
    # `joint="curve"` rounds the corners but leaves the four ENDS cut square.
    for point in (points[0], points[1], points[3], points[4]):
        draw.ellipse([point[0] - width // 2, point[1] - width // 2,
                      point[0] + width // 2, point[1] + width // 2],
                     fill=INK + (255,))

    # So the card has an edge of its own on a white desktop.
    ImageDraw.Draw(icon).rounded_rectangle(
        [INSET, INSET, S - INSET, S - INSET], radius=RADIUS,
        outline=(16, 34, 28, 30), width=3)
    return icon


def export(master):
    """Writes the README's logo and the sizes the .deb installs.

    The sizes are committed rather than generated at package time: building
    a .deb should not need Pillow, and the release workflow does not have it.
    """
    os.makedirs("docs", exist_ok=True)
    master.save("docs/logo.png")
    written = ["docs/logo.png"]
    for size in SIZES:
        path = f"packaging/icons/{size}x{size}/mediafin.png"
        os.makedirs(os.path.dirname(path), exist_ok=True)
        master.resize((size, size), Image.LANCZOS).save(path)
        written.append(path)
    for path in written:
        print("wrote", path)


if __name__ == "__main__":
    export(make())
