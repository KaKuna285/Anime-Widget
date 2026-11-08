#!/usr/bin/env python3
"""End-to-end test: real server + real client against a fake MAL.

Dev tool (not deployed). Runs entirely in a temp dir with its own HOME,
so it never touches your real data, token or server:

    python3 tests/e2e-test.py
"""

import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CLIENT = os.path.join(REPO, "scripts", "anime-downloaded.sh")
SERVER = os.path.join(REPO, "anime_widget_server", "app", "server.py")


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


# ---- fake MyAnimeList --------------------------------------------

class FakeMal:
    def __init__(self):
        self.lists = {}           # mal_id -> {"status", "num_episodes_watched", "score"}
        self.catalog = {
            101: {"title": "Frieren", "en": "Frieren: Beyond Journey's End", "eps": 3},
            202: {"title": "Dandadan", "en": None, "eps": 12},
            303: {"title": "Dandadan Movie", "en": None, "eps": 1},
        }
        self.fail_puts = False
        self.force_401_once = False
        self.refreshes = 0
        self.calls = []


MAL = FakeMal()


class MalHandler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _send(self, status, obj=None):
        body = json.dumps(obj or {}).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _node(self, mid):
        c = MAL.catalog[mid]
        return {"id": mid, "title": c["title"], "alternative_titles": {"en": c["en"]},
                "media_type": "tv", "start_season": {"year": 2024}, "main_picture": {"medium": f"pic{mid}"}}

    def _auth_ok(self):
        if self.headers.get("X-MAL-Client-ID"):
            return True
        if MAL.force_401_once and self.headers.get("Authorization"):
            MAL.force_401_once = False
            return False
        return self.headers.get("Authorization", "").startswith("Bearer ")

    def do_GET(self):
        MAL.calls.append(("GET", self.path))
        if not self._auth_ok():
            return self._send(401, {"error": "invalid_token"})
        u = urllib.parse.urlparse(self.path)
        q = urllib.parse.parse_qs(u.query)
        parts = u.path.strip("/").split("/")   # v2/anime/...

        if parts[:2] == ["v2", "anime"] and len(parts) == 2:
            needle = q["q"][0].lower()
            hits = [self._node(m) for m, c in MAL.catalog.items() if needle.split()[0] in c["title"].lower()]
            return self._send(200, {"data": [{"node": n} for n in hits]})
        if parts[:3] == ["v2", "anime", "season"]:
            return self._send(200, {"data": [{"node": dict(self._node(101), mean=9.1, num_list_users=5)}]})
        if parts[:2] == ["v2", "anime"] and len(parts) == 3:
            mid = int(parts[2])
            fields = q.get("fields", [""])[0]
            if "my_list_status" in fields:
                node = {"id": mid}
                if mid in MAL.lists:
                    node["my_list_status"] = MAL.lists[mid]
                return self._send(200, node)
            c = MAL.catalog[mid]
            return self._send(200, {"id": mid, "num_episodes": c["eps"], "alternative_titles": {"en": c["en"]},
                                    "main_picture": {"medium": f"pic{mid}"}})
        if parts[:4] == ["v2", "users", "@me", "animelist"]:
            st = q["status"][0]
            return self._send(200, {"data": [{"node": self._node(m)} for m, v in MAL.lists.items() if v["status"] == st]})
        self._send(404)

    def do_PUT(self):
        MAL.calls.append(("PUT", self.path))
        if not self._auth_ok():
            return self._send(401)
        if MAL.fail_puts:
            return self._send(500, {"error": "boom"})
        mid = int(self.path.strip("/").split("/")[2])
        data = urllib.parse.parse_qs(self.rfile.read(int(self.headers["Content-Length"])).decode())
        entry = MAL.lists.setdefault(mid, {"status": "watching", "num_episodes_watched": 0})
        if "status" in data:
            entry["status"] = data["status"][0]
        if "num_watched_episodes" in data:
            entry["num_episodes_watched"] = int(data["num_watched_episodes"][0])
        if "score" in data:
            entry["score"] = int(data["score"][0])
        self._send(200, entry)

    def do_DELETE(self):
        MAL.calls.append(("DELETE", self.path))
        mid = int(self.path.strip("/").split("/")[2])
        if MAL.lists.pop(mid, None) is None:
            return self._send(404)
        self._send(200)

    def do_POST(self):  # token refresh
        MAL.refreshes += 1
        self.rfile.read(int(self.headers["Content-Length"]))
        self._send(200, {"access_token": f"acc{MAL.refreshes}", "refresh_token": "ref", "expires_in": 3600})


# ---- harness ------------------------------------------------------

class Env:
    def __init__(self):
        self.tmp = tempfile.mkdtemp(prefix="anime-e2e-")
        self.home = os.path.join(self.tmp, "home")
        self.data = os.path.join(self.tmp, "data")
        os.makedirs(os.path.join(self.home, ".config", "anime-todo"))
        os.makedirs(os.path.join(self.home, ".local", "share"))
        os.makedirs(self.data)
        self.mal_port = free_port()
        self.port = free_port()
        self.url = f"http://127.0.0.1:{self.port}"
        self.mal_server = ThreadingHTTPServer(("127.0.0.1", self.mal_port), MalHandler)
        threading.Thread(target=self.mal_server.serve_forever, daemon=True).start()

        with open(os.path.join(self.data, "options.json"), "w") as f:
            json.dump({"api_token": "secret", "mal_client_id": "cid"}, f)

        with open(os.path.join(self.home, ".config", "anime-todo", "server.conf"), "w") as f:
            f.write(f"SERVER_URL={self.url}\nAPI_TOKEN=secret\n")

        self.proc = None
        self.start_server()

    def start_server(self):
        env = dict(os.environ, DATA_DIR=self.data, PORT=str(self.port),
                   MAL_API_BASE=f"http://127.0.0.1:{self.mal_port}/v2",
                   MAL_TOKEN_URL=f"http://127.0.0.1:{self.mal_port}/token")
        self.proc = subprocess.Popen([sys.executable, SERVER], env=env,
                                     stdout=subprocess.PIPE, stderr=subprocess.STDOUT)

        for _ in range(50):
            try:
                urllib.request.urlopen(self.url + "/api/health", timeout=1)
                return
            except Exception:
                time.sleep(0.1)

        raise RuntimeError("server did not start:\n" + self.proc.stdout.read().decode())

    def stop_server(self):
        self.proc.terminate()
        self.proc.wait()

    def run(self, *args, ok=True):
        env = dict(os.environ, HOME=self.home)
        env.pop("ANIME_SERVER_URL", None)
        p = subprocess.run(["bash", CLIENT, *args], env=env, capture_output=True, text=True, timeout=60)
        if ok and p.returncode != 0:
            raise AssertionError(f"{args} failed ({p.returncode}): {p.stdout}{p.stderr}")
        if not ok and p.returncode == 0:
            raise AssertionError(f"{args} unexpectedly succeeded: {p.stdout}")
        return p.stdout

    def state(self):
        return json.loads(self.run("state"))

    def wait_for(self, pred, what, timeout=5):
        end = time.time() + timeout
        while time.time() < end:
            s = self.state()
            if pred(s):
                return s
            time.sleep(0.1)
        raise AssertionError(f"timed out waiting for {what}: {json.dumps(self.state(), indent=1)}")

    def cleanup(self):
        try:
            self.stop_server()
        finally:
            self.mal_server.shutdown()
            shutil.rmtree(self.tmp, ignore_errors=True)


PASSED = []


def check(name, cond, detail=""):
    if not cond:
        raise AssertionError(f"FAIL: {name} {detail}")
    PASSED.append(name)
    print(f"  ok  {name}")


def main():
    e = Env()

    try:
        anime = os.path.join(e.home, "Anime")

        # -- migration of legacy JSON + token
        share = os.path.join(e.home, ".local", "share")
        with open(os.path.join(share, "anime-series-map.json"), "w") as f:
            json.dump({"Frieren": {"malId": 101, "title": "Frieren", "numEpisodes": 3, "confirmed": True}}, f)
        with open(os.path.join(share, "anime-history.json"), "w") as f:
            json.dump([{"series": "Frieren", "seriesKey": "Frieren", "kind": "episode", "season": 1,
                        "episode": 1, "malId": 101, "watched": True, "watchedAt": "2026-01-01T10:00:00",
                        "malPrevious": {"exists": False}}], f)
        with open(os.path.join(e.home, ".config", "anime-todo", "mal-token.json"), "w") as f:
            json.dump({"access_token": "old", "refresh_token": "ref", "expires_in": 3600,
                       "obtained_at": time.time()}, f)

        print(e.run("migrate").strip())
        s = e.state()
        check("migrate imports series map + history", "Frieren" in s["seriesMap"] and len(s["history"]) == 1)
        e.run("migrate", ok=False)
        check("migrate refuses to overwrite without --force", True)
        check("info shows MAL logged in", "logged in" in e.run("info"))

        # -- download hook: mapped series gets malId immediately
        os.makedirs(os.path.join(anime, "Frieren"))
        e.run("[SubsPlease] Frieren - 02 (1080p).mkv", os.path.join(anime, "Frieren", "f02.mkv"),
              os.path.join(anime, "Frieren"), "")
        s = e.state()
        ep = s["episodes"][0]
        check("single download queued with mapped malId", ep["malId"] == 101 and ep["episode"] == 2, json.dumps(ep))

        e.run("[SubsPlease] Frieren - 02 (1080p).mkv", os.path.join(anime, "Frieren", "f02.mkv"),
              os.path.join(anime, "Frieren"), "")
        check("duplicate download ignored", len(e.state()["episodes"]) == 1)

        # -- new series triggers background search -> ready candidates
        e.run("[SubsPlease] Dandadan - 05 (1080p).mkv", "/x/d05.mkv", os.path.join(anime, "Dandadan"), "")
        s = e.wait_for(lambda s: s["pendingMatches"].get("Dandadan", {}).get("status") == "ready", "search")
        check("unmapped series searched on MAL", s["pendingMatches"]["Dandadan"]["candidates"][0]["id"] == 202)

        e.run("confirm-series", "Dandadan", "202", "Dandadan")
        s = e.state()
        check("confirm maps series, clears pending, backfills malId",
              s["seriesMap"]["Dandadan"]["numEpisodes"] == 12 and "Dandadan" not in s["pendingMatches"]
              and all(x["malId"] == 202 for x in s["episodes"] if x["series"] == "Dandadan"))

        # -- mal:ID tag overrides
        e.run("Something - 01.mkv", "/x/s01.mkv", os.path.join(anime, "Something"), "mal:303")
        s = e.state()
        check("mal: tag sets malId without search",
              any(x["series"] == "Something" and x["malId"] == 303 for x in s["episodes"])
              and "Something" not in s["pendingMatches"])

        # -- ANIME_ROOT filter
        e.run("set-config", anime)
        before = len(e.state()["episodes"])
        out = e.run("Other - 01.mkv", "/elsewhere/o.mkv", "/elsewhere/Other", "")
        check("ANIME_ROOT filters outside downloads", "outside" in out and len(e.state()["episodes"]) == before)

        # -- done -> MAL updated, moved to history (with 401 refresh path)
        MAL.force_401_once = True
        e.run("done", "Frieren", "1", "2", "episode")
        s = e.state()
        check("done updates MAL (after reactive token refresh)",
              MAL.lists[101]["num_episodes_watched"] == 2 and MAL.refreshes >= 1)
        check("done moves episode to history",
              not any(x["series"] == "Frieren" for x in s["episodes"]) and s["history"][-1]["episode"] == 2)

        # -- MAL failure leaves episode in TODO
        MAL.fail_puts = True
        e.run("done", "Dandadan", "1", "5", "episode", ok=False)
        s = e.state()
        check("failed MAL update keeps episode unchecked", any(x["series"] == "Dandadan" for x in s["episodes"]))
        MAL.fail_puts = False

        # -- final episode -> pending grade -> grade
        e.run("[SubsPlease] Frieren - 03 (1080p).mkv", "/x/f03.mkv", os.path.join(anime, "Frieren"), "")
        res = e.run("done", "Frieren", "1", "3")
        s = e.state()
        check("final episode creates pending grade", "Frieren" in s["pendingGrades"], res)
        e.run("grade-series", "Frieren", "9")
        s = e.state()
        check("grading completes on MAL with score",
              MAL.lists[101]["status"] == "completed" and MAL.lists[101]["score"] == 9 and not s["pendingGrades"])

        # -- undo history restores previous MAL state
        e.run("undo")
        s = e.state()
        check("undo puts episode back and restores MAL count",
              any(x["series"] == "Frieren" and x["episode"] == 3 for x in s["episodes"])
              and MAL.lists[101]["num_episodes_watched"] == 2)

        # -- remove + undo-removal ordering
        time.sleep(1.1)   # timestamps have 1s resolution
        e.run("remove-episode", "Frieren", "episode", "1", "3")
        check("remove takes episode off list", not any(x["series"] == "Frieren" for x in e.state()["episodes"]))
        e.run("undo")
        s = e.state()
        check("undo after remove restores the removed episode (not history)",
              any(x["series"] == "Frieren" and x["episode"] == 3 for x in s["episodes"]) and not s["lastRemoved"]
              and len(s["history"]) == 2)

        # -- undo of a first-ever watch removes it from MAL list again
        e.run("done", "Something", "1", "1")
        check("first watch adds to MAL list", 303 in MAL.lists)
        e.run("undo")
        check("undo of first watch deletes MAL entry", 303 not in MAL.lists)

        # -- skip + remap
        e.run("skip-series", "Something")
        check("skip-series marks skipped", e.state()["seriesMap"]["Something"]["skipped"])
        e.run("remap-series", "Something", "Dandadan")
        s = e.wait_for(lambda s: s["pendingMatches"].get("Something", {}).get("status") == "ready", "remap")
        check("remap runs custom query", s["pendingMatches"]["Something"]["query"] == "Dandadan")

        # -- multi-group batch splitting
        batch = os.path.join(e.tmp, "batch")
        os.makedirs(batch)
        for n in ("Show S01E01.mkv", "Show S01E02.mkv", "Show S02E01.mkv", "notes.txt"):
            open(os.path.join(batch, n), "w").close()
        e.run("Show Batch", batch, os.path.join(anime, "Show"), "")
        s = e.state()
        keys = sorted({x["seriesKey"] for x in s["episodes"] if x["series"] == "Show"})
        check("batch split into per-season keys", keys == ["Show::episodeS1", "Show::episodeS2"], str(keys))

        # -- client commands for add-series tool
        check("search-only returns candidates", json.loads(e.run("search-only", "Frieren"))[0]["id"] == 101)
        check("mal-season returns list", json.loads(e.run("mal-season", "score"))[0]["score"] == 9.1)
        MAL.lists[202] = {"status": "plan_to_watch", "num_episodes_watched": 0}
        check("mal-list returns user list", json.loads(e.run("mal-list", "plan_to_watch"))[0]["id"] == 202)
        check("legacy 'list' command still prints episodes", isinstance(json.loads(e.run("list")), list))

        # -- long-poll wakes on change
        rev = e.state()["rev"]
        t0 = time.time()
        waiter = subprocess.Popen(["bash", CLIENT, "wait"], env=dict(os.environ, HOME=e.home))
        time.sleep(0.5)
        e.run("dismiss-batch-warning", "nothing")   # no-op: must NOT wake
        time.sleep(0.3)
        check("no-op change does not bump revision", waiter.poll() is None and e.state()["rev"] == rev)
        e.run("remove-episode", "Show", "episode", "2", "1")
        waiter.wait(timeout=5)
        check("wait returns promptly after a change", time.time() - t0 < 4)

        # -- offline: cached state + outbox + auto flush
        e.stop_server()
        s = e.state()
        check("offline state falls back to cache", s["offline"] and len(s["episodes"]) > 0)
        out = e.run("[SubsPlease] Dandadan - 06 (1080p).mkv", "/x/d06.mkv", os.path.join(anime, "Dandadan"), "")
        check("offline download goes to outbox", "Queued locally" in out and e.state()["outboxCount"] == 1)
        e.run("done", "Dandadan", "1", "5", ok=False)
        check("offline mutation fails loudly", True)
        e.start_server()
        s = e.state()
        check("outbox flushed when server is back",
              s["outboxCount"] == 0 and not s["offline"]
              and any(x["series"] == "Dandadan" and x["episode"] == 6 for x in s["episodes"]))

        # -- persistence across restart
        e.stop_server()
        e.start_server()
        check("state persists across server restart", any(x["episode"] == 6 for x in e.state()["episodes"]))

        # -- auth
        try:
            urllib.request.urlopen(e.url + "/api/state")
            check("API rejects requests without token", False)
        except urllib.error.HTTPError as err:
            check("API rejects requests without token", err.code == 401)

        print(f"\nAll {len(PASSED)} checks passed.")
    finally:
        e.cleanup()


if __name__ == "__main__":
    main()
