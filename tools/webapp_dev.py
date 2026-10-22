#!/usr/bin/env python3
"""Previews the webapp in your computer's browser, with fake APIs.

    python3 tools/webapp_dev.py          # then open http://localhost:8000/

Serves the page in arduino/kindle_gateway/webapp.h, re-read on every request:
edit webapp.h and reload the browser. Lights and Spotify are simulated in
memory, so the controls respond as they do on the Arduino.
"""

import argparse
import json
import re
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

WEBAPP_H = Path(__file__).resolve().parent.parent / "arduino/kindle_gateway/webapp.h"

state = {
    "lights": [
        {"name": "Soggiorno", "on": True, "b": 60},
        {"name": "Cucina", "on": True, "b": 30},
        {"name": "Studio", "on": False, "b": 50},
    ],
    "sp": {"ok": True, "active": True, "playing": True, "track": "Bohemian Rhapsody - Remastered 2011",
           "artist": "Queen", "progress": 134, "duration": 354},
    "started": time.time(),
    "ota": {"configured": True, "kindle": "kindle-v2", "latest": "kindle-v3"},
}


def webapp_html():
    m = re.search(r'R"html\((.*)\)html"', WEBAPP_H.read_text(), re.S)
    return m.group(1)


def api_state():
    sp = dict(state["sp"])
    if sp["playing"]:
        sp["progress"] = min(sp["duration"], sp["progress"] + int(time.time() - state["started"]))
    return {
        "time": time.strftime("%H:%M"),
        "date": "martedì 20 ottobre",
        "w": {"ok": True, "temp": "17,4", "desc": "Pioggia"},
        "lights": state["lights"],
        "sp": sp,
        "ota": state["ota"],
    }


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        url = urllib.parse.urlparse(self.path)
        q = {k: v[0] for k, v in urllib.parse.parse_qs(url.query).items()}
        if url.path == "/":
            self.reply(200, webapp_html(), "text/html; charset=utf-8")
        elif url.path == "/api/state":
            self.reply(200, json.dumps(api_state()), "application/json")
        elif url.path == "/api/light":
            light = state["lights"][int(q["i"])]
            light["on"] = q.get("on") == "1"
            if light["on"]:
                light["b"] = max(1, min(100, int(q.get("b", light["b"]))))
            self.reply(200, "ok\n")
        elif url.path == "/api/ota":
            state["ota"]["kindle"] = state["ota"]["latest"]  # as if the Kindle had updated
            self.reply(200, "ok\n")
        elif url.path in ("/api/cmd", "/cmd"):
            a, sp = q.get("a"), state["sp"]
            if a == "toggle":
                sp["playing"] = not sp["playing"]
            elif a in ("next", "prev"):
                sp["progress"], state["started"] = 0, time.time()
            self.reply(200, "ok\n")
        else:
            self.reply(404, "not found\n")

    def reply(self, code, body, ctype="text/plain; charset=utf-8"):
        data = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, fmt, *args):
        print(self.address_string(), fmt % args)


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--port", type=int, default=8000)
    args = p.parse_args()
    print(f"Webapp at http://localhost:{args.port}/ (Ctrl+C to quit)")
    ThreadingHTTPServer(("127.0.0.1", args.port), Handler).serve_forever()


if __name__ == "__main__":
    main()
