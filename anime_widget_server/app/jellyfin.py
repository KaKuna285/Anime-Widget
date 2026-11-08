"""Auto-tick episodes that were watched in Jellyfin.

Every few seconds the server asks Jellyfin for the user's played
episodes/movies, and any that match an episode in the list (by its
library path, which the PC client records from the ~/AnimeLibrary
hardlinks) is marked watched through the normal "done" path -- so MAL
updates and the rate-it prompt appear exactly as for a manual tick.

An episode is ticked once per play: undoing an auto-tick won't make it
come straight back, but playing it to the end again will.
"""

import json
import os
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

POLL_SECONDS = float(os.environ.get("JELLYFIN_POLL_SECONDS", "30"))
SEEN_LIMIT = 1000


class JellyfinWatcher:
    def __init__(self, store, ops, log, url, api_key, username, version):
        self.store = store
        self.ops = ops
        self.log = log
        self.url = (url or "").rstrip("/")
        self.api_key = (api_key or "").strip()
        self.username = (username or "").strip()
        self.version = version
        self.user_id = None
        self.status = {"enabled": self.enabled, "ok": None, "error": "", "lastCheck": None, "ticked": 0}
        self._error_logged = {}

    @property
    def enabled(self):
        return bool(self.url and self.api_key and self.username)

    # ---- HTTP -----------------------------------------------------

    def _get(self, path, params=None):
        query = ("?" + urllib.parse.urlencode(params)) if params else ""
        auth = (
            f'MediaBrowser Client="Anime-Widget", Device="Home Assistant", '
            f'DeviceId="anime-widget-server", Version="{self.version}", Token="{self.api_key}"'
        )
        req = urllib.request.Request(self.url + path + query, headers={"Authorization": auth})

        with urllib.request.urlopen(req, timeout=20) as response:
            return json.load(response)

    def _resolve_user(self):
        users = self._get("/Users")
        match = next((u for u in users if u.get("Name", "").lower() == self.username.lower()), None)

        if not match:
            names = ", ".join(u.get("Name", "?") for u in users)
            raise RuntimeError(f"Jellyfin user '{self.username}' not found (users: {names})")

        self.user_id = match["Id"]

    def played_items(self):
        if not self.user_id:
            self._resolve_user()

        data = self._get("/Items", {
            "userId": self.user_id,
            "IsPlayed": "true",
            "Recursive": "true",
            "IncludeItemTypes": "Episode,Movie",
            "Fields": "Path",
            "SortBy": "DatePlayed",
            "SortOrder": "Descending",
            "Limit": "300",
            "EnableImages": "false",
        })
        return data.get("Items", [])

    # ---- matching -------------------------------------------------

    @staticmethod
    def _norm(path):
        return (path or "").replace("\\", "/")

    def check_once(self):
        items = self.played_items()
        episodes = self.store.get("episodes")
        seen = self.store.get("jellyfinSeen")
        targets = [e for e in episodes if e.get("libraryPath")]

        if not targets:
            return 0

        ticked = 0
        new_seen = dict(seen)

        for item in items:
            path = self._norm(item.get("Path"))
            played_at = (item.get("UserData") or {}).get("LastPlayedDate") or "played"
            marker = f"{item.get('Id')}|{played_at}"

            if not path or seen.get(item.get("Id")) == played_at:
                continue

            for ep in targets:
                rel = self._norm(ep["libraryPath"]).lstrip("/")

                if not (path == rel or path.endswith("/" + rel)):
                    continue

                try:
                    self.ops.done(ep["series"], ep["season"], ep["episode"], ep.get("kind") or "episode")
                    self.log(f"Jellyfin: marked watched -> {ep['series']} S{ep['season']:02d}E{ep['episode']:02d}")
                    ticked += 1
                    new_seen[item["Id"]] = played_at
                except Exception as e:
                    # Usually MAL being unreachable; try again next round,
                    # but don't flood the log.
                    if time.time() - self._error_logged.get(marker, 0) > 600:
                        self._error_logged[marker] = time.time()
                        self.log(f"Jellyfin: couldn't mark {ep['series']} ep {ep['episode']} watched: {e}")
                break

        if new_seen != seen:
            # Keep the map bounded; drop the oldest entries.
            if len(new_seen) > SEEN_LIMIT:
                new_seen = dict(list(new_seen.items())[-SEEN_LIMIT:])

            with self.store.op_lock:
                self.store.commit({"jellyfinSeen": new_seen})

        return ticked

    def prime(self):
        """On first start, remember what's already played so old plays
        don't suddenly tick episodes that were re-added to the list."""
        if self.store.get("jellyfinSeen"):
            return

        seen = {i["Id"]: (i.get("UserData") or {}).get("LastPlayedDate") or "played"
                for i in self.played_items() if i.get("Id")}

        with self.store.op_lock:
            self.store.commit({"jellyfinSeen": seen or {"_primed": "1"}})

        self.log(f"Jellyfin: connected as '{self.username}', {len(seen)} played item(s) noted.")

    # ---- loop -----------------------------------------------------

    def run(self):
        primed = False

        while True:
            try:
                if not primed:
                    self.prime()
                    primed = True

                ticked = self.check_once()
                self.status.update(ok=True, error="", lastCheck=time.time())
                self.status["ticked"] += ticked
            except (urllib.error.URLError, OSError, RuntimeError, ValueError) as e:
                reason = getattr(e, "reason", None) or e
                message = f"{reason}"

                if isinstance(e, urllib.error.HTTPError) and e.code == 401:
                    message = "Jellyfin rejected the API key (401)."

                if self.status.get("error") != message:
                    self.log(f"Jellyfin: {message}")

                self.status.update(ok=False, error=message, lastCheck=time.time())
                self.user_id = None
            except Exception as e:
                self.log(f"Jellyfin: unexpected error: {e}")
                self.status.update(ok=False, error=str(e), lastCheck=time.time())

            time.sleep(POLL_SECONDS)

    def start(self):
        if not self.enabled:
            return

        threading.Thread(target=self.run, daemon=True).start()
