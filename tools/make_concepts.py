#!/usr/bin/env python3
"""Render three distinct app-icon concepts for review."""
import math
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

def card_base():
    inset = 96
    radius = int((S-2*inset)*0.2237)
    icon = Image.new("RGBA",(S,S),(0,0,0,0))
    shadow = Image.new("RGBA",(S,S),(0,0,0,0))
    ImageDraw.Draw(shadow).rounded_rectangle([inset,inset+26,S-inset,S-inset+26],radius=radius,fill=(0,0,0,150))
    icon.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(34)))
    mask = Image.new("L",(S,S),0)
    ImageDraw.Draw(mask).rounded_rectangle([inset,inset,S-inset,S-inset],radius=radius,fill=255)
    icon.paste(background(S),(0,0),mask)
    ov = Image.new("RGBA",(S,S),(0,0,0,0))
    ImageDraw.Draw(ov).rounded_rectangle([inset,inset,S-inset,S-inset],radius=radius,outline=(255,255,255,38),width=3)
    icon.alpha_composite(ov)
    return icon, mask

def vgrad(top, bottom, h=S):
    g = Image.new("RGBA",(S,h)); px=g.load()
    for y in range(h):
        c = lerp(top,bottom,y/max(1,h-1))
        for x in range(S): px[x,y]=(c[0],c[1],c[2],255)
    return g

def glow(poly_or_draw_fn, blur=26, color=(31,201,143,170)):
    g = Image.new("RGBA",(S,S),(0,0,0,0)); poly_or_draw_fn(ImageDraw.Draw(g), color)
    return g.filter(ImageFilter.GaussianBlur(blur))

# ---------- Concept A: Clapperboard ----------
def concept_clapper():
    icon, _ = card_base()
    cx = S//2
    # body
    body = [300, 470, 724, 740]
    bmask = Image.new("L",(S,S),0); ImageDraw.Draw(bmask).rounded_rectangle(body,radius=34,fill=255)
    icon.paste(vgrad((26,38,33),(15,24,20)), (0,0), bmask)
    bd = ImageDraw.Draw(icon)
    bd.rounded_rectangle(body, radius=34, outline=(31,201,143,120), width=4)
    # body text lines
    for i,ly in enumerate((545,610,675)):
        bd.rounded_rectangle([340, ly, 684-(i*90), ly+22], radius=11, fill=(31,201,143,90))
    # clapper top bar with diagonal stripes
    bar = [300, 300, 724, 430]
    barmask = Image.new("L",(S,S),0); ImageDraw.Draw(barmask).rounded_rectangle(bar,radius=26,fill=255)
    stripes = Image.new("RGBA",(S,S),(20,28,24,255))
    sd = ImageDraw.Draw(stripes)
    w = 70
    x = 240
    on = True
    while x < 760:
        sd.polygon([(x,300),(x+w,300),(x+w-110,440),(x-110,440)], fill=(31,201,143,255) if on else (235,240,238,255))
        on = not on; x += w
    icon.paste(stripes,(0,0),barmask)
    ImageDraw.Draw(icon).rounded_rectangle(bar,radius=26,outline=(255,255,255,40),width=3)
    return icon

# ---------- Concept B: Play tile ----------
def concept_play():
    icon, _ = card_base()
    cx=cy=S//2
    # inner tile with green gradient
    tile=[300,300,724,724]
    tmask=Image.new("L",(S,S),0); ImageDraw.Draw(tmask).rounded_rectangle(tile,radius=96,fill=255)
    icon.alpha_composite(glow(lambda d,c: d.rounded_rectangle(tile,radius=96,fill=c),blur=40,color=(0,168,120,150)))
    icon.paste(vgrad((38,214,160),(0,150,108)),(0,0),tmask)
    ImageDraw.Draw(icon).rounded_rectangle(tile,radius=96,outline=(255,255,255,60),width=4)
    # play triangle (white, rounded-ish)
    tri=[(452,406),(452,618),(648,512)]
    pmask=Image.new("L",(S,S),0); ImageDraw.Draw(pmask).polygon(tri,fill=255)
    pmask=pmask.filter(ImageFilter.GaussianBlur(2))
    white=Image.new("RGBA",(S,S),(255,255,255,255))
    icon.paste(white,(0,0),pmask)
    return icon

# ---------- Concept C: Film frame + check ----------
def concept_filmcheck():
    icon,_=card_base()
    # vertical film strip
    strip=[372,280,652,744]
    smask=Image.new("L",(S,S),0); ImageDraw.Draw(smask).rounded_rectangle(strip,radius=30,fill=255)
    icon.paste(vgrad((30,44,38),(17,26,22)),(0,0),smask)
    d=ImageDraw.Draw(icon)
    d.rounded_rectangle(strip,radius=30,outline=(31,201,143,140),width=4)
    # sprocket holes
    for sx in (398,604):
        y=312
        while y<712:
            d.rounded_rectangle([sx,y,sx+22,y+34],radius=6,fill=(31,201,143,70)); y+=66
    # frames
    for fy in (round(360),round(500)):
        d.rounded_rectangle([446,fy,558,fy+96],radius=12,outline=(31,201,143,110),width=4)
    # check badge bottom-right
    bc=(648,648)
    icon.alpha_composite(glow(lambda dr,c: dr.ellipse([bc[0]-92,bc[1]-92,bc[0]+92,bc[1]+92],fill=c),blur=24,color=(0,168,120,160)))
    bmask=Image.new("L",(S,S),0); ImageDraw.Draw(bmask).ellipse([bc[0]-92,bc[1]-92,bc[0]+92,bc[1]+92],fill=255)
    icon.paste(vgrad((46,224,168),(0,158,112)),(0,0),bmask)
    d.ellipse([bc[0]-92,bc[1]-92,bc[0]+92,bc[1]+92],outline=(255,255,255,70),width=4)
    d.line([(bc[0]-42,bc[1]+4),(bc[0]-10,bc[1]+38),(bc[0]+48,bc[1]-34)],fill=(255,255,255,255),width=22,joint="curve")
    return icon

concepts = {"A_clapper":concept_clapper(),"B_play":concept_play(),"C_filmcheck":concept_filmcheck()}
for name,img in concepts.items():
    img.resize((256,256),Image.LANCZOS).save(f"/tmp/concept_{name}.png")

# contact sheet
sheet=Image.new("RGBA",(256*3+64,256+90),(20,20,22,255))
dd=ImageDraw.Draw(sheet)
for i,(name,img) in enumerate(concepts.items()):
    x=16+i*(256+16)
    sheet.paste(img.resize((256,256),Image.LANCZOS),(x,16))
    dd.text((x+8,280),name.split("_")[0]+"  "+name.split("_")[1], fill=(230,230,235))
sheet.convert("RGB").save("/tmp/concepts_sheet.png")
print("done")
