# Jarvis uygulama ikonu ve README logosu: siyah yuvarlatılmış karede parçacık küresi (küre görünümünün aynısı).
# Kullanım: python3 scripts/make_icon.py   (Pillow gerekir)
import math, random
from PIL import Image, ImageDraw, ImageFilter

SIZE = 1024
random.seed(7)

def sphere_points(n=2600):
    golden = math.pi * (3 - math.sqrt(5))
    pts = []
    for i in range(n):
        y = 1 - (i / (n - 1)) * 2
        r = math.sqrt(1 - y * y)
        a = golden * i
        pts.append((math.cos(a) * r, y, math.sin(a) * r))
    return pts

def render(size=SIZE, rounded=True, tint=(255, 255, 255)):
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    bg = ImageDraw.Draw(img)
    if rounded:
        bg.rounded_rectangle((0, 0, size - 1, size - 1), radius=int(size * 0.225), fill=(6, 7, 10, 255))
    else:
        bg.rectangle((0, 0, size, size), fill=(6, 7, 10, 255))

    # Yumuşak hale
    halo = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    hd = ImageDraw.Draw(halo)
    R = size * 0.36
    cx = cy = size / 2
    hd.ellipse((cx - R * 1.15, cy - R * 1.15, cx + R * 1.15, cy + R * 1.15), fill=(*tint, 28))
    halo = halo.filter(ImageFilter.GaussianBlur(size * 0.06))
    img.alpha_composite(halo)

    # Parçacıklar: parlaklık kovaları (küredeki mantığın aynısı)
    layer = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    ry, rx = 0.9, 0.42
    sy, cy_, sx, cx_ = math.sin(ry), math.cos(ry), math.sin(rx), math.cos(rx)
    for (x, y, z) in sphere_points():
        wave = math.sin(x * 5.1) * math.sin(y * 3.7 + 1.3) * 0.018
        r = 1 + wave + random.uniform(-0.012, 0.012)
        x, y, z = x * r, y * r, z * r
        x1, z1 = x * cy_ + z * sy, -x * sy + z * cy_
        y2, z2 = y * cx_ - z1 * sx, y * sx + z1 * cx_
        px, py = cx + x1 * R, cy - y2 * R
        rim = 1 - min(abs(z2) / r, 1)
        depth = (z2 / r + 1) / 2
        bright = 0.07 + 0.75 * rim ** 3 + 0.18 * depth
        s = (1.1 + 2.4 * rim) * size / 300
        a = int(255 * min(bright, 1))
        d.ellipse((px - s / 2, py - s / 2, px + s / 2, py + s / 2), fill=(*tint, a))
    # Kenar parlaması için ince bir blur kopyası
    glow = layer.filter(ImageFilter.GaussianBlur(size * 0.004))
    img.alpha_composite(glow)
    img.alpha_composite(layer)
    return img

if __name__ == "__main__":
    import json, os
    icon = render()
    out = "Jarvis/Resources/Assets.xcassets/AppIcon.appiconset"
    images = []
    for pt in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            px = pt * scale
            name = f"icon_{pt}x{pt}@{scale}x.png"
            icon.resize((px, px), Image.LANCZOS).save(os.path.join(out, name))
            images.append({"filename": name, "idiom": "mac", "scale": f"{scale}x", "size": f"{pt}x{pt}"})
    json.dump({"images": images, "info": {"author": "xcode", "version": 1}}, open(os.path.join(out, "Contents.json"), "w"), indent=2)
    # README görseli: kare, köşeleri yuvarlatılmış, 512 px
    icon.resize((512, 512), Image.LANCZOS).save("docs/logo.png")
    # Geniş kapak: siyah zeminde küre + ad
    banner = Image.new("RGBA", (1600, 600), (6, 7, 10, 255))
    orb = render(560, rounded=False)
    banner.alpha_composite(orb, (60, 20))
    from PIL import ImageFont
    try:
        font = ImageFont.truetype("/System/Library/Fonts/SFNS.ttf", 150)
        sub = ImageFont.truetype("/System/Library/Fonts/SFNS.ttf", 44)
    except Exception:
        font = ImageFont.load_default(); sub = font
    bd = ImageDraw.Draw(banner)
    bd.text((700, 190), "Jarvis", font=font, fill=(240, 240, 245, 255))
    bd.text((706, 360), "Claude oturumlarına ve Mac'e sesle komut", font=sub, fill=(140, 144, 152, 255))
    banner.save("docs/banner.png")
    print("ikon + docs/logo.png + docs/banner.png üretildi")
