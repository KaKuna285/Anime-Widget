#!/usr/bin/env python3

import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime

CONFIG = os.path.expanduser("~/.config/anime-todo/mal.conf")
PENDING_FILE = os.path.expanduser(
    "~/.local/share/anime-pending-matches.json"
)

import contextlib
import fcntl

LOCK_FILE = os.path.expanduser("~/.local/share/anime-todo.lock")


@contextlib.contextmanager
def pending_lock():
    os.makedirs(os.path.dirname(LOCK_FILE), exist_ok=True)
    with open(LOCK_FILE, "a+") as lock_fd:
        fcntl.flock(lock_fd, fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(lock_fd, fcntl.LOCK_UN)

SEARCH_URL = "https://api.myanimelist.net/v2/anime"


def load_client_id():
    with open(CONFIG, "r", encoding="utf-8") as f:
        for line in f:
            if line.startswith("CLIENT_ID="):
                return line.strip().split("=", 1)[1]

    raise RuntimeError("CLIENT_ID not found in mal.conf")


def clean_query(name):
    text = name

    text = re.sub(r"\[[^\]]*\]", " ", text)          # [SubsPlease] etc.
    text = re.sub(r"\([^)]*\)", " ", text)            # (2020) etc.
    text = re.sub(r"\b(19|20)\d{2}\b", " ", text)      # bare years
    text = re.sub(
        r"\b(1080p|720p|480p|4k|hevc|x264|x265|bd|web-?dl)\b",
        " ",
        text,
        flags=re.I,
    )
    text = re.sub(r"\bseason\s*\d+\b", " ", text, flags=re.I)
    text = re.sub(r"\bs\d{1,2}\b", " ", text, flags=re.I)
    text = re.sub(r"[._]+", " ", text)
    text = re.sub(r"\s+", " ", text).strip()

    return text


def search_mal(query, client_id, limit=6):
    params = urllib.parse.urlencode({
        "q": query,
        "limit": limit,
        "fields": "alternative_titles,media_type,start_season,main_picture",
    })

    url = f"{SEARCH_URL}?{params}"

    request = urllib.request.Request(
        url,
        headers={"X-MAL-Client-ID": client_id},
    )

    with urllib.request.urlopen(request) as response:
        return json.load(response)

def current_season():
    now = datetime.now()
    month = now.month
    year = now.year

    if month in (1, 2, 3):
        return year, "winter"
    elif month in (4, 5, 6):
        return year, "spring"
    elif month in (7, 8, 9):
        return year, "summer"
    else:
        return year, "fall"


def fetch_season(sort):
    year, season = current_season()
    client_id = load_client_id()

    url = (
        f"https://api.myanimelist.net/v2/anime/season/{year}/{season}"
        f"?fields=alternative_titles,media_type,start_season,main_picture,mean,num_list_users"
        f"&limit=100"
    )

    results = []

    while url:
        request = urllib.request.Request(
            url,
            headers={"X-MAL-Client-ID": client_id},
        )

        with urllib.request.urlopen(request) as response:
            data = json.load(response)

        for item in data.get("data", []):
            node = item.get("node", {})

            results.append({
                "id": node.get("id"),
                "title": node.get("title"),
                "mediaType": node.get("media_type"),
                "startYear": (node.get("start_season") or {}).get("year"),
                "picture": (node.get("main_picture") or {}).get("medium"),
                "score": node.get("mean"),
                "members": node.get("num_list_users"),
            })

        url = data.get("paging", {}).get("next")

    # Don't rely on MAL's own server-side sort -- unrated/unaired
    # entries in a season frequently have no score at all, and MAL
    # doesn't reliably push those to the end, which scrambles the
    # ranking badly (confirmed: requesting fields=mean sorted by
    # anime_score returned entries with the mean field missing
    # entirely, mixed in among scored ones). Sort ourselves using
    # the actual returned values instead, with missing values always
    # pushed to the end regardless of sort mode.
    if sort == "score":
        results.sort(key=lambda r: (r["score"] is None, -(r["score"] or 0)))
    else:
        results.sort(key=lambda r: (r["members"] is None, -(r["members"] or 0)))

    return results

def load_pending():
    if not os.path.exists(PENDING_FILE):
        return {}

    with open(PENDING_FILE, "r", encoding="utf-8") as f:
        return json.load(f)


def save_pending(pending):
    os.makedirs(os.path.dirname(PENDING_FILE), exist_ok=True)

    with open(PENDING_FILE, "w", encoding="utf-8") as f:
        json.dump(pending, f, ensure_ascii=False, indent=2)
        f.write("\n")


def main():
    if len(sys.argv) >= 2 and sys.argv[1] == "--season":
        sort = sys.argv[2] if len(sys.argv) == 3 else "popularity"

        try:
            results = fetch_season(sort)
            print(json.dumps(results, ensure_ascii=False))
        except Exception as e:
            print(f"Failed to fetch seasonal anime: {e}", file=sys.stderr)
            sys.exit(1)

        return

    if len(sys.argv) not in (2, 3):
        print(f"Usage: {sys.argv[0]} SERIES_KEY [QUERY]", file=sys.stderr)
        sys.exit(1)

    series_key = sys.argv[1]
    query = sys.argv[2] if len(sys.argv) == 3 else clean_query(series_key)

    try:
        client_id = load_client_id()
        result = search_mal(query, client_id)
    except Exception as e:
        with pending_lock():
            pending = load_pending()
            pending[series_key] = {
                "status": "error",
                "query": query,
                "error": str(e),
            }
            save_pending(pending)

        print(f"MAL search failed for '{series_key}': {e}", file=sys.stderr)
        sys.exit(1)

    candidates = []

    for item in result.get("data", []):
        node = item.get("node", {})

        candidates.append({
            "id": node.get("id"),
            "title": node.get("title"),
            "mediaType": node.get("media_type"),
            "startYear": (node.get("start_season") or {}).get("year"),
            "picture": (node.get("main_picture") or {}).get("medium"),
        })

    with pending_lock():
        pending = load_pending()
        pending[series_key] = {
            "status": "ready" if candidates else "no_results",
            "query": query,
            "candidates": candidates,
        }
        save_pending(pending)

    print(
        f"Found {len(candidates)} candidate(s) for "
        f"'{series_key}' (query: '{query}')"
    )


if __name__ == "__main__":
    main()
