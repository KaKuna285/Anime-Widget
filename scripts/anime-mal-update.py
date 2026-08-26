#!/usr/bin/env python3

import json
import os
import sys
import time
import urllib.parse
import urllib.request
import urllib.error
from datetime import datetime

LOG_FILE = os.path.expanduser("~/.local/share/anime-mal.log")
LOG_MAX_BYTES = 1_000_000
LOG_KEEP_LINES = 500

CONFIG = os.path.expanduser("~/.config/anime-todo/mal.conf")
TOKEN_FILE = os.path.expanduser(
    "~/.config/anime-todo/mal-token.json"
)
TOKEN_URL = "https://myanimelist.net/v1/oauth2/token"

# Refresh proactively this many seconds before the token would
# actually expire, so a slightly-early clock or slow request doesn't
# still hit a 401.
REFRESH_MARGIN_SECONDS = 300


def log(message):
    timestamp = datetime.now().isoformat(timespec="seconds")

    if (
        os.path.exists(LOG_FILE)
        and os.path.getsize(LOG_FILE) > LOG_MAX_BYTES
    ):
        try:
            with open(LOG_FILE, "r", encoding="utf-8") as f:
                lines = f.readlines()

            with open(LOG_FILE, "w", encoding="utf-8") as f:
                f.writelines(lines[-LOG_KEEP_LINES:])
        except Exception:
            # Trimming is a nice-to-have -- if it fails for any
            # reason, fall through and still write the log entry
            # rather than losing it.
            pass

    with open(LOG_FILE, "a", encoding="utf-8") as f:
        f.write(f"[{timestamp}] {message}\n")


def load_client_id():
    with open(CONFIG, "r", encoding="utf-8") as f:
        for line in f:
            if line.startswith("CLIENT_ID="):
                return line.strip().split("=", 1)[1]

    raise RuntimeError("CLIENT_ID not found in mal.conf")


def save_tokens(tokens):
    tokens["obtained_at"] = time.time()

    with open(TOKEN_FILE, "w", encoding="utf-8") as f:
        json.dump(tokens, f, indent=2)
        f.write("\n")

    os.chmod(TOKEN_FILE, 0o600)


def refresh_tokens(tokens):
    client_id = load_client_id()

    data = urllib.parse.urlencode({
        "client_id": client_id,
        "grant_type": "refresh_token",
        "refresh_token": tokens["refresh_token"],
    }).encode()

    request = urllib.request.Request(
        TOKEN_URL,
        data=data,
        headers={
            "Content-Type": "application/x-www-form-urlencoded"
        },
        method="POST",
    )

    with urllib.request.urlopen(request) as response:
        new_tokens = json.load(response)

    save_tokens(new_tokens)
    log("Refreshed MAL access token")

    return new_tokens


def load_tokens():
    with open(TOKEN_FILE, "r", encoding="utf-8") as f:
        tokens = json.load(f)

    obtained_at = tokens.get("obtained_at")
    expires_in = tokens.get("expires_in")

    if obtained_at and expires_in:
        expires_at = obtained_at + expires_in

        if time.time() >= expires_at - REFRESH_MARGIN_SECONDS:
            try:
                tokens = refresh_tokens(tokens)
            except Exception as e:
                log(
                    "Proactive token refresh failed, will retry "
                    f"reactively if needed: {e}"
                )

    return tokens


def _send(url, method, headers, data):
    request = urllib.request.Request(
        url,
        data=data,
        headers=headers,
        method=method
    )

    with urllib.request.urlopen(request) as response:
        if response.status == 204:
            return {}

        return json.load(response)


def api_request(url, method="GET", data=None):
    tokens = load_tokens()

    headers = {
        "Authorization": f"Bearer {tokens['access_token']}"
    }

    encoded_data = None

    if data is not None:
        encoded_data = urllib.parse.urlencode(data).encode()
        headers["Content-Type"] = (
            "application/x-www-form-urlencoded"
        )

    max_attempts = 3
    attempts = 0

    while True:
        attempts += 1

        try:
            return _send(url, method, headers, encoded_data)

        except urllib.error.HTTPError as e:
            if e.code == 401 and attempts < max_attempts:
                try:
                    tokens = refresh_tokens(tokens)
                except Exception as refresh_error:
                    log(f"Reactive token refresh failed: {refresh_error}")
                else:
                    headers["Authorization"] = f"Bearer {tokens['access_token']}"
                    continue

            if e.code == 429 and attempts < max_attempts:
                retry_after = e.headers.get("Retry-After") if e.headers else None

                try:
                    wait_seconds = float(retry_after) if retry_after else 2.0
                except ValueError:
                    wait_seconds = 2.0

                log(f"MAL rate limit hit (429) -- waiting {wait_seconds}s before retry")
                time.sleep(wait_seconds)
                continue

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
        f"https://api.myanimelist.net/v2/anime/{mal_id}"
        "?fields=my_list_status"
    )

    result = api_request(url)

    return result.get("my_list_status")


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


def mark_finished(mal_id, score=None):
    data = {
        "status": "completed"
    }

    if score is not None:
        data["score"] = score

    print(
        f"Marking MAL ID {mal_id} as completed"
        + (f" with score {score}" if score is not None else "")
        + "..."
    )

    url = (
        f"https://api.myanimelist.net/v2/anime/"
        f"{mal_id}/my_list_status"
    )

    result = api_request(
        url,
        method="PUT",
        data=data
    )

    log(
        f"Marked MAL ID {mal_id} as completed"
        + (f" with score {score}" if score is not None else "")
    )

    print("MAL entry marked as completed.")

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
        f"  {sys.argv[0]} --restore MAL_ID PREVIOUS_STATE_JSON\n"
        f"  {sys.argv[0]} --finish MAL_ID [SCORE]"
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

elif len(sys.argv) >= 2 and sys.argv[1] == "--finish":
    if len(sys.argv) not in (3, 4):
        print_usage()
        sys.exit(1)

    mal_id = int(sys.argv[2])
    score = int(sys.argv[3]) if len(sys.argv) == 4 else None

    try:
        mark_finished(mal_id, score)

    except Exception as e:
        log(
            f"MAL finish failed for "
            f"ID {mal_id}: {e}"
        )

        print(f"MAL finish failed: {e}")
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
