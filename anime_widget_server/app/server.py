#!/usr/bin/env python3
"""Anime-Widget server: HTTP API + (later) the mobile web app.

Stdlib only, so the add-on image needs nothing beyond python3.

Auth: requests arriving through Home Assistant ingress (from the
Supervisor's proxy at 172.30.32.2) are already authenticated by HA.
Everything else must send "Authorization: Bearer <api token>".
"""

import hmac
import json
import os
import secrets
import sys
import threading
import traceback
import urllib.parse
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from mal import MalClient, MalError  # noqa: E402
from ops import OpError, Ops  # noqa: E402
from store import Store  # noqa: E402

VERSION = "0.1.2"
DATA_DIR = os.environ.get("DATA_DIR", "/data")
OPTIONS_FILE = os.environ.get("OPTIONS_FILE", os.path.join(DATA_DIR, "options.json"))
PORT = int(os.environ.get("PORT", "8099"))
INGRESS_PROXY_IP = "172.30.32.2"
WEB_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "web")
LOG_FILE = os.path.join(DATA_DIR, "anime-server.log")
LOG_MAX_BYTES = 1_000_000
LOG_KEEP_LINES = 500
WAIT_MAX_SECONDS = 55

_log_lock = threading.Lock()


def log(message):
    line = f"[{datetime.now().isoformat(timespec='seconds')}] {message}"
    print(line, flush=True)

    with _log_lock:
        try:
            if os.path.exists(LOG_FILE) and os.path.getsize(LOG_FILE) > LOG_MAX_BYTES:
                with open(LOG_FILE, "r", encoding="utf-8") as f:
                    lines = f.readlines()
                with open(LOG_FILE, "w", encoding="utf-8") as f:
                    f.writelines(lines[-LOG_KEEP_LINES:])

            with open(LOG_FILE, "a", encoding="utf-8") as f:
                f.write(line + "\n")
        except OSError:
            pass


def load_options():
    try:
        with open(OPTIONS_FILE, "r", encoding="utf-8") as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return {}


def resolve_api_token(options):
    """Use the configured token, or generate and persist one."""
    token = (options.get("api_token") or "").strip()

    if token:
        return token

    path = os.path.join(DATA_DIR, "api-token")

    if os.path.exists(path):
        with open(path, "r", encoding="utf-8") as f:
            token = f.read().strip()

    if not token:
        token = secrets.token_urlsafe(32)

        with open(path, "w", encoding="utf-8") as f:
            f.write(token)

        os.chmod(path, 0o600)
        log("Generated a new API token (see the add-on's web page).")

    return token


os.makedirs(DATA_DIR, exist_ok=True)
OPTIONS = load_options()
API_TOKEN = resolve_api_token(OPTIONS)
STORE = Store(os.path.join(DATA_DIR, "anime.db"))
MAL = MalClient(DATA_DIR, (OPTIONS.get("mal_client_id") or "").strip(), log)
OPS = Ops(STORE, MAL, log)


class Handler(BaseHTTPRequestHandler):
    server_version = f"AnimeWidget/{VERSION}"
    protocol_version = "HTTP/1.1"

    # ---- helpers --------------------------------------------------

    def log_message(self, fmt, *args):
        pass  # keep the add-on log readable; ops log what matters

    def _is_ingress(self):
        return self.client_address[0] == INGRESS_PROXY_IP

    def _authorized(self):
        if self._is_ingress():
            return True

        header = self.headers.get("Authorization", "")

        if header.startswith("Bearer "):
            return hmac.compare_digest(header[7:].strip(), API_TOKEN)

        return False

    def _send(self, status, body, content_type="application/json; charset=utf-8"):
        if not isinstance(body, (bytes, bytearray)):
            body = json.dumps(body, ensure_ascii=False).encode("utf-8")

        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _json_body(self):
        length = int(self.headers.get("Content-Length") or 0)

        if not length:
            return {}

        try:
            return json.loads(self.rfile.read(length).decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as e:
            raise OpError(f"Invalid JSON body: {e}")

    def _route(self, method):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path.rstrip("/") or "/"
        query = {k: v[-1] for k, v in urllib.parse.parse_qs(parsed.query).items()}

        if path == "/api/health":
            return self._send(200, {"ok": True, "version": VERSION, "rev": STORE.rev})

        if not path.startswith("/api/"):
            return self._static(path)

        if not self._authorized():
            return self._send(401, {"error": "Unauthorized -- check API_TOKEN in server.conf."})

        handler = ROUTES.get((method, path))

        if handler is None:
            return self._send(404, {"error": f"No such endpoint: {method} {path}"})

        try:
            body = self._json_body() if method == "POST" else {}
            result = handler(self, body, query)
            self._send(200, result)
        except OpError as e:
            self._send(e.status, {"error": str(e)})
        except MalError as e:
            self._send(502, {"error": str(e)})
        except Exception as e:
            log(f"Unhandled error on {method} {path}: {e}\n{traceback.format_exc()}")
            self._send(500, {"error": f"Server error: {e}"})

    def _static(self, path):
        if path == "/":
            path = "/index.html"

        rel = os.path.normpath(path.lstrip("/"))

        if rel.startswith(".."):
            return self._send(404, {"error": "Not found"})

        full = os.path.join(WEB_DIR, rel)

        if not os.path.isfile(full):
            return self._send(404, {"error": "Not found"})

        types = {
            ".html": "text/html; charset=utf-8",
            ".js": "text/javascript; charset=utf-8",
            ".css": "text/css; charset=utf-8",
            ".json": "application/json",
            ".webmanifest": "application/manifest+json",
            ".png": "image/png",
            ".svg": "image/svg+xml",
        }

        with open(full, "rb") as f:
            self._send(200, f.read(), types.get(os.path.splitext(full)[1], "application/octet-stream"))

    def do_GET(self):
        self._route("GET")

    def do_POST(self):
        self._route("POST")


# ---- route handlers ----------------------------------------------

def need(body, *names):
    missing = [n for n in names if body.get(n) in (None, "")]

    if missing:
        raise OpError(f"Missing field(s): {', '.join(missing)}")

    return [body[n] for n in names]


def r_state(h, body, q):
    return STORE.snapshot()


def r_wait(h, body, q):
    since = int(q.get("since", -1))
    timeout = min(float(q.get("timeout", 30)), WAIT_MAX_SECONDS)
    rev = STORE.wait_for_change(since, timeout)
    return {"rev": rev, "changed": rev != since}


def r_info(h, body, q):
    info = {"version": VERSION, "rev": STORE.rev, "mal": MAL.token_status(),
            "malClientIdSet": bool(MAL.client_id)}

    # Only reveal the token to HA ingress (i.e. an HA admin).
    if h._is_ingress():
        info["apiToken"] = API_TOKEN

    return info


def r_episodes(h, body, q):
    return OPS.queue_episodes(body.get("items"), body.get("malId"))


def r_done(h, body, q):
    series, season, episode = need(body, "series", "season", "episode")
    return OPS.done(series, season, episode, body.get("kind") or "episode")


def r_undo(h, body, q):
    return OPS.undo()


def r_remove(h, body, q):
    series, season, episode = need(body, "series", "season", "episode")
    return OPS.remove_episode(series, body.get("kind") or "episode", season, episode)


def r_remove_series(h, body, q):
    (key,) = need(body, "seriesKey")
    return OPS.remove_series(key, body.get("label"))


def r_confirm(h, body, q):
    key, mal_id = need(body, "seriesKey", "malId")
    return OPS.confirm_series(key, mal_id, body.get("title"))


def r_skip(h, body, q):
    (key,) = need(body, "seriesKey")
    return OPS.skip_series(key)


def r_remap(h, body, q):
    (key,) = need(body, "seriesKey")
    return OPS.remap_series(key, body.get("query"))


def r_grade(h, body, q):
    (key,) = need(body, "seriesKey")
    score = body.get("score")
    return OPS.grade(key, int(score) if score not in (None, "") else None)


def r_dismiss(h, body, q):
    (key,) = need(body, "key")
    return OPS.dismiss_batch_warning(key)


def r_mal_search(h, body, q):
    query = (q.get("q") or "").strip()

    if not query:
        raise OpError("Missing ?q=")

    return MAL.search(query)


def r_mal_list(h, body, q):
    return MAL.list_status(q.get("status") or "plan_to_watch")


def r_mal_season(h, body, q):
    return MAL.season(q.get("sort") or "popularity")


def r_auth_start(h, body, q):
    return {"url": MAL.auth_start()}


def r_auth_finish(h, body, q):
    (url,) = need(body, "redirectUrl")
    MAL.auth_finish(url)
    return {"message": "Logged in to MyAnimeList."}


def r_import(h, body, q):
    result = OPS.import_state(body.get("docs") or {}, bool(body.get("force")))
    token = body.get("malToken")

    if token:
        if not token.get("refresh_token"):
            raise OpError("malToken has no refresh_token.")

        MAL.save_tokens(token, keep_obtained_at=True)
        result["message"] += ", MAL token"

    return result


ROUTES = {
    ("GET", "/api/state"): r_state,
    ("GET", "/api/wait"): r_wait,
    ("GET", "/api/info"): r_info,
    ("POST", "/api/episodes"): r_episodes,
    ("POST", "/api/done"): r_done,
    ("POST", "/api/undo"): r_undo,
    ("POST", "/api/remove"): r_remove,
    ("POST", "/api/remove-series"): r_remove_series,
    ("POST", "/api/series/confirm"): r_confirm,
    ("POST", "/api/series/skip"): r_skip,
    ("POST", "/api/series/remap"): r_remap,
    ("POST", "/api/grade"): r_grade,
    ("POST", "/api/batch-warnings/dismiss"): r_dismiss,
    ("GET", "/api/mal/search"): r_mal_search,
    ("GET", "/api/mal/list"): r_mal_list,
    ("GET", "/api/mal/season"): r_mal_season,
    ("POST", "/api/mal/auth/start"): r_auth_start,
    ("POST", "/api/mal/auth/finish"): r_auth_finish,
    ("POST", "/api/import"): r_import,
}


def main():
    log(f"Anime-Widget server {VERSION} starting on port {PORT} (data: {DATA_DIR}, rev {STORE.rev})")

    if not MAL.client_id:
        log("WARNING: mal_client_id is not set -- MAL features will fail until it is.")

    OPS.resume_interrupted_searches()

    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    server.daemon_threads = True
    server.serve_forever()


if __name__ == "__main__":
    main()
