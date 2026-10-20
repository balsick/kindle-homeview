#!/usr/bin/env python3
"""Ottiene il refresh token Spotify per lo sketch Arduino.

Da eseguire una volta sul PC (serve solo Python 3, nessuna libreria esterna).
Nell'app sul developer dashboard di Spotify deve esserci il Redirect URI
http://127.0.0.1:8888/callback
"""

import base64
import getpass
import http.server
import json
import secrets
import sys
import urllib.parse
import urllib.request
import webbrowser

REDIRECT_URI = "http://127.0.0.1:8888/callback"
SCOPES = "user-read-playback-state user-read-currently-playing user-modify-playback-state"


def main():
    client_id = input("Client ID: ").strip()
    client_secret = getpass.getpass("Client Secret: ").strip()
    state = secrets.token_urlsafe(16)
    auth_url = "https://accounts.spotify.com/authorize?" + urllib.parse.urlencode({
        "client_id": client_id,
        "response_type": "code",
        "redirect_uri": REDIRECT_URI,
        "scope": SCOPES,
        "state": state,
    })

    result = {}

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            query = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
            if query.get("state", [""])[0] == state:
                result.update({k: v[0] for k, v in query.items()})
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.end_headers()
            self.wfile.write("Fatto, puoi chiudere questa pagina.".encode())

        def log_message(self, *args):
            pass

    server = http.server.HTTPServer(("127.0.0.1", 8888), Handler)
    print("Apro il browser per l'autorizzazione. Se non si apre, visita:\n" + auth_url)
    webbrowser.open(auth_url)
    while "code" not in result and "error" not in result:
        server.handle_request()
    if "error" in result:
        sys.exit("Autorizzazione negata: " + result["error"])

    credentials = base64.b64encode(f"{client_id}:{client_secret}".encode()).decode()
    request = urllib.request.Request(
        "https://accounts.spotify.com/api/token",
        data=urllib.parse.urlencode({
            "grant_type": "authorization_code",
            "code": result["code"],
            "redirect_uri": REDIRECT_URI,
        }).encode(),
        headers={
            "Authorization": "Basic " + credentials,
            "Content-Type": "application/x-www-form-urlencoded",
        },
    )
    with urllib.request.urlopen(request) as response:
        tokens = json.load(response)

    print("\nCopia questa riga in arduino_secrets.h:\n")
    print(f'#define SPOTIFY_REFRESH_TOKEN "{tokens["refresh_token"]}"')


if __name__ == "__main__":
    main()
