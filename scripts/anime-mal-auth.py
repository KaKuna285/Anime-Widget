#!/usr/bin/env python3

import json
import os
import secrets
import threading
import time
import urllib.parse
import urllib.request
import webbrowser
from http.server import BaseHTTPRequestHandler, HTTPServer

CONFIG = os.path.expanduser("~/.config/anime-todo/mal.conf")
TOKEN_FILE = os.path.expanduser("~/.config/anime-todo/mal-token.json")

AUTH_URL = "https://myanimelist.net/v1/oauth2/authorize"
TOKEN_URL = "https://myanimelist.net/v1/oauth2/token"

REDIRECT_URI = "http://localhost:8080/callback"


def load_client_id():
    with open(CONFIG, "r", encoding="utf-8") as f:
        for line in f:
            if line.startswith("CLIENT_ID="):
                return line.strip().split("=", 1)[1]

    raise RuntimeError("CLIENT_ID not found in mal.conf")


client_id = load_client_id()

# MAL uses plain PKCE
code_verifier = secrets.token_urlsafe(64)[:100]
code_challenge = code_verifier


state = secrets.token_urlsafe(32)

callback_code = None
callback_error = None


class CallbackHandler(BaseHTTPRequestHandler):

    def do_GET(self):
        global callback_code, callback_error

        parsed = urllib.parse.urlparse(self.path)

        if parsed.path != "/callback":
            self.send_response(404)
            self.end_headers()
            return

        params = urllib.parse.parse_qs(parsed.query)

        if "error" in params:
            callback_error = params["error"][0]

            self.send_response(400)
            self.end_headers()
            self.wfile.write(
                b"Authorization failed. You can close this window."
            )
            return

        received_state = params.get("state", [None])[0]

        if received_state != state:
            callback_error = "Invalid OAuth state"

            self.send_response(400)
            self.end_headers()
            self.wfile.write(
                b"Invalid OAuth state. You can close this window."
            )
            return

        callback_code = params.get("code", [None])[0]

        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.end_headers()

        self.wfile.write(
            b"""
            <html>
            <body>
            <h2>Anime Checklist authorization successful!</h2>
            <p>You can close this window and return to the terminal.</p>
            </body>
            </html>
            """
        )

    def log_message(self, format, *args):
        pass


def exchange_code():
    data = urllib.parse.urlencode({
        "client_id": client_id,
        "code": callback_code,
        "code_verifier": code_verifier,
        "grant_type": "authorization_code",
        "redirect_uri": REDIRECT_URI,
    }).encode()

    request = urllib.request.Request(
        TOKEN_URL,
        data=data,
        headers={
            "Content-Type": "application/x-www-form-urlencoded"
        },
    )

    try:
        with urllib.request.urlopen(request) as response:
            return json.load(response)
    except urllib.error.HTTPError as e:
        error_body = e.read().decode("utf-8", errors="replace")
        print()
        print("MAL token endpoint returned an error:")
        print(error_body)
        raise


server = HTTPServer(("localhost", 8080), CallbackHandler)

thread = threading.Thread(
    target=server.serve_forever,
    daemon=True
)
thread.start()

params = {
    "response_type": "code",
    "client_id": client_id,
    "redirect_uri": REDIRECT_URI,
    "code_challenge": code_challenge,
    "code_challenge_method": "plain",
    "state": state,
}

url = AUTH_URL + "?" + urllib.parse.urlencode(params)

print("Opening MyAnimeList authorization page...")
print()
print(url)
print()

webbrowser.open(url)

print("Waiting for authorization...")
print("Authorize Anime Checklist in your browser.")

while callback_code is None and callback_error is None:
    time.sleep(0.2)

server.shutdown()

if callback_error:
    raise RuntimeError(
        f"MyAnimeList authorization failed: {callback_error}"
    )

print("Authorization code received.")
print("Exchanging code for tokens...")

tokens = exchange_code()

os.makedirs(os.path.dirname(TOKEN_FILE), exist_ok=True)

with open(TOKEN_FILE, "w", encoding="utf-8") as f:
    json.dump(tokens, f, indent=2)
    f.write("\n")

os.chmod(TOKEN_FILE, 0o600)

print()
print("MyAnimeList authorization successful!")
print(f"Token saved to: {TOKEN_FILE}")
