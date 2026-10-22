#!/usr/bin/env python3
"""Creates kindle/fonts/icons.ttf, the icon font used by the panel.

The icons come from Material Design Icons (Pictogrammers, Apache License
2.0). Only the ones the panel uses are kept, and each one is moved onto a
plain ASCII character: the Kindle's BusyBox and FBInk then only ever see
letters and digits, and the font is a few KB instead of 1.3 MB (FBInk reloads
it on every call).

The list of icons is the "I_name=char  # mdi-name" table in
kindle/dashboard.sh, so there's a single source of truth: after changing it,
run this again and commit kindle/icons-font.sh.

Besides the font, it writes kindle/icons-font.sh: the same font as printf
commands, which travels with OTA updates (they only carry text). On start
dashboard.sh rewrites fonts/icons.ttf from it when it changes, so the font
never needs to be copied to the Kindle by hand.

    python3 tools/make_icons.py                 # downloads MDI from jsDelivr
    python3 tools/make_icons.py --mdi DIR       # uses an already downloaded @mdi/font

Needs fonttools (pip install fonttools).
"""

import argparse
import hashlib
import logging
import re
import sys
import urllib.request
from pathlib import Path

from fontTools import subset
from fontTools.ttLib import TTFont
from fontTools.ttLib.tables._c_m_a_p import CmapSubtable

ROOT = Path(__file__).resolve().parent.parent
MDI_VERSION = "7.4.47"
MDI_URL = f"https://cdn.jsdelivr.net/npm/@mdi/font@{MDI_VERSION}/"
SHELL_FONT = ROOT / "kindle/icons-font.sh"
TABLE = re.compile(r"^I_(\w+)=(\S)\s+#\s*([a-z0-9-]+)\s*$")


def icon_table(script):
    """[(name, char, mdi_name)] from the table in dashboard.sh"""
    icons = [m.groups() for line in script.read_text().splitlines() if (m := TABLE.match(line))]
    chars = [c for _, c, _ in icons]
    dup = {c for c in chars if chars.count(c) > 1}
    if dup:
        sys.exit(f"Characters used twice in the icon table: {' '.join(sorted(dup))}")
    return icons


def fetch(mdi_dir, rel):
    if mdi_dir:
        return (Path(mdi_dir) / rel).read_bytes()
    with urllib.request.urlopen(MDI_URL + rel) as r:
        return r.read()


def make(out, script=ROOT / "kindle/dashboard.sh", mdi_dir=None):
    icons = icon_table(script)
    css = fetch(mdi_dir, "css/materialdesignicons.css").decode()
    codepoints = dict(re.findall(r'\.mdi-([a-z0-9-]+)::before \{\s*content: "\\([0-9A-F]+)"', css))

    tmp = Path(out).with_suffix(".full.ttf")
    tmp.parent.mkdir(parents=True, exist_ok=True)
    tmp.write_bytes(fetch(mdi_dir, "fonts/materialdesignicons-webfont.ttf"))
    font = TTFont(str(tmp))
    tmp.unlink()
    best = font.getBestCmap()

    mapping = {}
    for name, char, mdi in icons:
        if mdi not in codepoints:
            sys.exit(f"I_{name}: there's no '{mdi}' icon in MDI {MDI_VERSION}")
        mapping[ord(char)] = best[int(codepoints[mdi], 16)]

    # A single format 4 cmap (Windows, BMP): it's what stb_truetype in FBInk reads
    table = CmapSubtable.newSubtable(4)
    table.platformID, table.platEncID, table.language = 3, 1, 0
    table.cmap = mapping
    font["cmap"].tables = [table]

    options = subset.Options()
    options.layout_features = []
    options.name_IDs = ["*"]   # keeps the copyright and license notices
    subsetter = subset.Subsetter(options)
    subsetter.populate(unicodes=mapping.keys())
    subsetter.subset(font)
    font.save(str(out))
    return len(mapping)


def write_shell(ttf, sh):
    """The font as printf commands, every byte in octal (no "%" or quoting
    issues, and NUL bytes work with any printf)."""
    data = Path(ttf).read_bytes()
    lines = [
        "#!/bin/sh",
        "# The panel's icon font (fonts/icons.ttf) as printf commands, so it can",
        "# travel with OTA updates, which only carry text: dashboard.sh writes the",
        "# font when the id below changes. Made by tools/make_icons.py, don't edit.",
        "# Icons: Material Design Icons by Pictogrammers, Apache License 2.0.",
        f"# id: {hashlib.sha1(data).hexdigest()[:12]} {len(data)}",
    ]
    for i in range(0, len(data), 200):
        lines.append("printf '" + "".join(f"\\{b:03o}" for b in data[i:i + 200]) + "'")
    lines.append("# ota:end")
    Path(sh).write_text("\n".join(lines) + "\n")


def main():
    logging.getLogger("fontTools").setLevel(logging.ERROR)   # MDI's harmless warnings
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--mdi", help="folder of an @mdi/font package (with css/ and fonts/) instead of downloading it")
    p.add_argument("--out", type=Path, default=ROOT / "kindle/fonts/icons.ttf")
    args = p.parse_args()
    n = make(args.out, mdi_dir=args.mdi)
    write_shell(args.out, SHELL_FONT)
    print(f"{n} icons saved to {args.out} ({args.out.stat().st_size // 1024} KB)")
    print(f"and to {SHELL_FONT.relative_to(ROOT)}: commit it, OTA updates bring it to the Kindle.")


if __name__ == "__main__":
    main()
