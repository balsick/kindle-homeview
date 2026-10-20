#!/usr/bin/env python3
"""Anteprima sul PC della schermata del Kindle.

Esegue "dashboard.sh preview" con un finto FBInk che registra i comandi, poi
li ridisegna in un PNG 600x800. L'anteprima viene quindi dal codice vero: se
modifichi il layout in dashboard.sh o config.sh, cambia anche lei.

    python3 tools/preview.py                      # crea preview.png
    python3 tools/preview.py --watch              # la rigenera a ogni modifica
    python3 tools/preview.py --status mio.txt --lights "1:100 0:50 1:20"
    python3 tools/preview.py --screen qr          # schermata dei QR (tasto Home)

Serve Pillow (pip install pillow); per la schermata QR senza aver ancora
eseguito make_qr.py serve anche segno, per creare QR di esempio. È un'approssimazione: le metriche dei font
di FBInk e i 16 livelli di grigio dell'e-ink possono differire di qualche pixel.
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
    """Esegue dashboard.sh preview e restituisce i comandi FBInk, uno per lista."""
    with tempfile.TemporaryDirectory() as tmp:
        qr_dir = KINDLE_DIR / "qr"
        if screen == "qr" and not (qr_dir / "wifi.png").exists():
            # QR di esempio, per non toccare kindle/qr/
            import make_qr
            qr_dir = Path(tmp) / "qr"
            make_qr.make(qr_dir, "Casa-Ospiti", "benvenuti2026", "WPA", "http://192.168.1.60/")
        log = Path(tmp) / "fbink.log"
        shim = Path(tmp) / "fbink"
        shim.write_text(
            f"#!{sys.executable}\n"
            "import json, sys\n"
            f"open({str(log)!r}, 'a').write(json.dumps(sys.argv[1:]) + '\\n')\n"
        )
        shim.chmod(0o755)
        env = dict(os.environ, RUN=str(Path(tmp) / "run"), PREVIEW_FBINK=str(shim), QR_DIR=str(qr_dir))
        subprocess.run(["sh", str(KINDLE_DIR / "dashboard.sh"), "preview", str(status), lights, screen],
                       env=env, check=True)
        # Le immagini vanno lette finché la cartella temporanea esiste
        commands = [json.loads(line) for line in log.read_text().splitlines()]
        return [load_images(c) for c in commands]


def load_images(args):
    """Sostituisce il percorso dopo -g con l'immagine già caricata."""
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


def load_font(path, px):
    key = (Path(path).name, px)
    if key not in fonts:
        for d in FONT_DIRS:
            if (d / key[0]).exists():
                fonts[key] = ImageFont.truetype(str(d / key[0]), px)
                break
        else:
            sys.exit(f"Font {key[0]} non trovato: copialo in {KINDLE_DIR / 'fonts'}")
    return fonts[key]


def draw_text(draw, spec, text, centered):
    font = load_font(spec["regular"], int(spec["px"]))
    left = int(spec.get("left", 0))
    box_w = SCREEN_W - left - int(spec.get("right", 0))
    # Come FBInk: una riga sola, troncata con "…" se non ci sta
    if draw.textlength(text, font=font) > box_w:
        while text and draw.textlength(text + "…", font=font) > box_w:
            text = text[:-1]
        text += "…"
    x = left
    if centered:
        x += (box_w - draw.textlength(text, font=font)) / 2
    draw.text((x, int(spec.get("top", 0))), text, font=font, fill=0, anchor="la")


def render(commands):
    img = Image.new("L", (SCREEN_W, SCREEN_H), 255)
    draw = ImageDraw.Draw(img)
    for args in commands:
        flags, values, text = set(), {}, []
        it = iter(args)
        for a in it:
            if a in ("-k", "-s", "-t", "-g", "-B"):
                values[a] = next(it, "")
            elif a.startswith("-"):
                flags.add(a)
            else:
                text.append(a)
        if "-c" in flags:
            draw.rectangle((0, 0, SCREEN_W, SCREEN_H), fill=255)
        if "-k" in values:
            r = {k: int(v) for k, v in parse_spec(values["-k"]).items()}
            fill = 0 if values.get("-B", "").upper() == "BLACK" else 255
            draw.rectangle((r["left"], r["top"], r["left"] + r["width"] - 1, r["top"] + r["height"] - 1), fill=fill)
        if "-g" in values:
            spec, image = values["-g"]
            x = (SCREEN_W - image.width) // 2 if spec.get("halign", "").upper() == "CENTER" else int(spec.get("x", 0))
            img.paste(image, (x, int(spec.get("y", 0))))
        if "-t" in values:
            draw_text(draw, parse_spec(values["-t"]), " ".join(text), "-m" in flags)
    return img


def build(args):
    img = render(record_commands(args.status, args.lights, args.screen))
    img.save(args.out)
    print(f"{time.strftime('%H:%M:%S')}  anteprima salvata in {args.out}")


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--status", default=ROOT / "tools/sample_status.txt", type=Path,
                   help="file di stato come quello restituito da /status dell'Arduino")
    p.add_argument("--lights", default="1:60 1:30 0:50",
                   help='stato delle luci "accesa:luminosità" (default: "1:60 1:30 0:50")')
    p.add_argument("--screen", default="main", choices=["main", "qr"],
                   help="schermata principale o quella dei QR (tasto Home)")
    p.add_argument("--out", type=Path, help="default: preview.png, o preview-qr.png con --screen qr")
    p.add_argument("--watch", action="store_true", help="rigenera quando cambiano script, config o stato")
    args = p.parse_args()
    args.out = args.out or ROOT / ("preview-qr.png" if args.screen == "qr" else "preview.png")

    build(args)
    if not args.watch:
        return
    watched = [KINDLE_DIR / "dashboard.sh", KINDLE_DIR / "config.sh", args.status]
    if (KINDLE_DIR / "qr/info.sh").exists():
        watched.append(KINDLE_DIR / "qr/info.sh")
    last = [f.stat().st_mtime for f in watched]
    while True:
        time.sleep(0.5)
        now = [f.stat().st_mtime for f in watched]
        if now != last:
            last = now
            try:
                build(args)
            except (subprocess.CalledProcessError, SystemExit) as e:
                print(f"errore: {e}")


if __name__ == "__main__":
    main()
