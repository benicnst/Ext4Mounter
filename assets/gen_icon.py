#!/usr/bin/env python3
"""
Ext4Mounter v1.2 — App Icon Generator v3
Concept: 3D external HDD + lightning bolt (speed) + USB cable (mount)
"""
import os, subprocess, shutil
import numpy as np
from PIL import Image, ImageDraw, ImageFont, ImageFilter

SIZE   = 1024
CORNER = 182

# ── Palette ────────────────────────────────────────────────────────────────────
BG_CTR   = ( 14,  34,  88)    # background center  (deep navy)
BG_EDGE  = (  3,   8,  26)    # background edge    (near-black)

# Drive: silver aluminum
DR_TOP_HI = (250, 253, 255)   # top face highlight (almost white)
DR_TOP_MD = (218, 226, 242)   # top face main
DR_FR_HI  = (230, 235, 248)   # front face top
DR_FR_LO  = (160, 170, 196)   # front face bottom
DR_RT     = ( 84,  90, 112)   # right face (shadow)
DR_BASE   = (185, 193, 212)   # base/stand
DR_BASE_D = (140, 148, 170)   # base shadow side

# Lightning bolt
BOLT_CLR  = (255, 228,  44)   # yellow
BOLT_EDGE = (255, 180,   0)   # amber edge
BOLT_GLOW = (255, 200,  60,  55)   # warm glow

# Cable / connector
CABLE_CLR = (130, 138, 162)
CABLE_HI  = (175, 185, 210)
PLUG_CLR  = (108, 115, 138)

# Drive details
LED_A     = ( 60, 220, 100)   # green LED (active)
LED_B     = ( 60, 160, 255)   # blue LED
EXT4_CLR  = ( 34,  52, 120)   # "ext4" text (dark blue on silver)
STRIPE_LN = (145, 155, 180)   # decorative separator line


# ── Helpers ────────────────────────────────────────────────────────────────────

def radial_bg() -> Image.Image:
    cx, cy = SIZE // 2 - 30, SIZE // 2 - 20
    Y, X   = np.mgrid[0:SIZE, 0:SIZE]
    dist   = np.sqrt((X-cx)**2 + (Y-cy)**2).astype(np.float32)
    t      = np.clip(dist / (SIZE * 0.66), 0, 1)
    arr    = np.zeros((SIZE, SIZE, 4), dtype=np.uint8)
    for ch, ci, ce in zip(range(3), BG_CTR, BG_EDGE):
        arr[:,:,ch] = (ci*(1-t) + ce*t).astype(np.uint8)
    arr[:,:,3] = 255
    img  = Image.fromarray(arr)
    mask = Image.new("L", (SIZE, SIZE), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        [0, 0, SIZE-1, SIZE-1], radius=CORNER, fill=255)
    img.putalpha(mask)
    return img


def find_font(sz: int):
    for p in [
        "/System/Library/Fonts/SFNSDisplay-Bold.otf",
        "/System/Library/Fonts/SFNS.ttf",
        "/System/Library/Fonts/Helvetica.ttc",
        "/System/Library/Fonts/Arial.ttf",
    ]:
        if os.path.exists(p):
            try: return ImageFont.truetype(p, sz)
            except: pass
    return ImageFont.load_default()


def vgradient_layer(x0, y0, x1, y1, c_top, c_bot) -> Image.Image:
    """Vertical gradient clipped to axis-aligned rectangle."""
    arr = np.zeros((SIZE, SIZE, 4), dtype=np.uint8)
    h   = y1 - y0
    if h <= 0: return Image.fromarray(arr)
    t   = np.linspace(0, 1, h, dtype=np.float32)
    for ch, ci, ce in zip(range(3), c_top, c_bot):
        col = (ci*(1-t) + ce*t).astype(np.uint8)
        arr[y0:y1, x0:x1, ch] = col[:, None]
    arr[y0:y1, x0:x1, 3] = 255
    return Image.fromarray(arr)


def bolt_polygon(cx, cy, w, h):
    """Classic lightning bolt polygon (pointing downward)."""
    # Fraction where the horizontal crosspiece sits
    k = 0.38
    return [
        (cx + w*0.28,  cy - h*0.50),   # A: top-right
        (cx - w*0.16,  cy - h*(0.50-k)),# B: upper-left armpit
        (cx + w*0.20,  cy - h*(0.50-k)),# C: crosspiece right
        (cx - w*0.28,  cy + h*0.50),   # D: bottom-left
        (cx + w*0.16,  cy + h*(0.50-k)),# E: lower-right armpit
        (cx - w*0.20,  cy + h*(0.50-k)),# F: crosspiece left
    ]


# ── Main ───────────────────────────────────────────────────────────────────────

def make_icon() -> Image.Image:
    img  = radial_bg()

    # ── GEOMETRY ──────────────────────────────────────────────────────────────
    # Drive front face
    FX0, FY0, FX1, FY1 = 325, 268, 728, 560
    DX,  DY             = 52,  26          # isometric depth offset
    FR   = 28                              # front face corner radius
    # Top face (parallelogram)
    TOP  = [(FX0+DX, FY0-DY), (FX1+DX, FY0-DY), (FX1, FY0), (FX0, FY0)]
    # Right face
    RGT  = [(FX1, FY0), (FX1+DX, FY0-DY), (FX1+DX, FY1-DY), (FX1, FY1)]
    # Base/stand (wider than body, thin)
    BX0, BY0, BX1, BY1 = 296, FY1, 768, FY1+44
    BR   = 12
    # Cable
    CCX  = (FX0+FX1)//2 + 28
    CY0  = BY1
    CY1  = BY1 + 128
    CW   = 26
    # Lightning bolt
    BCX, BCY = 200, 408
    BW,  BH  = 200, 340

    # ── LIGHTNING BOLT GLOW (behind drive) ────────────────────────────────────
    for radius, alpha in [(170,10),(130,16),(95,24),(65,32),(40,42)]:
        glow_l = Image.new("RGBA", (SIZE,SIZE), (0,0,0,0))
        ImageDraw.Draw(glow_l).ellipse(
            [BCX-radius, BCY-radius, BCX+radius, BCY+radius],
            fill=(*BOLT_CLR[:3], alpha))
        glow_l = glow_l.filter(ImageFilter.GaussianBlur(28))
        img = Image.alpha_composite(img, glow_l)

    # ── LIGHTNING BOLT body (behind drive) ────────────────────────────────────
    bolt_layer = Image.new("RGBA", (SIZE,SIZE), (0,0,0,0))
    bd = ImageDraw.Draw(bolt_layer)
    pts = bolt_polygon(BCX, BCY, BW, BH)
    # Amber border (slightly larger offset polygon for rim)
    big = bolt_polygon(BCX, BCY, BW+14, BH+10)
    bd.polygon(big,  fill=(*BOLT_EDGE, 255))
    bd.polygon(pts,  fill=(*BOLT_CLR,  255))
    # Inner highlight
    small = bolt_polygon(BCX-6, BCY-10, BW*0.55, BH*0.50)
    bd.polygon(small, fill=(255, 248, 180, 140))
    img = Image.alpha_composite(img, bolt_layer)

    # ── DRIVE SHADOW ──────────────────────────────────────────────────────────
    shadow = Image.new("RGBA", (SIZE,SIZE), (0,0,0,0))
    sd     = ImageDraw.Draw(shadow)
    full   = [(FX0,FY1),(BX1,BY1),(BX1+DX,BY1-DY),
              (FX1+DX,FY0-DY),(FX0+DX,FY0-DY),(FX0,FY0)]
    sd.polygon(full, fill=(0,0,0,100))
    shadow = shadow.filter(ImageFilter.GaussianBlur(30))
    shadow = shadow.transform((SIZE,SIZE), Image.AFFINE, (1,0,0, 0,1,-18))
    img    = Image.alpha_composite(img, shadow)

    draw = ImageDraw.Draw(img)

    # ── RIGHT FACE (darkest) ──────────────────────────────────────────────────
    draw.polygon(RGT, fill=DR_RT)
    # subtle top-edge highlight on right face
    draw.line([RGT[0], RGT[1]], fill=(130,138,162), width=2)

    # ── TOP FACE (lightest, catches overhead light) ────────────────────────────
    draw.polygon(TOP, fill=DR_TOP_MD)
    # gradient effect on top: lighter toward left edge
    for i in range(0, DX, 3):
        t   = i / DX
        alp = int(55*(1-t))
        lx  = FX0+i; rx = FX1+i
        ly  = FY0 - int(DY*(1 - i/DX))
        draw.line([(lx, ly),(rx, ly)],
                  fill=(255,255,255, alp), width=3)
    # top-edge bright line
    draw.line([TOP[0], TOP[1]], fill=(252,254,255,220), width=3)

    # ── FRONT FACE GRADIENT ───────────────────────────────────────────────────
    fg  = vgradient_layer(FX0, FY0, FX1, FY1, DR_FR_HI, DR_FR_LO)
    # clip to rounded rect mask
    fmask = Image.new("L",(SIZE,SIZE),0)
    ImageDraw.Draw(fmask).rounded_rectangle(
        [FX0, FY0, FX1, FY1], radius=FR, fill=255)
    fg.putalpha(fmask)
    img  = Image.alpha_composite(img, fg)
    draw = ImageDraw.Draw(img)

    # Specular reflection (top-left glow on face)
    spec = Image.new("RGBA",(SIZE,SIZE),(0,0,0,0))
    ImageDraw.Draw(spec).ellipse(
        [FX0+10, FY0-40, FX0+(FX1-FX0)*0.7, FY0+(FY1-FY0)*0.42],
        fill=(255,255,255, 22))
    spec = spec.filter(ImageFilter.GaussianBlur(20))
    img  = Image.alpha_composite(img, spec)
    draw = ImageDraw.Draw(img)

    # Front face top edge bright line
    draw.line([(FX0+FR, FY0),(FX1-FR, FY0)],
              fill=(252,254,255,200), width=3)
    # Front face bottom shadow line
    draw.line([(FX0+FR, FY1),(FX1-FR, FY1)],
              fill=(60,68,90,180), width=2)
    # Front face right shadow
    draw.line([(FX1, FY0+FR),(FX1, FY1-FR)],
              fill=(100,108,132,120), width=2)

    # ── HORIZONTAL SEPARATOR LINE (like real HDD bezel split) ─────────────────
    SEP_Y = FY0 + (FY1-FY0)//4 + 10
    draw.line([(FX0+FR, SEP_Y),(FX1-FR, SEP_Y)],
              fill=STRIPE_LN, width=3)
    # subtle shadow below line
    draw.line([(FX0+FR, SEP_Y+3),(FX1-FR, SEP_Y+3)],
              fill=(220,226,242,120), width=2)

    # ── "ext4" TEXT on lower area of front face ───────────────────────────────
    font = find_font(148)
    label = "ext4"
    bb = draw.textbbox((0,0), label, font=font)
    tw, th = bb[2]-bb[0], bb[3]-bb[1]
    tx = (FX0+FX1)//2 - tw//2 - bb[0]
    ty = SEP_Y + ((FY1 - SEP_Y) - th)//2 - bb[1] - 2
    # text shadow
    draw.text((tx+2, ty+3), label, font=font, fill=(60,70,100,100))
    draw.text((tx, ty), label, font=font, fill=EXT4_CLR)

    # ── LED DOTS (right side, upper bezel area) ────────────────────────────────
    for (lx, ly, lc) in [
        (FX1-44, FY0+42, LED_A),   # green: activity
        (FX1-44, FY0+80, LED_B),   # blue:  power
    ]:
        lr = 10
        # glow
        gl = Image.new("RGBA",(SIZE,SIZE),(0,0,0,0))
        ImageDraw.Draw(gl).ellipse(
            [lx-22,ly-22,lx+22,ly+22], fill=(*lc, 50))
        gl = gl.filter(ImageFilter.GaussianBlur(8))
        img = Image.alpha_composite(img, gl)
        draw = ImageDraw.Draw(img)
        draw.ellipse([lx-lr-2,ly-lr-2,lx+lr+2,ly+lr+2], fill=(40,48,72))
        draw.ellipse([lx-lr,  ly-lr,  lx+lr,  ly+lr],   fill=lc)
        draw.ellipse([lx-5,   ly-7,   lx+2,   ly-2],
                     fill=(220,240,255,170))   # specular

    # ── DRIVE BASE / STAND ────────────────────────────────────────────────────
    # Right side of base (shadow)
    base_rgt = [(BX1, BY0), (BX1+DX, BY0-DY),
                (BX1+DX, BY1-DY), (BX1, BY1)]
    draw.polygon(base_rgt, fill=(95,102,125))
    # Base top face
    base_top = [(BX0+DX, BY0-DY), (BX1+DX, BY0-DY), (BX1, BY0), (BX0, BY0)]
    draw.polygon(base_top, fill=DR_TOP_MD)
    # Base front face gradient
    bg2 = vgradient_layer(BX0, BY0, BX1, BY1, DR_BASE, DR_BASE_D)
    bm2 = Image.new("L",(SIZE,SIZE),0)
    ImageDraw.Draw(bm2).rounded_rectangle(
        [BX0, BY0, BX1, BY1], radius=BR, fill=255)
    bg2.putalpha(bm2)
    img  = Image.alpha_composite(img, bg2)
    draw = ImageDraw.Draw(img)
    # Base top edge highlight
    draw.line([(BX0+BR, BY0),(BX1-BR, BY0)], fill=(240,244,252,180), width=2)

    # ── USB CABLE ─────────────────────────────────────────────────────────────
    # Plug head (just below base)
    PH = 46   # plug head height
    PW = CW + 20
    draw.rounded_rectangle(
        [CCX-PW//2, CY0, CCX+PW//2, CY0+PH],
        radius=8, fill=PLUG_CLR)
    draw.line([(CCX-PW//2+6, CY0+2),(CCX+PW//2-6, CY0+2)],
              fill=(160,168,190,180), width=2)
    # Cable body
    draw.rectangle(
        [CCX-CW//2, CY0+PH, CCX+CW//2, CY1],
        fill=CABLE_CLR)
    # Cable highlight
    draw.line([(CCX-CW//2+4, CY0+PH),(CCX-CW//2+4, CY1)],
              fill=(*CABLE_HI, 140), width=4)
    # Cable bottom connector
    draw.rounded_rectangle(
        [CCX-PW//2, CY1, CCX+PW//2, CY1+36],
        radius=8, fill=PLUG_CLR)

    # ── LIGHTNING BOLT ON TOP (overlapping drive slightly) ────────────────────
    # Re-draw the front portion of the bolt over the drive edge
    bolt_front = Image.new("RGBA",(SIZE,SIZE),(0,0,0,0))
    bfd = ImageDraw.Draw(bolt_front)
    # Only the right half of bolt that overlaps the drive, slightly transparent
    clip_pts = bolt_polygon(BCX, BCY, BW, BH)
    bfd.polygon(clip_pts, fill=(*BOLT_CLR, 210))
    # inner highlight
    bfd.polygon(bolt_polygon(BCX-4, BCY-8, BW*0.5, BH*0.45),
                fill=(255,250,200,130))
    img = Image.alpha_composite(img, bolt_front)

    return img


# ── Export ─────────────────────────────────────────────────────────────────────

def export_icns(icon, out_dir, icns_path):
    iconset = os.path.join(out_dir, "AppIcon.iconset")
    os.makedirs(iconset, exist_ok=True)
    for fname, sz in [
        ("icon_16x16.png",16),("icon_16x16@2x.png",32),
        ("icon_32x32.png",32),("icon_32x32@2x.png",64),
        ("icon_128x128.png",128),("icon_128x128@2x.png",256),
        ("icon_256x256.png",256),("icon_256x256@2x.png",512),
        ("icon_512x512.png",512),("icon_512x512@2x.png",1024),
    ]:
        icon.resize((sz,sz),Image.LANCZOS).save(os.path.join(iconset,fname))
        print(f"  {fname}")
    subprocess.run(["iconutil","-c","icns",iconset,"-o",icns_path],check=True)
    shutil.rmtree(iconset)
    print(f"✓ {icns_path}")


if __name__ == "__main__":
    base = os.path.dirname(os.path.abspath(__file__))
    icon = make_icon()
    preview = os.path.join(base, "icon_preview_1024.png")
    icon.save(preview)
    print(f"Preview: {preview}")
    icns = os.path.join(base, "AppIcon.icns")
    export_icns(icon, base, icns)
    app_icns = os.path.abspath(os.path.join(
        base, "..", "app", "Ext4Mounter.app", "Contents", "Resources", "AppIcon.icns"))
    if os.path.exists(os.path.dirname(app_icns)):
        shutil.copy2(icns, app_icns)
        print(f"✓ Deployed: {app_icns}")
