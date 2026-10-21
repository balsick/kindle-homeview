#!/usr/bin/env python3
"""Genera i QR mostrati sul Kindle col tasto Home.

    python3 tools/make_qr.py

Chiede rete e password del WiFi ospiti e crea in kindle/qr/:
  wifi.png  QR per connettersi al WiFi
  app.png   QR per aprire la webapp dell'Arduino (http://ARDUINO_HOST/)
  *.raw     gli stessi QR già pronti per il framebuffer del Kindle
  info.sh   testi mostrati sotto i QR

kindle/qr/ contiene la password in chiaro: è escluso dal repository e va
copiato solo sul Kindle (in /mnt/us/dashboard/qr/).

Serve segno (pip install segno).
"""

import argparse
import getpass
import re
from pathlib import Path

import segno
import segno.helpers

ROOT = Path(__file__).resolve().parent.parent
WIFI_PX = 300  # lato massimo dei QR in pixel sullo schermo 600x800
APP_PX = 200
SCREEN_W = 600


def save_qr(qr, path, max_px):
    # Moduli interi e bordo standard di 4: QR nitido e leggibile sull'e-ink
    modules = qr.symbol_size(scale=1, border=4)[0]
    scale = max(1, max_px // modules)
    qr.save(str(path), kind="png", scale=scale, border=4)
    save_raw(qr, path.with_suffix(".raw"), scale)


def save_raw(qr, path, scale):
    """Il QR come fascia larga quanto lo schermo, un byte per pixel (255 nero,
    0 bianco), centrata: dashboard.sh la copia con dd nel framebuffer del
    Kindle, perché l'FBInk di KOReader non sa disegnare le immagini."""
    rows = []
    for row in qr.matrix_iter(scale=scale, border=4):
        line = bytes(255 if dark else 0 for dark in row)
        left = (SCREEN_W - len(line)) // 2
        rows.append(bytes(left) + line + bytes(SCREEN_W - left - len(line)))
    path.write_bytes(b"".join(rows))


def shell_quote(s):
    return "'" + s.replace("'", "'\\''") + "'"


def arduino_host_from_config():
    for name in ("config.sh", "defaults.sh"):  # la configurazione locale vince
        path = ROOT / "kindle" / name
        m = re.search(r'^ARDUINO_HOST="([^"]+)"', path.read_text(), re.M) if path.exists() else None
        if m:
            return m.group(1)
    return ""


def make(out_dir, ssid, password, security, app_url):
    out_dir.mkdir(parents=True, exist_ok=True)
    wifi = segno.helpers.make_wifi(ssid=ssid, password=password or None,
                                   security=security if password else "nopass")
    save_qr(wifi, out_dir / "wifi.png", WIFI_PX)
    save_qr(segno.make(app_url, error="m"), out_dir / "app.png", APP_PX)
    (out_dir / "info.sh").write_text(
        "# Generato da tools/make_qr.py\n"
        f"QR_WIFI_SSID={shell_quote(ssid)}\n"
        f"QR_WIFI_PASS={shell_quote(password)}\n"
        f"QR_APP_URL={shell_quote(app_url)}\n"
    )


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--ssid", help="nome della rete (se assente viene chiesto)")
    p.add_argument("--security", default="WPA", choices=["WPA", "WEP"],
                   help="WPA vale anche per WPA2/WPA3 (default: WPA)")
    p.add_argument("--app-url", help="indirizzo della webapp (default: http://ARDUINO_HOST/ da kindle/config.sh o defaults.sh)")
    p.add_argument("--out", default=ROOT / "kindle/qr", type=Path)
    args = p.parse_args()

    ssid = args.ssid or input("Rete WiFi ospiti: ").strip()
    password = getpass.getpass("Password (vuota se rete aperta): ")
    app_url = args.app_url or f"http://{arduino_host_from_config()}/"
    make(args.out, ssid, password, args.security, app_url)
    print(f"QR creati in {args.out}. Copia la cartella in /mnt/us/dashboard/qr/ sul Kindle.")


if __name__ == "__main__":
    main()
