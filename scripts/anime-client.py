#!/usr/bin/env python3
"""PC-side client for the Anime-Widget server (Home Assistant add-on).

Replaces the old JSON-file logic in anime-downloaded.sh while keeping
its command-line interface, so the widget, standalone app, add-series
tool and qBittorrent hook all keep calling the same commands:

  anime-downloaded.sh "%N" "%F" "%D" "%T"   qBittorrent completion hook
  anime-downloaded.sh state                 everything, as one JSON object
  anime-downloaded.sh done SERIES SEASON EPISODE [KIND]
  ... (see usage() for the full list)

What stays on the PC (because it needs the files): filename parsing,
the ANIME_ROOT filter, batch-folder walking, and anime_link.py.

Offline behaviour:
  * read commands fall back to the last cached state (marked "offline")
  * new downloads are queued in an outbox and sent automatically the
    next time any command reaches the server
  * mutating commands fail loudly (they need the server/MAL anyway)
"""

import contextlib
import fcntl
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime

HOME = os.path.expanduser("~")
SCRIPT_DIR = os.path.dirname(os.path.realpath(__file__))
CONFIG_DIR = os.path.join(HOME, ".config", "anime-todo")
SERVER_CONF = os.path.join(CONFIG_DIR, "server.conf")
ROOT_CONF = os.path.join(CONFIG_DIR, "anime-todo.conf")
DATA_DIR = os.path.join(HOME, ".local", "share")
CACHE_DIR = os.path.join(HOME, ".cache", "anime-todo")
CACHE_FILE = os.path.join(CACHE_DIR, "state.json")
OUTBOX_FILE = os.path.join(DATA_DIR, "anime-todo-outbox.json")
OUTBOX_LOCK = os.path.join(DATA_DIR, "anime-todo-outbox.lock")
CLIENT_LOG = os.path.join(DATA_DIR, "anime-client.log")
PARSER = os.path.join(SCRIPT_DIR, "anime-parse-episode.py")

LIBRARY_LINK_SCRIPT = os.path.join(HOME, "scripts", "anime_link.py")
LIBRARY_LINK_SOURCE = os.path.join(HOME, "Anime")
LIBRARY_LINK_DEST = os.path.join(HOME, "AnimeLibrary")
LIBRARY_LINK_LOG = os.path.join(HOME, "scripts", "anime_link.log")

VIDEO_EXTS = (".mkv", ".mp4", ".avi", ".ts", ".webm", ".m4v")
EMPTY_STATE = {
    "episodes": [], "history": [], "seriesMap": {}, "pendingMatches": {},
    "pendingGrades": {}, "batchWarnings": {}, "lastRemoved": {}, "rev": -1,
}
LEGACY_FILES = {
    "episodes": "anime-todo.json",
    "history": "anime-history.json",
    "seriesMap": "anime-series-map.json",
    "pendingMatches": "anime-pending-matches.json",
    "pendingGrades": "anime-pending-grades.json",
    "batchWarnings": "anime-batch-warnings.json",
    "lastRemoved": "anime-last-removed.json",
}


class Unreachable(Exception):
    pass


class ServerError(Exception):
    def __init__(self, message, status):
        super().__init__(message)
        self.status = status


def log(message):
    try:
        with open(CLIENT_LOG, "a", encoding="utf-8") as f:
            f.write(f"[{datetime.now().isoformat(timespec='seconds')}] {message}\n")
    except OSError:
        pass


def fail(message, code=1):
    print(message)
    sys.exit(code)


# ---- config -------------------------------------------------------

def read_kv(path):
    values = {}

    try:
        with open(path, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()

                if not line or line.startswith("#") or "=" not in line:
                    continue

                key, value = line.split("=", 1)
                values[key.strip()] = value.strip().strip('"').strip("'")
    except FileNotFoundError:
        pass

    return values


def server_config():
    conf = read_kv(SERVER_CONF)
    url = os.environ.get("ANIME_SERVER_URL") or conf.get("SERVER_URL", "")
    token = os.environ.get("ANIME_API_TOKEN") or conf.get("API_TOKEN", "")

    if not url:
        fail(f"No SERVER_URL configured -- create {SERVER_CONF} with SERVER_URL=... and API_TOKEN=...")

    return url.rstrip("/"), token


def anime_root():
    return read_kv(ROOT_CONF).get("ANIME_ROOT", "")


# ---- HTTP ---------------------------------------------------------

def request(method, path, body=None, timeout=15):
    url, token = server_config()
    data = None
    headers = {"Authorization": f"Bearer {token}"}

    if body is not None:
        data = json.dumps(body).encode("utf-8")
        headers["Content-Type"] = "application/json"

    req = urllib.request.Request(url + path, data=data, headers=headers, method=method)

    try:
        with urllib.request.urlopen(req, timeout=timeout) as response:
            return json.loads(response.read().decode("utf-8") or "null")
    except urllib.error.HTTPError as e:
        try:
            message = json.loads(e.read().decode("utf-8")).get("error") or str(e)
        except Exception:
            message = str(e)

        raise ServerError(message, e.code)
    except (urllib.error.URLError, OSError) as e:
        reason = getattr(e, "reason", e)
        raise Unreachable(f"Can't reach the Anime-Widget server at {url} ({reason}).")


def call(method, path, body=None, timeout=60):
    """For interactive commands: print the server's message or fail."""
    try:
        result = request(method, path, body, timeout)
    except Unreachable as e:
        fail(f"{e}\nIs the Home Assistant add-on running?")
    except ServerError as e:
        fail(str(e))

    return result


# ---- cache + outbox -----------------------------------------------

def save_cache(state):
    os.makedirs(CACHE_DIR, exist_ok=True)
    tmp = CACHE_FILE + ".tmp"

    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(state, f, ensure_ascii=False)

    os.replace(tmp, CACHE_FILE)


def load_cache():
    try:
        with open(CACHE_FILE, "r", encoding="utf-8") as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return dict(EMPTY_STATE)


@contextlib.contextmanager
def outbox_locked():
    os.makedirs(DATA_DIR, exist_ok=True)

    with open(OUTBOX_LOCK, "a+") as fd:
        fcntl.flock(fd, fcntl.LOCK_EX)

        try:
            try:
                with open(OUTBOX_FILE, "r", encoding="utf-8") as f:
                    box = json.load(f)
            except (FileNotFoundError, json.JSONDecodeError):
                box = []

            holder = {"box": box}
            yield holder

            if holder["box"]:
                tmp = OUTBOX_FILE + ".tmp"

                with open(tmp, "w", encoding="utf-8") as f:
                    json.dump(holder["box"], f, ensure_ascii=False, indent=2)

                os.replace(tmp, OUTBOX_FILE)
            elif os.path.exists(OUTBOX_FILE):
                os.remove(OUTBOX_FILE)
        finally:
            fcntl.flock(fd, fcntl.LOCK_UN)


def outbox_count():
    try:
        with open(OUTBOX_FILE, "r", encoding="utf-8") as f:
            return len(json.load(f))
    except (FileNotFoundError, json.JSONDecodeError):
        return 0


def flush_outbox():
    """Send queued downloads. Returns the number still queued."""
    if not os.path.exists(OUTBOX_FILE):
        return 0

    with outbox_locked() as holder:
        remaining = []

        for i, payload in enumerate(holder["box"]):
            try:
                request("POST", "/api/episodes", payload, timeout=20)
                log(f"Sent queued download ({len(payload.get('items', []))} item(s))")
            except Unreachable:
                remaining = holder["box"][i:]
                break
            except ServerError as e:
                if e.status >= 500 or e.status in (401, 403, 408, 429):
                    # Server-side trouble or bad token: keep it for later.
                    remaining = holder["box"][i:]
                    break

                # The server rejected the data itself -- retrying won't help.
                log(f"Dropped queued download the server rejected ({e}): {json.dumps(payload)}")

        holder["box"] = remaining
        return len(remaining)


# ---- read commands ------------------------------------------------

def fetch_state():
    """Returns (state, offline_reason or None). Never raises."""
    try:
        flush_outbox()
        state = request("GET", "/api/state", timeout=8)
        save_cache(state)
        return state, None
    except (Unreachable, ServerError) as e:
        return load_cache(), str(e)


def cmd_state(_args):
    state, reason = fetch_state()
    state["offline"] = reason is not None
    state["offlineReason"] = reason or ""
    state["outboxCount"] = outbox_count()
    print(json.dumps(state, ensure_ascii=False))


def cmd_doc(name):
    def run(_args):
        state, _ = fetch_state()
        print(json.dumps(state.get(name, EMPTY_STATE[name]), ensure_ascii=False, indent=2))

    return run


def cmd_wait(_args):
    """Block until the server state changes (long-poll), then exit 0.

    The widget re-runs this in a loop. It always exits 0 -- after a
    pause if the server is unreachable -- so the loop never dies; a
    failure here just means the widget refreshes (and shows offline).
    """
    since = load_cache().get("rev", -1)

    try:
        request("GET", f"/api/wait?since={since}&timeout=50", timeout=65)
    except Unreachable:
        time.sleep(10)
    except ServerError:
        time.sleep(30)


# ---- mutating commands --------------------------------------------

def print_result(result):
    if isinstance(result, dict) and result.get("message"):
        print(result["message"])


def cmd_done(args):
    if len(args) < 3:
        fail("Usage: done SERIES SEASON EPISODE [KIND]")

    print_result(call("POST", "/api/done", {
        "series": args[0], "season": int(args[1]), "episode": int(args[2]),
        "kind": args[3] if len(args) > 3 else "episode",
    }))


def cmd_undo(_args):
    print_result(call("POST", "/api/undo", {}))


def cmd_remove(args):
    if len(args) < 4:
        fail("Usage: remove-episode SERIES KIND SEASON EPISODE")

    print_result(call("POST", "/api/remove", {
        "series": args[0], "kind": args[1], "season": int(args[2]), "episode": int(args[3]),
    }))


def cmd_confirm(args):
    if len(args) < 2:
        fail("Usage: confirm-series SERIES_KEY MAL_ID [TITLE]")

    print_result(call("POST", "/api/series/confirm", {
        "seriesKey": args[0], "malId": int(args[1]), "title": args[2] if len(args) > 2 else None,
    }))


def cmd_skip(args):
    if not args:
        fail("Usage: skip-series SERIES_KEY")

    print_result(call("POST", "/api/series/skip", {"seriesKey": args[0]}))


def cmd_remap(args):
    if not args:
        fail("Usage: remap-series SERIES_KEY [QUERY]")

    print_result(call("POST", "/api/series/remap", {
        "seriesKey": args[0], "query": args[1] if len(args) > 1 else None,
    }))


def cmd_grade(args):
    if len(args) < 2:
        fail("Usage: grade-series SERIES_KEY SCORE")

    print_result(call("POST", "/api/grade", {"seriesKey": args[0], "score": int(args[1])}))


def cmd_skip_grade(args):
    if not args:
        fail("Usage: skip-grade SERIES_KEY")

    print_result(call("POST", "/api/grade", {"seriesKey": args[0], "score": None}))


def cmd_dismiss(args):
    if not args:
        fail("Usage: dismiss-batch-warning KEY")

    print_result(call("POST", "/api/batch-warnings/dismiss", {"key": args[0]}))


def cmd_search_only(args):
    if not args:
        fail("Usage: search-only QUERY")

    q = urllib.parse.quote(args[0])
    print(json.dumps(call("GET", f"/api/mal/search?q={q}"), ensure_ascii=False))


def cmd_mal_list(args):
    status = urllib.parse.quote(args[0] if args else "plan_to_watch")
    print(json.dumps(call("GET", f"/api/mal/list?status={status}", timeout=90), ensure_ascii=False))


def cmd_mal_season(args):
    sort = urllib.parse.quote(args[0] if args else "popularity")
    print(json.dumps(call("GET", f"/api/mal/season?sort={sort}", timeout=90), ensure_ascii=False))


def cmd_get_config(_args):
    print(anime_root())


def cmd_set_config(args):
    root = args[0] if args else ""
    os.makedirs(CONFIG_DIR, exist_ok=True)

    with open(ROOT_CONF, "w", encoding="utf-8") as f:
        f.write(f'ANIME_ROOT="{root}"\n')

    print(f"Anime root set to: {root}" if root else "Anime root cleared -- all downloads will be tracked.")


def cmd_info(_args):
    url, _ = server_config()
    info = call("GET", "/api/info")
    mal = info.get("mal", {})
    print(f"Server:    {url} (v{info.get('version')}, rev {info.get('rev')})")
    print(f"MAL:       {'logged in' if mal.get('loggedIn') else 'NOT logged in'}"
          f"{'' if info.get('malClientIdSet') else ' -- client ID not set in add-on config!'}")
    print(f"Outbox:    {outbox_count()} queued download(s)")


def cmd_flush(_args):
    left = flush_outbox()
    print(f"{left} download(s) still queued." if left else "Outbox is empty.")


def cmd_migrate(args):
    force = "--force" in args
    docs = {}

    for name, filename in LEGACY_FILES.items():
        path = os.path.join(DATA_DIR, filename)

        if os.path.exists(path):
            with open(path, "r", encoding="utf-8") as f:
                docs[name] = json.load(f)

    body = {"docs": docs, "force": force}
    token_file = os.path.join(CONFIG_DIR, "mal-token.json")

    if os.path.exists(token_file) and "--no-token" not in args:
        with open(token_file, "r", encoding="utf-8") as f:
            body["malToken"] = json.load(f)

    if not docs and "malToken" not in body:
        fail(f"Nothing to migrate -- no anime-*.json files in {DATA_DIR}.")

    print_result(call("POST", "/api/import", body))
    print("Your old files were left untouched in ~/.local/share (safe to delete once you're happy).")


# ---- qBittorrent hook ---------------------------------------------

def parse_episode(filename, series):
    try:
        out = subprocess.run(
            [sys.executable, PARSER, filename, series],
            capture_output=True, text=True, timeout=10,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None

    lines = out.stdout.strip().splitlines()

    if out.returncode != 0 or len(lines) < 3 or not lines[2].strip():
        return None

    return lines[0].strip() or "episode", int(lines[1] or 1), int(lines[2])


def group_label(series, kind, season):
    return {
        "movie": f"{series} (Movie)",
        "ova": f"{series} (OVA)",
        "special": f"{series} (Special)",
    }.get(kind, f"{series} Season {season}")


def within_root(path):
    root = anime_root()

    if not root:
        return True

    real_root = os.path.realpath(root)
    real_path = os.path.realpath(path)
    return real_path == real_root or real_path.startswith(real_root + os.sep)


def run_library_link():
    if not os.path.isfile(LIBRARY_LINK_SCRIPT):
        return

    with open(LIBRARY_LINK_LOG, "a") as out:
        subprocess.Popen(
            ["/usr/bin/python3", LIBRARY_LINK_SCRIPT, LIBRARY_LINK_SOURCE, LIBRARY_LINK_DEST, "--prune"],
            stdout=out, stderr=out, stdin=subprocess.DEVNULL, start_new_session=True,
        )


def cmd_download(args):
    torrent_name = args[0] if len(args) > 0 else ""
    content_path = args[1] if len(args) > 1 else ""
    save_path = args[2] if len(args) > 2 else ""
    tags = args[3] if len(args) > 3 else ""

    if not torrent_name or not save_path:
        usage()

    series = os.path.basename(save_path.rstrip("/"))
    match = re.search(r"mal:\s*(\d+)", tags, re.I)
    mal_id = int(match.group(1)) if match else None

    if not within_root(save_path):
        print(f"Skipping '{torrent_name}' -- save path '{save_path}' is outside the configured anime root ({anime_root()}).")
        return

    items = []

    if os.path.isdir(content_path):
        print(f"Processing batch: '{torrent_name}'...")
        parsed = []

        for dirpath, _dirs, files in os.walk(content_path):
            for name in files:
                if name.lower().endswith(VIDEO_EXTS):
                    parsed.append(os.path.join(dirpath, name))

        groups = set()
        results = []

        for path in sorted(parsed):
            info = parse_episode(os.path.basename(path), series)

            if info is None:
                print(f"Warning: could not parse episode number from '{os.path.basename(path)}' -- skipped.")
                continue

            results.append((path, info))
            groups.add((info[0], info[1]))

        if not parsed:
            print(f"No video files found in batch '{torrent_name}'.")

        for path, (kind, season, episode) in results:
            if len(groups) <= 1:
                key, label = series, series
            else:
                key, label = f"{series}::{kind}S{season}", group_label(series, kind, season)

            items.append({"seriesKey": key, "series": series, "groupLabel": label,
                          "kind": kind, "season": season, "episode": episode, "path": path})

        if len(groups) > 1:
            print(f"Batch '{torrent_name}' contains {len(groups)} distinct groups -- each is matched to MAL independently.")
    elif re.search("batch", torrent_name, re.I):
        print(f"Skipping '{torrent_name}' -- name suggests a batch, but content path isn't a directory.")
        return
    else:
        info = parse_episode(torrent_name, series)

        if info is None:
            print(f"Warning: could not parse episode number from '{torrent_name}' -- skipped, not added to list.")
            log(f"Unparseable download: {torrent_name!r} in {save_path!r}")
            return

        kind, season, episode = info
        items.append({"seriesKey": series, "series": series, "groupLabel": series,
                      "kind": kind, "season": season, "episode": episode, "path": content_path})

    if not items:
        return

    payload = {"items": items, "malId": mal_id}

    try:
        flush_outbox()
        result = request("POST", "/api/episodes", payload, timeout=20)
        print_result(result)
    except (Unreachable, ServerError) as e:
        with outbox_locked() as holder:
            holder["box"].append(payload)

        log(f"Queued download offline ({e}): {torrent_name}")
        print(f"{e}\nQueued locally -- it will be sent automatically once the server is reachable.")

    run_library_link()


# ---- dispatch -----------------------------------------------------

COMMANDS = {
    "state": cmd_state,
    "list": cmd_doc("episodes"),
    "history": cmd_doc("history"),
    "pending": cmd_doc("pendingMatches"),
    "series-map": cmd_doc("seriesMap"),
    "pending-grades": cmd_doc("pendingGrades"),
    "last-removed": cmd_doc("lastRemoved"),
    "batch-warnings": cmd_doc("batchWarnings"),
    "wait": cmd_wait,
    "done": cmd_done,
    "undo": cmd_undo,
    "remove-episode": cmd_remove,
    "confirm-series": cmd_confirm,
    "skip-series": cmd_skip,
    "remap-series": cmd_remap,
    "grade-series": cmd_grade,
    "skip-grade": cmd_skip_grade,
    "dismiss-batch-warning": cmd_dismiss,
    "search-only": cmd_search_only,
    "mal-list": cmd_mal_list,
    "mal-season": cmd_mal_season,
    "get-config": cmd_get_config,
    "set-config": cmd_set_config,
    "info": cmd_info,
    "flush": cmd_flush,
    "migrate": cmd_migrate,
}


def usage():
    print(
        "Usage:\n"
        "  anime-downloaded.sh TORRENT_NAME CONTENT_PATH SAVE_PATH [TAGS]   (qBittorrent hook)\n"
        "  anime-downloaded.sh info | state | flush | migrate [--force] [--no-token]\n"
        "  anime-downloaded.sh done SERIES SEASON EPISODE [KIND] | undo\n"
        "  anime-downloaded.sh remove-episode SERIES KIND SEASON EPISODE\n"
        "  anime-downloaded.sh confirm-series KEY MAL_ID [TITLE] | skip-series KEY | remap-series KEY [QUERY]\n"
        "  anime-downloaded.sh grade-series KEY SCORE | skip-grade KEY\n"
        "  anime-downloaded.sh search-only QUERY | mal-list STATUS | mal-season [popularity|score]"
    )
    sys.exit(1)


def main():
    if len(sys.argv) < 2 or sys.argv[1] in ("-h", "--help"):
        usage()

    command = COMMANDS.get(sys.argv[1])

    if command:
        command(sys.argv[2:])
    else:
        cmd_download(sys.argv[1:])


if __name__ == "__main__":
    main()
