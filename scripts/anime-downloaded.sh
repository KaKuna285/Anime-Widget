#!/bin/bash

TODO="$HOME/.local/share/anime-todo.json"
HISTORY="$HOME/.local/share/anime-history.json"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

ensure_files() {
    mkdir -p "$(dirname "$TODO")"

    [ -f "$TODO" ] || printf '[]\n' > "$TODO"
    [ -f "$HISTORY" ] || printf '[]\n' > "$HISTORY"
}

case "$1" in
    list)
        ensure_files
        cat "$TODO"
        ;;

    history)
        ensure_files
        cat "$HISTORY"
        ;;

    done)
        SERIES="$2"
        SEASON="$3"
        EPISODE="$4"

        if [ -z "$SERIES" ] || [ -z "$SEASON" ] || [ -z "$EPISODE" ]; then
            echo "Usage: $0 done SERIES SEASON EPISODE"
            exit 1
        fi

        ensure_files

        # Find the episode and its MAL ID.
        MAL_ID="$(
            python3 - "$TODO" "$SERIES" "$SEASON" "$EPISODE" <<'PY'
import json
import sys

todo_file = sys.argv[1]
series = sys.argv[2]
season = int(sys.argv[3])
episode = int(sys.argv[4])

with open(todo_file, "r", encoding="utf-8") as f:
    todo = json.load(f)

for item in todo:
    if (
        item.get("series") == series
        and item.get("season") == season
        and item.get("episode") == episode
    ):
        mal_id = item.get("malId")
        if mal_id:
            print(mal_id)
        break
PY
        )"

        # Get the MAL state before making any change.
        MAL_PREVIOUS='{"exists":false}'

        if [ -n "$MAL_ID" ]; then
            MAL_STATUS_OUTPUT="$(
                "$SCRIPT_DIR/anime-mal-update.py" --get-status "$MAL_ID" 2>&1
            )"

            MAL_STATUS_EXIT=$?

            if [ "$MAL_STATUS_EXIT" -eq 0 ]; then
                MAL_PREVIOUS="$MAL_STATUS_OUTPUT"
            else
                echo "Warning: Could not get previous MAL state."
                echo "$MAL_STATUS_OUTPUT"
            fi
        fi

        # Move the episode from TODO to history.
        COMPLETED="$(
            python3 - "$TODO" "$HISTORY" "$SERIES" "$SEASON" "$EPISODE" "$MAL_PREVIOUS" <<'PY'
import json
import sys
from datetime import datetime

todo_file = sys.argv[1]
history_file = sys.argv[2]
series = sys.argv[3]
season = int(sys.argv[4])
episode_number = int(sys.argv[5])
mal_previous = json.loads(sys.argv[6])

with open(todo_file, "r", encoding="utf-8") as f:
    todo = json.load(f)

with open(history_file, "r", encoding="utf-8") as f:
    history = json.load(f)

remaining = []
completed = None

for episode in todo:
    if (
        episode.get("series") == series
        and episode.get("season") == season
        and episode.get("episode") == episode_number
    ):
        completed = episode
    else:
        remaining.append(episode)

if completed is not None:
    already_in_history = any(
        x.get("series") == series
        and x.get("season") == season
        and x.get("episode") == episode_number
        for x in history
    )

    if not already_in_history:
        completed["watched"] = True
        completed["watchedAt"] = datetime.now().isoformat(timespec="seconds")
        completed["malPrevious"] = mal_previous
        history.append(completed)

with open(todo_file, "w", encoding="utf-8") as f:
    json.dump(remaining, f, ensure_ascii=False, indent=2)
    f.write("\n")

with open(history_file, "w", encoding="utf-8") as f:
    json.dump(history, f, ensure_ascii=False, indent=2)
    f.write("\n")

print("yes" if completed is not None else "no")
PY
        )"

        # Only update MAL if this was actually a TODO episode.
        if [ "$COMPLETED" = "yes" ] && [ -n "$MAL_ID" ]; then
            echo "Updating MAL..."
            "$SCRIPT_DIR/anime-mal-update.py" "$MAL_ID" "$EPISODE"
        fi
        ;;

    undo)
        ensure_files

        # Get the last history entry.
        LAST_ENTRY="$(
            python3 - "$HISTORY" <<'PY'
import json
import sys

history_file = sys.argv[1]

with open(history_file, "r", encoding="utf-8") as f:
    history = json.load(f)

if history:
    print(json.dumps(history[-1], ensure_ascii=False))
PY
        )"

        if [ -z "$LAST_ENTRY" ]; then
            echo "Nothing to undo."
            exit 1
        fi

        echo "Last completed episode:"
        echo "$LAST_ENTRY"

        # Extract the MAL ID and previous state.
        MAL_ID="$(
            printf '%s' "$LAST_ENTRY" |
            python3 -c '
import json
import sys

item = json.load(sys.stdin)
mal_id = item.get("malId")

if mal_id:
    print(mal_id)
'
        )"

        MAL_PREVIOUS="$(
            printf '%s' "$LAST_ENTRY" |
            python3 -c '
import json
import sys

item = json.load(sys.stdin)
print(json.dumps(
    item.get("malPrevious", {"exists": False}),
    separators=(",", ":")
))
'
        )"

        # Restore MAL first.
        if [ -n "$MAL_ID" ]; then
            echo "Restoring MAL state..."

            "$SCRIPT_DIR/anime-mal-update.py" \
                --restore "$MAL_ID" "$MAL_PREVIOUS"

            if [ $? -ne 0 ]; then
                echo "MAL restore failed."
                echo "History was NOT changed."
                exit 1
            fi
        fi

        # MAL succeeded. Now move the entry back to TODO
        # and remove it from history.
        python3 - "$TODO" "$HISTORY" <<'PY'
import json
import sys

todo_file = sys.argv[1]
history_file = sys.argv[2]

with open(todo_file, "r", encoding="utf-8") as f:
    todo = json.load(f)

with open(history_file, "r", encoding="utf-8") as f:
    history = json.load(f)

if not history:
    print("Nothing to undo.")
    sys.exit(1)

episode = history[-1]

# Don't add a duplicate TODO entry.
already_in_todo = any(
    x.get("series") == episode.get("series")
    and x.get("season") == episode.get("season")
    and x.get("episode") == episode.get("episode")
    for x in todo
)

if not already_in_todo:
    episode["watched"] = False
    episode.pop("watchedAt", None)
    episode.pop("malPrevious", None)
    todo.append(episode)

history.pop()

with open(todo_file, "w", encoding="utf-8") as f:
    json.dump(todo, f, ensure_ascii=False, indent=2)
    f.write("\n")

with open(history_file, "w", encoding="utf-8") as f:
    json.dump(history, f, ensure_ascii=False, indent=2)
    f.write("\n")

print(
    f"Undo successful: "
    f"{episode.get('series')} "
    f"S{episode.get('season'):02d}"
    f"E{episode.get('episode'):02d}"
)
PY
        ;;

    *)
        TORRENT_NAME="$1"
        CONTENT_PATH="$2"
        SAVE_PATH="$3"
	TAGS="$4"

	MAL_ID="$(printf '%s' "$TAGS" | grep -oEi 'mal:[[:space:]]*[0-9]+' | grep -oE '[0-9]+')"

        SERIES="$(basename "$SAVE_PATH")"

        EPISODE_CODE="$(printf '%s' "$TORRENT_NAME" | grep -oEi 'S[0-9]{1,2}E[0-9]{1,4}' | head -1 | tr '[:lower:]' '[:upper:]')"

	if [ -n "$EPISODE_CODE" ]; then
	    SEASON="$(printf '%s' "$EPISODE_CODE" | grep -oEi '^S[0-9]+' | grep -oE '[0-9]+')"
	    EPISODE="$(printf '%s' "$EPISODE_CODE" | grep -oEi 'E[0-9]+' | grep -oE '[0-9]+')"
	fi

        if [ -n "$EPISODE" ]; then
            ensure_files
            python3 - "$TODO" "$SERIES" "$SEASON" "$EPISODE" "$CONTENT_PATH" "$MAL_ID" <<'PY'

import json
import sys

todo_file = sys.argv[1]
series = sys.argv[2]
season = int(sys.argv[3])
episode = int(sys.argv[4])
path = sys.argv[5]
mal_id = int(sys.argv[6]) if sys.argv[6] else None


with open(todo_file, "r", encoding="utf-8") as f:
    todo = json.load(f)

item = {
    "series": series,
    "season": season,
    "episode": episode,
    "path": path,
    "malId": mal_id,
    "watched": False
}

if not any(
    x.get("series") == series
    and x.get("season") == season
    and x.get("episode") == episode
    for x in todo
):
    todo.append(item)

with open(todo_file, "w", encoding="utf-8") as f:
    json.dump(todo, f, ensure_ascii=False, indent=2)
    f.write("\n")
PY
        fi
        ;;
esac
