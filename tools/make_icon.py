#!/usr/bin/env python3
"""Generates the MediaIdentifier app icon (clapperboard, Jellyfin-green theme)
and the full macOS AppIcon asset catalog. Run: python3 tools/make_icon.py"""
import os, json, math
from PIL import Image, ImageDraw, ImageFilter

S = 1024

def lerp(a, b, t): return tuple(int(a[i] + (b[i]-a[i])*t) for i in range(3))

def radial_layer(size, color, center, radius, strength):
    layer = Image.new("RGBA", (size, size), (0,0,0,0)); px = layer.load()
    cx, cy = center[0]*size, center[1]*size; r = radius*size
    for y in range(size):
        for x in range(size):
            d = math.hypot(x-cx, y-cy)/r
            if d < 1.0:
                px[x,y] = (color[0],color[1],color[2], int(255*strength*(1-d)**1.6))
    return layer

def background(size):
    base = Image.new("RGBA",(size,size),(7,16,13,255))
    base.alpha_composite(radial_layer(size,(18,59,48),(0.26,0.18),0.95,1.0))
    base.alpha_composite(radial_layer(size,(12,52,66),(0.85,0.95),0.9,0.95))
    base.alpha_composite(radial_layer(size,(31,201,143),(0.5,0.42),0.55,0.16))
    return base

def vgrad(top, bottom, h=S):
    g = Image.new("RGBA",(S,h)); px=g.load()
    for y in range(h):
        c = lerp(top,bottom,y/max(1,h-1))
        for x in range(S): px[x,y]=(c[0],c[1],c[2],255)
    return g

def make_master():
    inset = 96
    radius = int((S-2*inset)*0.2237)
    icon = Image.new("RGBA",(S,S),(0,0,0,0))

    # Shadow + card.
    shadow = Image.new("RGBA",(S,S),(0,0,0,0))
    ImageDraw.Draw(shadow).rounded_rectangle([inset,inset+26,S-inset,S-inset+26],radius=radius,fill=(0,0,0,150))
    icon.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(34)))
    mask = Image.new("L",(S,S),0)
    ImageDraw.Draw(mask).rounded_rectangle([inset,inset,S-inset,S-inset],radius=radius,fill=255)
    icon.paste(background(S),(0,0),mask)
    ov = Image.new("RGBA",(S,S),(0,0,0,0))
    ImageDraw.Draw(ov).rounded_rectangle([inset,inset,S-inset,S-inset],radius=radius,outline=(255,255,255,38),width=3)
    icon.alpha_composite(ov)

    # --- Clapperboard ---
    # body
    body = [300, 470, 724, 740]
    bmask = Image.new("L",(S,S),0); ImageDraw.Draw(bmask).rounded_rectangle(body,radius=34,fill=255)
    icon.paste(vgrad((26,38,33),(15,24,20)), (0,0), bmask)
    bd = ImageDraw.Draw(icon)
    bd.rounded_rectangle(body, radius=34, outline=(31,201,143,120), width=4)
    for i,ly in enumerate((545,610,675)):
        bd.rounded_rectangle([340, ly, 684-(i*90), ly+22], radius=11, fill=(31,201,143,95))

    # clapper top bar with diagonal stripes
    bar = [300, 300, 724, 430]
    barmask = Image.new("L",(S,S),0); ImageDraw.Draw(barmask).rounded_rectangle(bar,radius=26,fill=255)
    stripes = Image.new("RGBA",(S,S),(20,28,24,255))
    sd = ImageDraw.Draw(stripes)
    w = 70; x = 240; on = True
    while x < 760:
        sd.polygon([(x,300),(x+w,300),(x+w-110,440),(x-110,440)],
                   fill=(31,201,143,255) if on else (235,240,238,255))
        on = not on; x += w
    icon.paste(stripes,(0,0),barmask)
    ImageDraw.Draw(icon).rounded_rectangle(bar,radius=26,outline=(255,255,255,40),width=3)
    return icon

def export(master):
    app_dir = "Sources/MediaIdentifierApp/Assets.xcassets"
    icon_dir = os.path.join(app_dir, "AppIcon.appiconset")
    os.makedirs(icon_dir, exist_ok=True)

    specs = [(16,1),(16,2),(32,1),(32,2),(128,1),(128,2),(256,1),(256,2),(512,1),(512,2)]
    images = []; seen = {}
    for size, scale in specs:
        px = size*scale
        if px not in seen:
            fname = f"icon_{size}x{size}@{scale}x.png"
            master.resize((px,px), Image.LANCZOS).save(os.path.join(icon_dir,fname))
            seen[px] = fname
        images.append({"size":f"{size}x{size}","idiom":"mac","filename":seen[px],"scale":f"{scale}x"})

    with open(os.path.join(icon_dir,"Contents.json"),"w") as f:
        json.dump({"images":images,"info":{"version":1,"author":"xcode"}}, f, indent=2)
    with open(os.path.join(app_dir,"Contents.json"),"w") as f:
        json.dump({"info":{"version":1,"author":"xcode"}}, f, indent=2)

    os.makedirs("docs", exist_ok=True)
    master.save("docs/logo.png")
    print("Wrote", icon_dir, "and docs/logo.png")

if __name__ == "__main__":
    m = make_master()
    export(m)
    for s in (256,128,32):
        m.resize((s,s),Image.LANCZOS).save(f"/tmp/icon_final_{s}.png")
