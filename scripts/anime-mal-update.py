#!/usr/bin/env python3

import json
import os
import sys
import urllib.parse
import urllib.request
import urllib.error
from datetime import datetime

LOG_FILE = os.path.expanduser("~/.local/share/anime-mal.log")

TOKEN_FILE = os.path.expanduser(
    "~/.config/anime-todo/mal-token.json"
)


def log(message):
    timestamp = datetime.now().isoformat(timespec="seconds")

    with open(LOG_FILE, "a", encoding="utf-8") as f:
        f.write(f"[{timestamp}] {message}\n")


def load_tokens():
    with open(TOKEN_FILE, "r", encoding="utf-8") as f:
        return json.load(f)


def api_request(url, method="GET", data=None):
    tokens = load_tokens()

    headers = {
        "Authorization": f"Bearer {tokens['access_token']}"
    }

    if data is not None:
        data = urllib.parse.urlencode(data).encode()
        headers["Content-Type"] = (
            "application/x-www-form-urlencoded"
        )

    request = urllib.request.Request(
        url,
        data=data,
        headers=headers,
        method=method
    )

    try:
        with urllib.request.urlopen(request) as response:
            if response.status == 204:
                return {}

            return json.load(response)

    except urllib.error.HTTPError as e:
        error_body = ""

        try:
            error_body = e.read().decode(
                "utf-8",
                errors="replace"
            )
        except Exception:
            pass

        raise RuntimeError(
            f"MAL API error: HTTP {e.code} {error_body}"
        ) from e


def get_list_status(mal_id):
    url = (
        "https://api.myanimelist.net/v2/users/@me/animelist"
        "?limit=100"
        "&fields=list_status"
    )

    while url:
        result = api_request(url)

        for entry in result.get("data", []):
            node = entry.get("node", {})

            if node.get("id") == mal_id:
                return entry.get("list_status")

        url = result.get("paging", {}).get("next")

    return None


def get_previous_state(mal_id):
    current = get_list_status(mal_id)

    if current is None:
        return {
            "exists": False
        }

    return {
        "exists": True,
        "status": current.get("status"),
        "num_episodes_watched": current.get(
            "num_episodes_watched",
            0
        )
    }


def add_to_list(mal_id, episode):
    print(
        f"Anime {mal_id} is not on your MAL list."
    )

    print(
        f"Adding it as Watching with "
        f"{episode} episode(s) watched..."
    )

    url = (
        f"https://api.myanimelist.net/v2/anime/"
        f"{mal_id}/my_list_status"
    )

    result = api_request(
        url,
        method="PUT",
        data={
            "status": "watching",
            "num_watched_episodes": episode
        }
    )

    log(
        f"Successfully added MAL ID {mal_id} "
        f"with episode {episode}"
    )

    print("Anime added to MAL successfully.")

    print(
        json.dumps(
            result,
            indent=2,
            ensure_ascii=False
        )
    )


def update_watched(mal_id, episode):
    current = get_list_status(mal_id)

    if current is None:
        previous_state = {
            "exists": False
        }
    else:
        previous_state = {
            "exists": True,
            "status": current.get("status"),
            "num_episodes_watched": current.get(
                "num_episodes_watched",
                0
            )
        }

    print(
        "PREVIOUS_STATE:"
        + json.dumps(
            previous_state,
            separators=(",", ":")
        )
    )

    if current is None:
        add_to_list(mal_id, episode)
        return

    current_watched = current.get(
        "num_episodes_watched",
        0
    )

    status = current.get(
        "status",
        "unknown"
    )

    print(
        f"MAL status: {status}"
    )

    print(
        f"MAL currently has "
        f"{current_watched} episodes watched."
    )

    print(
        f"Episode being checked: {episode}"
    )

    new_watched = max(
        current_watched,
        episode
    )

    if new_watched == current_watched:
        print(
            f"MAL is already at "
            f"{current_watched} episodes."
        )

        log(
            f"MAL ID {mal_id} already at "
            f"{current_watched} episodes; "
            f"checked episode {episode}"
        )

        return

    print(
        f"Updating MAL from "
        f"{current_watched} to "
        f"{new_watched} episodes..."
    )

    url = (
        f"https://api.myanimelist.net/v2/anime/"
        f"{mal_id}/my_list_status"
    )

    result = api_request(
        url,
        method="PUT",
        data={
            "num_watched_episodes": new_watched
        }
    )

    log(
        f"Successfully updated MAL ID {mal_id} "
        f"to episode {episode}"
    )

    print("MAL updated successfully.")

    print(
        json.dumps(
            result,
            indent=2,
            ensure_ascii=False
        )
    )


def restore_state(mal_id, previous_state):
    print(
        "Restoring MAL ID "
        f"{mal_id} to previous state:"
    )

    print(
        json.dumps(
            previous_state,
            indent=2,
            ensure_ascii=False
        )
    )

    if not previous_state.get("exists", False):
        print(
            "Anime was not previously on the MAL list."
        )

        url = (
            f"https://api.myanimelist.net/v2/anime/"
            f"{mal_id}/my_list_status"
        )

        try:
            api_request(
                url,
                method="DELETE"
            )
        except RuntimeError as e:
            # A 404 means it is already absent, which is
            # exactly the state we want.
            if "HTTP 404" not in str(e):
                raise

        log(
            f"Restored MAL ID {mal_id}: removed from list"
        )

        print(
            "Anime removed from MAL successfully."
        )

        return

    status = previous_state.get("status")
    watched = previous_state.get(
        "num_episodes_watched",
        0
    )

    if not status:
        raise RuntimeError(
            "Previous MAL state has no status."
        )

    print(
        f"Restoring status '{status}' "
        f"with {watched} episode(s) watched..."
    )

    url = (
        f"https://api.myanimelist.net/v2/anime/"
        f"{mal_id}/my_list_status"
    )

    result = api_request(
        url,
        method="PUT",
        data={
            "status": status,
            "num_watched_episodes": watched
        }
    )

    log(
        f"Restored MAL ID {mal_id}: "
        f"status={status}, episodes={watched}"
    )

    print("MAL state restored successfully.")

    print(
        json.dumps(
            result,
            indent=2,
            ensure_ascii=False
        )
    )


def print_usage():
    print(
        f"Usage:\n"
        f"  {sys.argv[0]} MAL_ID EPISODE\n"
        f"  {sys.argv[0]} --get-status MAL_ID\n"
        f"  {sys.argv[0]} --restore MAL_ID PREVIOUS_STATE_JSON"
    )


if len(sys.argv) >= 2 and sys.argv[1] == "--get-status":
    if len(sys.argv) != 3:
        print_usage()
        sys.exit(1)

    mal_id = int(sys.argv[2])

    try:
        state = get_previous_state(mal_id)

        print(
            json.dumps(
                state,
                indent=2,
                ensure_ascii=False
            )
        )

    except Exception as e:
        log(
            f"MAL status check failed for "
            f"ID {mal_id}: {e}"
        )

        print(f"MAL status check failed: {e}")
        sys.exit(1)

elif len(sys.argv) >= 2 and sys.argv[1] == "--restore":
    if len(sys.argv) != 4:
        print_usage()
        sys.exit(1)

    mal_id = int(sys.argv[2])

    try:
        previous_state = json.loads(sys.argv[3])
    except json.JSONDecodeError as e:
        print(
            f"Invalid previous state JSON: {e}"
        )
        sys.exit(1)

    try:
        restore_state(
            mal_id,
            previous_state
        )

    except Exception as e:
        log(
            f"MAL restore failed for "
            f"ID {mal_id}: {e}"
        )

        print(f"MAL restore failed: {e}")
        sys.exit(1)

else:
    if len(sys.argv) != 3:
        print_usage()
        sys.exit(1)

    mal_id = int(sys.argv[1])
    episode = int(sys.argv[2])

    try:
        update_watched(
            mal_id,
            episode
        )

    except Exception as e:
        log(
            f"MAL update failed for "
            f"ID {mal_id}, episode {episode}: {e}"
        )

        print(f"MAL update failed: {e}")
        sys.exit(1)
