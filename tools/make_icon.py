#!/usr/bin/env python3
"""Generates the MediaIdentifier app icon (dark Jellyfin-green theme) and the
full macOS AppIcon asset catalog. Run: python3 tools/make_icon.py"""
import os, json, math
from PIL import Image, ImageDraw, ImageFilter

S = 1024

def lerp(a, b, t): return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))

def radial_layer(size, color, center, radius, strength):
    """RGBA layer: `color` at `center`, fading to transparent by `radius`."""
    layer = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    px = layer.load()
    cx, cy = center[0] * size, center[1] * size
    r = radius * size
    for y in range(size):
        for x in range(size):
            d = math.hypot(x - cx, y - cy) / r
            if d < 1.0:
                a = int(255 * strength * (1 - d) ** 1.6)
                px[x, y] = (color[0], color[1], color[2], a)
    return layer

def background(size):
    base = Image.new("RGBA", (size, size), (7, 16, 13, 255))  # #07100d
    base.alpha_composite(radial_layer(size, (18, 59, 48), (0.26, 0.18), 0.95, 1.0))   # green TL
    base.alpha_composite(radial_layer(size, (12, 52, 66), (0.85, 0.95), 0.9, 0.95))  # teal BR
    base.alpha_composite(radial_layer(size, (31, 201, 143), (0.5, 0.42), 0.55, 0.16)) # subtle glow
    return base

def rounded_mask(size, radius, inset):
    m = Image.new("L", (size, size), 0)
    d = ImageDraw.Draw(m)
    d.rounded_rectangle([inset, inset, size - inset, size - inset], radius=radius, fill=255)
    return m

def vertical_gradient(box, top, bottom):
    w, h = box
    g = Image.new("RGBA", (w, h))
    px = g.load()
    for y in range(h):
        c = lerp(top, bottom, y / max(1, h - 1))
        for x in range(w):
            px[x, y] = (c[0], c[1], c[2], 255)
    return g

def make_master():
    icon = Image.new("RGBA", (S, S), (0, 0, 0, 0))

    inset = 96
    radius = int((S - 2 * inset) * 0.2237)

    # Drop shadow.
    shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    sd = ImageDraw.Draw(shadow)
    sd.rounded_rectangle([inset, inset + 26, S - inset, S - inset + 26], radius=radius,
                         fill=(0, 0, 0, 150))
    shadow = shadow.filter(ImageFilter.GaussianBlur(34))
    icon.alpha_composite(shadow)

    # Card.
    mask = rounded_mask(S, radius, inset)
    card = background(S)
    icon.paste(card, (0, 0), mask)

    # Inner hairline + top gloss.
    overlay = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    od = ImageDraw.Draw(overlay)
    od.rounded_rectangle([inset, inset, S - inset, S - inset], radius=radius,
                         outline=(255, 255, 255, 38), width=3)
    gloss = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    gd = ImageDraw.Draw(gloss)
    gd.rounded_rectangle([inset, inset, S - inset, inset + int((S - 2 * inset) * 0.42)],
                         radius=radius, fill=(255, 255, 255, 16))
    gloss = gloss.filter(ImageFilter.GaussianBlur(12))
    icon.alpha_composite(Image.composite(gloss, Image.new("RGBA", (S, S), (0, 0, 0, 0)), mask))
    icon.alpha_composite(overlay)

    # --- Film perforations (subtle texture down both card edges) ---
    perf = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    pd = ImageDraw.Draw(perf)
    hole_w, hole_h, gap = 26, 40, 78
    for col_x in (inset + 60, S - inset - 60 - hole_w):
        y = inset + 80
        while y < S - inset - 80:
            pd.rounded_rectangle([col_x, y, col_x + hole_w, y + hole_h], radius=8,
                                 fill=(31, 201, 143, 28))
            y += gap
    icon.alpha_composite(Image.composite(perf, Image.new("RGBA", (S, S), (0, 0, 0, 0)), mask))

    # --- Hero arrow (rename / transform) ---
    cy = S // 2
    arrow = [
        (300, cy - 46), (556, cy - 46), (556, cy - 132),
        (724, cy), (556, cy + 132), (556, cy + 46), (300, cy + 46),
    ]
    # Glow behind.
    glow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(glow).polygon(arrow, fill=(31, 201, 143, 180))
    glow = glow.filter(ImageFilter.GaussianBlur(26))
    icon.alpha_composite(glow)

    # Gradient-filled arrow via mask.
    amask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(amask).polygon(arrow, fill=255)
    agrad = vertical_gradient((S, S), (60, 230, 175), (0, 160, 112))
    icon.paste(agrad, (0, 0), amask)

    # Three "assembling" segments left of the shaft (motion / batch).
    seg = ImageDraw.Draw(icon)
    for i, (x0, x1) in enumerate([(150, 214), (196, 260), (242, 300)]):
        a = 150 + i * 35
        seg.rounded_rectangle([x0, cy - 30, x1, cy + 30], radius=22, fill=(31, 201, 143, a))

    return icon

def export(master):
    app_dir = "Sources/MediaIdentifierApp/Assets.xcassets"
    icon_dir = os.path.join(app_dir, "AppIcon.appiconset")
    os.makedirs(icon_dir, exist_ok=True)

    specs = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
             (256, 1), (256, 2), (512, 1), (512, 2)]
    images = []
    seen = {}
    for size, scale in specs:
        px = size * scale
        fname = f"icon_{size}x{size}@{scale}x.png"
        if px not in seen:
            img = master.resize((px, px), Image.LANCZOS)
            img.save(os.path.join(icon_dir, fname))
            seen[px] = fname
        else:
            fname = seen[px]  # reuse identical pixel size
        images.append({"size": f"{size}x{size}", "idiom": "mac",
                       "filename": fname, "scale": f"{scale}x"})

    with open(os.path.join(icon_dir, "Contents.json"), "w") as f:
        json.dump({"images": images, "info": {"version": 1, "author": "xcode"}}, f, indent=2)
    with open(os.path.join(app_dir, "Contents.json"), "w") as f:
        json.dump({"info": {"version": 1, "author": "xcode"}}, f, indent=2)

    os.makedirs("docs", exist_ok=True)
    master.save("docs/logo.png")
    print("Wrote", icon_dir, "and docs/logo.png")

if __name__ == "__main__":
    m = make_master()
    export(m)
    # Legibility previews.
    for s in (128, 64, 32):
        m.resize((s, s), Image.LANCZOS).save(f"/tmp/icon_preview_{s}.png")
    m.resize((256, 256), Image.LANCZOS).save("/tmp/icon_preview_256.png")
