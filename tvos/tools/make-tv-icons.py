#!/usr/bin/env python3
"""Builds the tvOS "App Icon & Top Shelf Image" brand assets from the MeloNX iOS icon.

tvOS icons are layered (parallax) images. Back layer: the icon's purple→red
gradient. Front layer: the two Joy-Cons cut out of the icon (pixels that differ
from the gradient keep their colour, the rest become transparent).

Usage: make-tv-icons.py <MeloNX source icon 1024 png> <output Assets.xcassets dir>
"""
import json, os, sys
from PIL import Image, ImageFilter

src_path, out = sys.argv[1], sys.argv[2]
icon = Image.open(src_path).convert('RGB')
W, H = icon.size
px = icon.load()
corners = [px[8, 8], px[W - 9, 8], px[8, H - 9], px[W - 9, H - 9]]

def bg(x, y):
    u, v = x / (W - 1), y / (H - 1)
    return tuple(int((1-u)*(1-v)*a + u*(1-v)*b + (1-u)*v*c + u*v*d)
                 for a, b, c, d in zip(*corners))

# Front: the emblem with the gradient keyed out
front = Image.new('RGBA', (W, H))
fp = front.load()
for y in range(H):
    for x in range(W):
        r, g, b = px[x, y]
        br, bgc, bb = bg(x, y)
        d = abs(r - br) + abs(g - bgc) + abs(b - bb)
        a = 0 if d < 40 else (255 if d > 90 else int((d - 40) * 255 / 50))
        fp[x, y] = (r, g, b, a)
front = front.crop(front.getbbox())

def gradient(size):
    w, h = size
    img = Image.new('RGB', (w, h))
    p = img.load()
    for y in range(h):
        for x in range(w):
            p[x, y] = bg(x * (W - 1) / max(w - 1, 1), y * (H - 1) / max(h - 1, 1))
    return img.filter(ImageFilter.GaussianBlur(radius=max(w, h) / 200))

def front_layer(size, scale=0.78):
    w, h = size
    img = Image.new('RGBA', (w, h), (0, 0, 0, 0))
    fh = int(h * scale)
    fw = int(front.width * fh / front.height)
    img.alpha_composite(front.resize((fw, fh), Image.LANCZOS), ((w - fw) // 2, (h - fh) // 2))
    return img

def write_json(path, obj):
    os.makedirs(path, exist_ok=True)
    with open(os.path.join(path, 'Contents.json'), 'w') as f:
        json.dump(obj, f, indent=2)

info = {'author': 'xcode', 'version': 1}
brand = os.path.join(out, 'App Icon & Top Shelf Image.brandassets')

def imagestack(name, base, scales):
    stack = os.path.join(brand, name + '.imagestack')
    write_json(stack, {'info': info, 'layers': [{'filename': 'Front.imagestacklayer'}, {'filename': 'Back.imagestacklayer'}]})
    for layer, make in (('Front', front_layer), ('Back', gradient)):
        ldir = os.path.join(stack, layer + '.imagestacklayer')
        write_json(ldir, {'info': info})
        cdir = os.path.join(ldir, 'Content.imageset')
        images = []
        for s in scales:
            fn = f'{layer.lower()}@{s}x.png'
            make((base[0] * s, base[1] * s)).save(os.path.join(cdir, fn)) if os.makedirs(cdir, exist_ok=True) is None else None
            images.append({'filename': fn, 'idiom': 'tv', 'scale': f'{s}x'})
        write_json(cdir, {'images': images, 'info': info})

def topshelf(name, base):
    d = os.path.join(brand, name + '.imageset')
    os.makedirs(d, exist_ok=True)
    images = []
    for s in (1, 2):
        size = (base[0] * s, base[1] * s)
        img = gradient(size).convert('RGBA')
        img.alpha_composite(front_layer(size, 0.7))
        fn = f'topshelf@{s}x.png'
        img.convert('RGB').save(os.path.join(d, fn))
        images.append({'filename': fn, 'idiom': 'tv', 'scale': f'{s}x'})
    write_json(d, {'images': images, 'info': info})

write_json(out, {'info': info})
imagestack('App Icon', (400, 240), (1, 2))
imagestack('App Icon - App Store', (1280, 768), (1,))
topshelf('Top Shelf Image', (1920, 720))
topshelf('Top Shelf Image Wide', (2320, 720))
write_json(brand, {'info': info, 'assets': [
    {'filename': 'App Icon - App Store.imagestack', 'idiom': 'tv', 'role': 'primary-app-icon', 'size': '1280x768'},
    {'filename': 'App Icon.imagestack', 'idiom': 'tv', 'role': 'primary-app-icon', 'size': '400x240'},
    {'filename': 'Top Shelf Image Wide.imageset', 'idiom': 'tv', 'role': 'top-shelf-image-wide', 'size': '2320x720'},
    {'filename': 'Top Shelf Image.imageset', 'idiom': 'tv', 'role': 'top-shelf-image', 'size': '1920x720'},
]})
print('wrote', out)
