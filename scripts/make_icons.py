#!/usr/bin/env python3
"""Draws the app icon, its alternates and their previews into the asset
catalog. Needs Pillow. Run from the repository root."""

import json
import math
import os

from PIL import Image, ImageDraw, ImageFilter

ASSETS = "AnkiApp/Resources/Assets.xcassets"
S = 1024

# name: (top colour, bottom colour, card alpha, star colour)
VARIANTS = {
    "Classic": ((40, 120, 255), (88, 70, 220), 215, (52, 110, 245)),
    "Midnight": ((22, 26, 48), (6, 8, 20), 60, (120, 160, 255)),
    "Sunset": ((255, 150, 60), (230, 60, 110), 215, (240, 90, 80)),
    "Forest": ((40, 170, 110), (16, 100, 80), 215, (30, 140, 90)),
    "Berry": ((200, 70, 220), (110, 40, 190), 215, (170, 60, 210)),
    "Mono": ((240, 240, 244), (205, 205, 212), 255, (40, 40, 46)),
}


def draw(top, bottom, card_alpha, star, transparent=False, tint=False):
    if transparent:
        img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    else:
        img = Image.new("RGBA", (S, S))
        d = ImageDraw.Draw(img)
        for y in range(S):
            t = y / S
            c = tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3))
            d.line([(0, y), (S, y)], fill=c + (255,))

    def card(alpha, angle, outline=90):
        layer = Image.new("RGBA", (S, S), (0, 0, 0, 0))
        ld = ImageDraw.Draw(layer)
        fill = (255, 255, 255, alpha)
        ld.rounded_rectangle((250, 210, 790, 810), radius=70, fill=fill,
                             outline=(255, 255, 255, min(255, alpha + outline)), width=6)
        return layer.rotate(angle, resample=Image.BICUBIC, center=(S / 2, S / 2))

    if not transparent:
        shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
        ImageDraw.Draw(shadow).rounded_rectangle((250, 230, 790, 830), radius=70, fill=(0, 0, 40, 110))
        img = Image.alpha_composite(img, shadow.filter(ImageFilter.GaussianBlur(30)))
    back_alpha = 120 if tint else 70
    img = Image.alpha_composite(img, card(back_alpha, -12))
    img = Image.alpha_composite(img, card(back_alpha + 40, 6))
    img = Image.alpha_composite(img, card(card_alpha, 0))

    st = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    pts = []
    cx, cy, outer, inner = 520, 510, 170, 72
    for i in range(10):
        a = -math.pi / 2 + i * math.pi / 5
        r = outer if i % 2 == 0 else inner
        pts.append((cx + r * math.cos(a), cy + r * math.sin(a)))
    star_fill = (0, 0, 0, 255) if tint else star + (255,)
    ImageDraw.Draw(st).polygon(pts, fill=star_fill)
    if tint:
        # tinted icons are greyscale; the star is cut out of the front card
        img = Image.alpha_composite(img, st)
        r, g, b, a = img.split()
        gray = img.convert("L")
        img = Image.merge("RGBA", (gray, gray, gray, a))
    else:
        img = Image.alpha_composite(img, st)
    return img


def write_json(path, data):
    with open(path, "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")


def icon_set(name, images):
    folder = os.path.join(ASSETS, f"{name}.appiconset")
    os.makedirs(folder, exist_ok=True)
    entries = []
    for filename, img, appearance in images:
        img.save(os.path.join(folder, filename))
        entry = {"filename": filename, "idiom": "universal", "platform": "ios", "size": "1024x1024"}
        if appearance:
            entry["appearances"] = [{"appearance": "luminosity", "value": appearance}]
        entries.append(entry)
    write_json(os.path.join(folder, "Contents.json"), {"images": entries, "info": {"author": "xcode", "version": 1}})


def preview(name, img):
    folder = os.path.join(ASSETS, f"IconPreview-{name}.imageset")
    os.makedirs(folder, exist_ok=True)
    small = img.convert("RGB").resize((180, 180), Image.LANCZOS)
    small.save(os.path.join(folder, "preview.png"))
    write_json(os.path.join(folder, "Contents.json"), {
        "images": [{"filename": "preview.png", "idiom": "universal"}],
        "info": {"author": "xcode", "version": 1},
    })


def main():
    for name, (top, bottom, alpha, star) in VARIANTS.items():
        base = draw(top, bottom, alpha, star)
        if name == "Classic":
            dark = draw(top, bottom, alpha, star, transparent=True)
            tinted = draw(top, bottom, alpha, star, transparent=True, tint=True)
            icon_set("AppIcon", [
                ("AppIcon.png", base.convert("RGB"), None),
                ("AppIcon-Dark.png", dark, "dark"),
                ("AppIcon-Tinted.png", tinted, "tinted"),
            ])
        else:
            icon_set(f"AppIcon-{name}", [(f"AppIcon-{name}.png", base.convert("RGB"), None)])
        preview(name, base)
    print("icons written")


if __name__ == "__main__":
    main()
