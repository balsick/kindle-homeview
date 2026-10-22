#!/usr/bin/env python3
"""Previews the Kindle screen on your computer.

Runs "dashboard.sh preview" with a fake FBInk that records the commands, then
redraws them into a 600x800 PNG. So the preview comes from the real code: if
you change the layout in dashboard.sh or defaults.sh, the preview follows.

    python3 tools/preview.py                      # creates preview.png
    python3 tools/preview.py --watch              # regenerates it on every change
    python3 tools/preview.py --status my.txt --lights "1:100 0:50 1:20"
    python3 tools/preview.py --screen qr          # QR screen (Home key)

Needs Pillow (pip install pillow); for the QR screen before running
make_qr.py it also needs segno, to create sample QR codes, and without
kindle/fonts/icons.ttf fonttools and Internet, to create the icons with
make_icons.py. It's an approximation: FBInk's font metrics and the 16 gray
levels of e-ink can differ by a few pixels.
"""

import argparse
import json
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parent.parent
KINDLE_DIR = ROOT / "kindle"
SCREEN_W, SCREEN_H = 600, 800
FONT_DIRS = [
    KINDLE_DIR / "fonts",
    Path("/usr/share/fonts/truetype/dejavu"),
    Path.home() / "Library/Fonts",
    Path("/Library/Fonts"),
    Path("C:/Windows/Fonts"),
]


def record_commands(status, lights, screen):
    """Runs dashboard.sh preview and returns the FBInk commands, one list each."""
    with tempfile.TemporaryDirectory() as tmp:
        qr_dir = KINDLE_DIR / "qr"
        if screen == "qr" and not (qr_dir / "wifi.png").exists():
            # Sample QR codes, so kindle/qr/ stays untouched
            import make_qr
            qr_dir = Path(tmp) / "qr"
            make_qr.make(qr_dir, "Casa-Ospiti", "benvenuti2026", "WPA", "http://192.168.1.60/")
        icons = KINDLE_DIR / "fonts/icons.ttf"
        if not icons.exists():
            import make_icons
            icons = Path(tmp) / "icons.ttf"
            make_icons.make(icons)
        log = Path(tmp) / "fbink.log"
        shim = Path(tmp) / "fbink"
        shim.write_text(
            f"#!{sys.executable}\n"
            "import json, sys\n"
            f"open({str(log)!r}, 'a').write(json.dumps(sys.argv[1:]) + '\\n')\n"
        )
        shim.chmod(0o755)
        env = dict(os.environ, RUN=str(Path(tmp) / "run"), PREVIEW_FBINK=str(shim), QR_DIR=str(qr_dir),
                   PREVIEW_ICONS=str(icons))
        subprocess.run(["sh", str(KINDLE_DIR / "dashboard.sh"), "preview", str(status), lights, screen],
                       env=env, check=True)
        # Images must be read while the temporary folder still exists
        commands = [json.loads(line) for line in log.read_text().splitlines()]
        commands = [load_images(c) for c in commands]
        for c in commands:   # the icon font may be in the temporary folder too
            if "-t" in c:
                spec = parse_spec(c[c.index("-t") + 1])
                load_font(spec["regular"], int(spec["px"]))
        return commands


def load_images(args):
    """Replaces the path after -g with the already loaded image."""
    if "-g" in args:
        i = args.index("-g") + 1
        spec = parse_spec(args[i])
        img = Image.open(spec["file"]).convert("L")
        img.load()
        args = args[:i] + [(spec, img)] + args[i + 1:]
    return args


def parse_spec(spec):
    return dict(item.split("=", 1) for item in spec.split(",") if "=" in item)


fonts = {}
GRAYS = {"BLACK": 0x00, "WHITE": 0xFF, **{f"GRAY{d:X}": d * 0x11 for d in range(1, 15)}}


def load_font(path, px):
    """Like FBInk (stb_truetype's ScaleForPixelHeight), px is the height from
    the ascender to the descender, not the em size Pillow uses."""
    key = (Path(path).name, px)
    if key not in fonts:
        for f in [Path(path)] + [d / key[0] for d in FONT_DIRS]:
            if f.exists():
                ascent, descent = ImageFont.truetype(str(f), 1000).getmetrics()
                fonts[key] = ImageFont.truetype(str(f), round(px * 1000 / (ascent + descent)))
                break
        else:
            sys.exit(f"Font {key[0]} not found: copy it into {KINDLE_DIR / 'fonts'}")
    return fonts[key]


def draw_text(draw, spec, text, centered, fg, bg):
    font = load_font(spec["regular"], int(spec["px"]))
    left = int(spec.get("left", 0))
    box_w = SCREEN_W - left - int(spec.get("right", 0))
    # Like FBInk: a single line, truncated with "…" if it doesn't fit
    if draw.textlength(text, font=font) > box_w:
        while text and draw.textlength(text + "…", font=font) > box_w:
            text = text[:-1]
        text += "…"
    x = left
    width = draw.textlength(text, font=font)
    if centered:
        x += (box_w - width) / 2
    top = int(spec.get("top", 0))
    if bg is not None:   # without -O FBInk paints the background behind the line
        draw.rectangle((x, top, x + width - 1, top + int(spec["px"]) - 1), fill=bg)
    draw.text((x, top), text, font=font, fill=fg, anchor="la")


def render(commands):
    img = Image.new("L", (SCREEN_W, SCREEN_H), 255)
    draw = ImageDraw.Draw(img)
    for args in commands:
        flags, values, text = set(), {}, []
        it = iter(args)
        for a in it:
            if a in ("-k", "-s", "-t", "-g", "-B", "-C"):
                values[a] = next(it, "")
            elif a.startswith("-"):
                flags.add(a)
            else:
                text.append(a)
        if "-c" in flags:
            draw.rectangle((0, 0, SCREEN_W, SCREEN_H), fill=255)
        if "-k" in values:
            r = {k: int(v) for k, v in parse_spec(values["-k"]).items()}
            fill = GRAYS.get(values.get("-B", "WHITE").upper(), 255)
            draw.rectangle((r["left"], r["top"], r["left"] + r["width"] - 1, r["top"] + r["height"] - 1), fill=fill)
        if "-g" in values:
            spec, image = values["-g"]
            x = (SCREEN_W - image.width) // 2 if spec.get("halign", "").upper() == "CENTER" else int(spec.get("x", 0))
            img.paste(image, (x, int(spec.get("y", 0))))
        if "-t" in values:
            bg = None if "-O" in flags else GRAYS.get(values.get("-B", "WHITE").upper(), 255)
            fg = GRAYS.get(values.get("-C", "BLACK").upper(), 0)
            draw_text(draw, parse_spec(values["-t"]), " ".join(text), "-m" in flags, fg, bg)
    return img


def build(args):
    img = render(record_commands(args.status, args.lights, args.screen))
    img.save(args.out)
    print(f"{time.strftime('%H:%M:%S')}  preview saved to {args.out}")


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--status", default=ROOT / "tools/sample_status.txt", type=Path,
                   help="state file like the one returned by the Arduino's /status")
    p.add_argument("--lights", default="1:60 1:30 0:50",
                   help='light states as "on:brightness" (default: "1:60 1:30 0:50")')
    p.add_argument("--screen", default="main", choices=["main", "qr"],
                   help="main screen or the QR screen (Home key)")
    p.add_argument("--out", type=Path, help="default: preview.png, or preview-qr.png with --screen qr")
    p.add_argument("--watch", action="store_true", help="regenerate when scripts, config or state change")
    args = p.parse_args()
    args.out = args.out or ROOT / ("preview-qr.png" if args.screen == "qr" else "preview.png")

    build(args)
    if not args.watch:
        return
    watched = [KINDLE_DIR / "dashboard.sh", KINDLE_DIR / "defaults.sh", KINDLE_DIR / "config.sh",
               KINDLE_DIR / "qr/info.sh", args.status]
    mtime = lambda f: f.stat().st_mtime if f.exists() else 0
    last = [mtime(f) for f in watched]
    while True:
        time.sleep(0.5)
        now = [mtime(f) for f in watched]
        if now != last:
            last = now
            try:
                build(args)
            except (subprocess.CalledProcessError, SystemExit) as e:
                print(f"error: {e}")


if __name__ == "__main__":
    main()
