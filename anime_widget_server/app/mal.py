"""MyAnimeList API client, ported from the old anime-mal-*.py scripts.

The OAuth token now lives on the server (in /data/mal-token.json) and
is refreshed here, both proactively (shortly before expiry) and
reactively (refresh-and-retry once on a 401). 429s back off and retry.
"""

import json
import os
import re
import secrets
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime

# Overridable so the test suite can point at a fake MAL.
API = os.environ.get("MAL_API_BASE", "https://api.myanimelist.net/v2")
TOKEN_URL = os.environ.get("MAL_TOKEN_URL", "https://myanimelist.net/v1/oauth2/token")
AUTH_URL = "https://myanimelist.net/v1/oauth2/authorize"

# Must match the redirect URI registered on your MAL API app. The old
# desktop flow used this, so keeping it means no change on MAL's side:
# after authorizing, the browser tries to load localhost (which fails
# on a phone -- that's fine) and you paste that URL back into the
# server's web page.
REDIRECT_URI = "http://localhost:8080/callback"

REFRESH_MARGIN_SECONDS = 300
CANDIDATE_FIELDS = "alternative_titles,media_type,start_season,main_picture"


class MalError(RuntimeError):
    pass


class MalClient:
    def __init__(self, data_dir, client_id, log):
        self.token_file = os.path.join(data_dir, "mal-token.json")
        self.client_id = client_id
        self.log = log
        self._token_lock = threading.Lock()
        self._pending_auth = None  # (state, code_verifier)

    # ---- token handling -------------------------------------------

    def has_token(self):
        return os.path.exists(self.token_file)

    def _require_client_id(self):
        if not self.client_id:
            raise MalError(
                "MAL client ID is not set -- add it in the add-on's "
                "Configuration tab."
            )

    def save_tokens(self, tokens, keep_obtained_at=False):
        if not keep_obtained_at or "obtained_at" not in tokens:
            tokens["obtained_at"] = time.time()

        tmp = self.token_file + ".tmp"

        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(tokens, f, indent=2)

        os.chmod(tmp, 0o600)
        os.replace(tmp, self.token_file)

    def _load_raw_tokens(self):
        if not self.has_token():
            raise MalError(
                "Not logged in to MyAnimeList -- open the add-on's web "
                "page in Home Assistant and log in (or run "
                "'anime-client.py migrate' to import your old token)."
            )

        with open(self.token_file, "r", encoding="utf-8") as f:
            return json.load(f)

    def _refresh(self, tokens):
        self._require_client_id()

        data = urllib.parse.urlencode({
            "client_id": self.client_id,
            "grant_type": "refresh_token",
            "refresh_token": tokens["refresh_token"],
        }).encode()

        request = urllib.request.Request(
            TOKEN_URL,
            data=data,
            headers={"Content-Type": "application/x-www-form-urlencoded"},
            method="POST",
        )

        with urllib.request.urlopen(request, timeout=20) as response:
            new_tokens = json.load(response)

        self.save_tokens(new_tokens)
        self.log("Refreshed MAL access token")

        return new_tokens

    def _load_tokens(self):
        with self._token_lock:
            tokens = self._load_raw_tokens()
            obtained_at = tokens.get("obtained_at")
            expires_in = tokens.get("expires_in")

            if obtained_at and expires_in:
                if time.time() >= obtained_at + expires_in - REFRESH_MARGIN_SECONDS:
                    try:
                        tokens = self._refresh(tokens)
                    except Exception as e:
                        self.log(
                            "Proactive token refresh failed, will retry "
                            f"reactively if needed: {e}"
                        )

            return tokens

    def token_status(self):
        if not self.has_token():
            return {"loggedIn": False}

        try:
            tokens = self._load_raw_tokens()
        except Exception as e:
            return {"loggedIn": False, "error": str(e)}

        expires_at = None

        if tokens.get("obtained_at") and tokens.get("expires_in"):
            expires_at = tokens["obtained_at"] + tokens["expires_in"]

        return {"loggedIn": True, "accessExpiresAt": expires_at}

    # ---- OAuth (paste-the-redirect-URL flow) ----------------------

    def auth_start(self):
        self._require_client_id()

        # MAL only supports the "plain" PKCE method.
        verifier = secrets.token_urlsafe(64)[:100]
        state = secrets.token_urlsafe(32)
        self._pending_auth = (state, verifier)

        params = {
            "response_type": "code",
            "client_id": self.client_id,
            "redirect_uri": REDIRECT_URI,
            "code_challenge": verifier,
            "code_challenge_method": "plain",
            "state": state,
        }

        return AUTH_URL + "?" + urllib.parse.urlencode(params)

    def auth_finish(self, redirected_url):
        if not self._pending_auth:
            raise MalError("No login in progress -- click 'Log in' first.")

        state, verifier = self._pending_auth
        params = urllib.parse.parse_qs(urllib.parse.urlparse(redirected_url.strip()).query)

        if "error" in params:
            raise MalError(f"MAL authorization failed: {params['error'][0]}")

        if params.get("state", [None])[0] != state:
            raise MalError("OAuth state mismatch -- start the login again.")

        code = params.get("code", [None])[0]

        if not code:
            raise MalError("No 'code' found in that URL.")

        data = urllib.parse.urlencode({
            "client_id": self.client_id,
            "code": code,
            "code_verifier": verifier,
            "grant_type": "authorization_code",
            "redirect_uri": REDIRECT_URI,
        }).encode()

        request = urllib.request.Request(
            TOKEN_URL,
            data=data,
            headers={"Content-Type": "application/x-www-form-urlencoded"},
        )

        try:
            with urllib.request.urlopen(request, timeout=20) as response:
                tokens = json.load(response)
        except urllib.error.HTTPError as e:
            body = e.read().decode("utf-8", errors="replace")
            raise MalError(f"MAL token endpoint error: HTTP {e.code} {body}") from e

        with self._token_lock:
            self.save_tokens(tokens)

        self._pending_auth = None
        self.log("Logged in to MAL via web flow")

    # ---- generic requests -----------------------------------------

    def _send(self, url, method, headers, data):
        request = urllib.request.Request(url, data=data, headers=headers, method=method)

        with urllib.request.urlopen(request, timeout=30) as response:
            if response.status == 204:
                return {}

            body = response.read()
            return json.loads(body) if body else {}

    def _with_retries(self, url, method, headers, data, on_401=None):
        attempts = 0

        while True:
            attempts += 1

            try:
                return self._send(url, method, headers, data)
            except urllib.error.HTTPError as e:
                if e.code == 401 and on_401 and attempts < 3:
                    if on_401(headers):
                        continue

                if e.code == 429 and attempts < 3:
                    retry_after = e.headers.get("Retry-After") if e.headers else None

                    try:
                        wait = float(retry_after) if retry_after else 2.0
                    except ValueError:
                        wait = 2.0

                    self.log(f"MAL rate limit hit (429) -- waiting {wait}s")
                    time.sleep(wait)
                    continue

                body = ""

                try:
                    body = e.read().decode("utf-8", errors="replace")
                except Exception:
                    pass

                raise MalError(f"MAL API error: HTTP {e.code} {body}") from e
            except urllib.error.URLError as e:
                raise MalError(f"Could not reach MyAnimeList: {e.reason}") from e

    def user_request(self, url, method="GET", data=None):
        """Request on behalf of the logged-in user (OAuth bearer)."""
        tokens = self._load_tokens()
        headers = {"Authorization": f"Bearer {tokens['access_token']}"}
        encoded = None

        if data is not None:
            encoded = urllib.parse.urlencode(data).encode()
            headers["Content-Type"] = "application/x-www-form-urlencoded"

        state = {"tokens": tokens}

        def on_401(hdrs):
            try:
                with self._token_lock:
                    state["tokens"] = self._refresh(state["tokens"])
            except Exception as e:
                self.log(f"Reactive token refresh failed: {e}")
                return False

            hdrs["Authorization"] = f"Bearer {state['tokens']['access_token']}"
            return True

        return self._with_retries(url, method, headers, encoded, on_401)

    def public_request(self, url):
        """Read-only request authenticated with just the client ID."""
        self._require_client_id()
        return self._with_retries(url, "GET", {"X-MAL-Client-ID": self.client_id}, None)

    # ---- list status ----------------------------------------------

    def get_previous_state(self, mal_id):
        result = self.user_request(f"{API}/anime/{mal_id}?fields=my_list_status")
        current = result.get("my_list_status")

        if current is None:
            return {"exists": False}

        return {
            "exists": True,
            "status": current.get("status"),
            "num_episodes_watched": current.get("num_episodes_watched", 0),
        }

    def update_watched(self, mal_id, episode):
        """Returns (previous_state, message)."""
        previous = self.get_previous_state(mal_id)
        url = f"{API}/anime/{mal_id}/my_list_status"

        if not previous["exists"]:
            self.user_request(url, "PUT", {"status": "watching", "num_watched_episodes": episode})
            self.log(f"Added MAL ID {mal_id} with episode {episode}")
            return previous, f"Added to MAL as Watching ({episode} watched)."

        current_watched = previous["num_episodes_watched"]
        status = previous["status"] or "unknown"
        update = {}
        new_watched = max(current_watched, episode)

        if new_watched != current_watched:
            update["num_watched_episodes"] = new_watched

        # Watching an episode should move plan-to-watch/on-hold/dropped
        # to "watching" -- MAL doesn't infer this itself.
        if status in ("plan_to_watch", "on_hold", "dropped"):
            update["status"] = "watching"

        if not update:
            self.log(f"MAL ID {mal_id} already at {current_watched} ({status}); checked {episode}")
            return previous, f"MAL already at {current_watched} episodes."

        self.user_request(url, "PUT", update)
        self.log(f"Updated MAL ID {mal_id}: {update}")
        return previous, "MAL updated."

    def mark_finished(self, mal_id, score=None):
        data = {"status": "completed"}

        if score is not None:
            data["score"] = int(score)

        self.user_request(f"{API}/anime/{mal_id}/my_list_status", "PUT", data)
        self.log(f"Marked MAL ID {mal_id} completed" + (f" with score {score}" if score is not None else ""))

    def restore_state(self, mal_id, previous):
        url = f"{API}/anime/{mal_id}/my_list_status"

        if not previous.get("exists", False):
            try:
                self.user_request(url, "DELETE")
            except MalError as e:
                # 404 = already absent, which is what we want.
                if "HTTP 404" not in str(e):
                    raise

            self.log(f"Restored MAL ID {mal_id}: removed from list")
            return

        status = previous.get("status")

        if not status:
            raise MalError("Previous MAL state has no status.")

        watched = previous.get("num_episodes_watched", 0)
        self.user_request(url, "PUT", {"status": status, "num_watched_episodes": watched})
        self.log(f"Restored MAL ID {mal_id}: status={status}, episodes={watched}")

    # ---- lookups --------------------------------------------------

    @staticmethod
    def _candidate(node, extra=None):
        out = {
            "id": node.get("id"),
            "title": node.get("title"),
            "englishTitle": (node.get("alternative_titles") or {}).get("en") or None,
            "mediaType": node.get("media_type"),
            "startYear": (node.get("start_season") or {}).get("year"),
            "picture": (node.get("main_picture") or {}).get("medium"),
        }

        if extra:
            out.update(extra)

        return out

    def search(self, query, limit=6):
        params = urllib.parse.urlencode({"q": query[:64], "limit": limit, "fields": CANDIDATE_FIELDS})
        result = self.public_request(f"{API}/anime?{params}")
        return [self._candidate(item.get("node", {})) for item in result.get("data", [])]

    def details(self, mal_id):
        data = self.public_request(f"{API}/anime/{mal_id}?fields=num_episodes,alternative_titles,main_picture")
        return {
            "title": data.get("title"),
            "numEpisodes": data.get("num_episodes") or None,
            "englishTitle": (data.get("alternative_titles") or {}).get("en") or None,
            "picture": (data.get("main_picture") or {}).get("medium"),
        }

    def list_status(self, status):
        url = (
            f"{API}/users/@me/animelist?status={urllib.parse.quote(status)}"
            f"&fields={CANDIDATE_FIELDS}&limit=100"
        )
        results = []

        while url:
            result = self.user_request(url)
            results.extend(self._candidate(e.get("node", {})) for e in result.get("data", []))
            url = result.get("paging", {}).get("next")

        return results

    def season(self, sort="popularity"):
        now = datetime.now()
        season = ["winter", "spring", "summer", "fall"][(now.month - 1) // 3]
        url = (
            f"{API}/anime/season/{now.year}/{season}"
            f"?fields={CANDIDATE_FIELDS},mean,num_list_users&limit=100"
        )
        results = []

        while url:
            data = self.public_request(url)

            for item in data.get("data", []):
                node = item.get("node", {})
                results.append(self._candidate(node, {
                    "score": node.get("mean"),
                    "members": node.get("num_list_users"),
                }))

            url = data.get("paging", {}).get("next")

        # MAL's own sort misplaces unscored entries; sort ourselves with
        # missing values pushed to the end.
        key = "score" if sort == "score" else "members"
        results.sort(key=lambda r: (r[key] is None, -(r[key] or 0)))
        return results


def clean_query(name):
    """Turn a fansub folder name into a reasonable MAL search query."""
    text = name.split("::")[0]
    text = re.sub(r"\[[^\]]*\]", " ", text)
    text = re.sub(r"\([^)]*\)", " ", text)
    text = re.sub(r"\b(19|20)\d{2}\b", " ", text)
    text = re.sub(r"\b(1080p|720p|480p|4k|hevc|x264|x265|bd|web-?dl)\b", " ", text, flags=re.I)
    text = re.sub(r"\bseason\s*\d+\b", " ", text, flags=re.I)
    text = re.sub(r"\bs\d{1,2}\b", " ", text, flags=re.I)
    text = re.sub(r"[._]+", " ", text)
    return re.sub(r"\s+", " ", text).strip()
