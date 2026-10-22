#!/usr/bin/env python3
"""Gets the Spotify refresh token for the Arduino sketch.

Run it once on your computer (needs only Python 3, no external libraries).
The app on the Spotify developer dashboard must have the Redirect URI
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
            self.wfile.write("Done, you can close this page.".encode())

        def log_message(self, *args):
            pass

    server = http.server.HTTPServer(("127.0.0.1", 8888), Handler)
    print("Opening the browser for authorization. If it doesn't open, visit:\n" + auth_url)
    webbrowser.open(auth_url)
    while "code" not in result and "error" not in result:
        server.handle_request()
    if "error" in result:
        sys.exit("Authorization denied: " + result["error"])

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

    print("\nCopy this line into arduino_secrets.h:\n")
    print(f'#define SECRET_SPOTIFY_REFRESH_TOKEN "{tokens["refresh_token"]}"')


if __name__ == "__main__":
    main()
