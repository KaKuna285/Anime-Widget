#!/bin/bash

TODO="$HOME/.local/share/anime-todo.json"
HISTORY="$HOME/.local/share/anime-history.json"
SERIES_MAP="$HOME/.local/share/anime-series-map.json"
PENDING="$HOME/.local/share/anime-pending-matches.json"
PENDING_GRADES="$HOME/.local/share/anime-pending-grades.json"
BATCH_WARNINGS="$HOME/.local/share/anime-batch-warnings.json"
LAST_REMOVED="$HOME/.local/share/anime-last-removed.json"

LOCK_FILE="$HOME/.local/share/anime-todo.lock"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PENDING_TIMEOUT_SECONDS=120

CONFIG_FILE="$HOME/.config/anime-todo/anime-todo.conf"
ANIME_ROOT=""

if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
fi

ensure_files() {
    mkdir -p "$(dirname "$TODO")"

    [ -f "$TODO" ] || printf '[]\n' > "$TODO"
    [ -f "$HISTORY" ] || printf '[]\n' > "$HISTORY"
    [ -f "$SERIES_MAP" ] || printf '{}\n' > "$SERIES_MAP"
    [ -f "$PENDING" ] || printf '{}\n' > "$PENDING"
    [ -f "$PENDING_GRADES" ] || printf '{}\n' > "$PENDING_GRADES"
    [ -f "$BATCH_WARNINGS" ] || printf '{}\n' > "$BATCH_WARNINGS"
    [ -f "$LAST_REMOVED" ] || printf '{}\n' > "$LAST_REMOVED"
    [ -f "$LOCK_FILE" ] || : > "$LOCK_FILE"
}

# Runs "$@" as a command while holding an exclusive lock on LOCK_FILE,
# so concurrent anime-downloaded.sh invocations can't race on reading
# and rewriting the JSON data files. Blocks (waits) rather than
# failing if another instance already holds the lock.
with_lock() {
    (
        flock -x 200
        "$@"
    ) 200>"$LOCK_FILE"
}

# Returns true (0) if PATH is inside the configured ANIME_ROOT (or
# is ANIME_ROOT itself), or if ANIME_ROOT isn't configured at all --
# in which case nothing is restricted, preserving existing behavior
# until the user opts in.
is_within_anime_root() {
    if [ -z "$ANIME_ROOT" ]; then
        return 0
    fi

    local path="$1"
    local resolved_path
    local resolved_root

    resolved_path="$(realpath -m "$path" 2>/dev/null)"
    resolved_root="$(realpath -m "$ANIME_ROOT" 2>/dev/null)"

    if [ -z "$resolved_path" ] || [ -z "$resolved_root" ]; then
        return 1
    fi

    case "$resolved_path" in
        "$resolved_root"|"$resolved_root"/*)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# Writes a "searching" placeholder into PENDING for SERIES so that
# concurrent episode completions don't each trigger their own search.
mark_pending() {
    local series="$1"
    local query="$2"

    python3 - "$PENDING" "$series" "$query" <<'PY'
import json
import sys
import time

pending_file = sys.argv[1]
series = sys.argv[2]
query = sys.argv[3]

with open(pending_file, "r", encoding="utf-8") as f:
    pending = json.load(f)

pending[series] = {
    "status": "searching",
    "query": query,
    "startedAt": time.time()
}

with open(pending_file, "w", encoding="utf-8") as f:
    json.dump(pending, f, ensure_ascii=False, indent=2)
    f.write("\n")
PY
}

# Kicks off the MAL search for a newly-seen series. Safe to call even
# before anime-mal-search.py exists -- it just becomes a no-op that
# leaves the episode unmatched until you run step 2.
start_series_search() {
    local series="$1"

    mark_pending "$series" "$series"

    if [ -x "$SCRIPT_DIR/anime-mal-search.py" ]; then
        "$SCRIPT_DIR/anime-mal-search.py" "$series" >/dev/null 2>&1 200>&- &
        disown
    else
        echo "anime-mal-search.py not found yet -- '$series' queued, will stay unmatched until it exists."
    fi
}

# Produces a short human-readable label for a (kind, season) group,
# used when a batch spans multiple groups and each needs its own
# distinct MAL-matching identity.
group_label() {
    local series="$1"
    local kind="$2"
    local season="$3"

    case "$kind" in
        movie)
            echo "$series (Movie)"
            ;;
        ova)
            echo "$series (OVA)"
            ;;
        special)
            echo "$series (Special)"
            ;;
        *)
            echo "$series Season $season"
            ;;
    esac
}

# Runs the user's external anime-library linking script (if
# configured) in the background after a real download was
# successfully processed. Never blocks anime-downloaded.sh --
# backgrounded and detached, same pattern as the MAL search calls.
# Safe to leave configured even if the script doesn't exist on this
# machine; it just silently no-ops.
LIBRARY_LINK_SCRIPT="$HOME/scripts/anime_link.py"
LIBRARY_LINK_SOURCE="$HOME/Anime"
LIBRARY_LINK_DEST="$HOME/AnimeLibrary"
LIBRARY_LINK_LOG="$HOME/scripts/anime_link.log"

run_library_link() {
    if [ ! -f "$LIBRARY_LINK_SCRIPT" ]; then
        return
    fi

    (
        /usr/bin/python3 "$LIBRARY_LINK_SCRIPT" "$LIBRARY_LINK_SOURCE" "$LIBRARY_LINK_DEST" --prune >> "$LIBRARY_LINK_LOG" 2>&1
    ) &
    disown
}

# Queues a single, already-parsed episode/movie/OVA/special from
# inside a batch torrent under the given MAL-matching identity
# (SERIES_KEY may be the plain folder name, or a composite
# "<folder>::<kind>S<season>" key when the batch spans multiple
# distinct groups). DISPLAY_SERIES is always the plain folder name,
# used for the TODO entry's "series" field (widget grouping/display)
# regardless of which identity key was used for MAL matching.
process_one_episode() {
    local series_key="$1"
    local display_series="$2"
    local group_label_text="$3"
    local kind="$4"
    local season="$5"
    local episode="$6"
    local file_path="$7"

    local needs_search
    needs_search="$(
        python3 - "$SERIES_MAP" "$PENDING" "$TODO" "$series_key" "$display_series" "$kind" "$season" "$episode" "$file_path" "$MAL_ID" "$PENDING_TIMEOUT_SECONDS" <<'PY'
import json
import sys
import time

series_map_file = sys.argv[1]
pending_file = sys.argv[2]
todo_file = sys.argv[3]
series_key = sys.argv[4]
display_series = sys.argv[5]
kind = sys.argv[6]
season = int(sys.argv[7])
episode = int(sys.argv[8])
path = sys.argv[9]
explicit_mal_id = int(sys.argv[10]) if sys.argv[10] else None
pending_timeout = int(sys.argv[11])

with open(series_map_file, "r", encoding="utf-8") as f:
    series_map = json.load(f)

entry = series_map.get(series_key)

mal_id = explicit_mal_id
needs_search = False

if mal_id is None:
    if entry and entry.get("malId"):
        mal_id = entry["malId"]
    elif entry and entry.get("skipped"):
        pass
    else:
        with open(pending_file, "r", encoding="utf-8") as f:
            pending = json.load(f)

        pending_entry = pending.get(series_key)

        if pending_entry is None:
            needs_search = True
        else:
            status = pending_entry.get("status")

            if status == "error":
                needs_search = True
            elif status == "searching":
                started_at = pending_entry.get("startedAt")

                if (
                    started_at is None
                    or (time.time() - started_at) > pending_timeout
                ):
                    needs_search = True

with open(todo_file, "r", encoding="utf-8") as f:
    todo = json.load(f)

item = {
    "series": display_series,
    "seriesKey": series_key,
    "kind": kind,
    "season": season,
    "episode": episode,
    "path": path,
    "malId": mal_id,
    "watched": False
}

if not any(
    x.get("seriesKey", x.get("series")) == series_key
    and x.get("kind", "episode") == kind
    and x.get("season") == season
    and x.get("episode") == episode
    for x in todo
):
    todo.append(item)

    with open(todo_file, "w", encoding="utf-8") as f:
        json.dump(todo, f, ensure_ascii=False, indent=2)
        f.write("\n")

print("yes" if needs_search else "no")
PY
    )"

    if [ $? -ne 0 ]; then
        echo "Failed to queue episode for '$series_key':"
        echo "$needs_search"
        return
    fi

    if [ "$needs_search" = "yes" ]; then
        mark_pending "$series_key" "$group_label_text"

        if [ -x "$SCRIPT_DIR/anime-mal-search.py" ]; then
            "$SCRIPT_DIR/anime-mal-search.py" "$series_key" "$group_label_text" >/dev/null 2>&1 200>&- &
            disown
        else
            echo "anime-mal-search.py not found -- '$series_key' queued, will stay unmatched until it exists."
        fi
    fi
}

case "$1" in
    list)
        ensure_files
        (
            flock -s 200
            cat "$TODO"
        ) 200>"$LOCK_FILE"
        ;;

    history)
        ensure_files

        (
            flock -s 200
            cat "$HISTORY"
        ) 200>"$LOCK_FILE"
        ;;

    done)
        SERIES="$2"
        SEASON="$3"
        EPISODE="$4"
        KIND="${5:-episode}"

        if [ -z "$SERIES" ] || [ -z "$SEASON" ] || [ -z "$EPISODE" ]; then
            echo "Usage: $0 done SERIES SEASON EPISODE [KIND]"
            exit 1
        fi

        ensure_files

        (
            flock -x 200

            # Find the episode and its MAL ID.
            MAL_ID="$(
                python3 - "$TODO" "$SERIES" "$SEASON" "$EPISODE" "$KIND" <<'PY'
import json
import sys

todo_file = sys.argv[1]
series = sys.argv[2]
season = int(sys.argv[3])
episode = int(sys.argv[4])
kind = sys.argv[5]

with open(todo_file, "r", encoding="utf-8") as f:
    todo = json.load(f)

for item in todo:
    if (
        item.get("series") == series
        and item.get("season") == season
        and item.get("episode") == episode
        and item.get("kind", "episode") == kind
    ):
        mal_id = item.get("malId")
        if mal_id:
            print(mal_id)
        break
PY
            )"

                        if [ $? -ne 0 ]; then
                echo "Failed to look up episode in TODO list -- aborting."
                exit 1
            fi

            # Update MAL *before* moving the episode to history. If
            # anything here fails, the episode stays in TODO rather
            # than silently disappearing as if it had succeeded.
            MAL_PREVIOUS='{"exists":false}'

            if [ -n "$MAL_ID" ]; then
                MAL_STATUS_OUTPUT="$(
                    "$SCRIPT_DIR/anime-mal-update.py" --get-status "$MAL_ID"
                )"

                if [ $? -ne 0 ]; then
                    echo "MAL status check failed:"
                    echo "$MAL_STATUS_OUTPUT"
                    echo "Aborting -- episode NOT marked done."
                    exit 1
                fi

                MAL_PREVIOUS="$MAL_STATUS_OUTPUT"

                echo "Updating MAL..."

                MAL_UPDATE_OUTPUT="$("$SCRIPT_DIR/anime-mal-update.py" "$MAL_ID" "$EPISODE" 2>&1)"

                if [ $? -ne 0 ]; then
                    echo "$MAL_UPDATE_OUTPUT"
                    echo "MAL update failed -- episode NOT marked done."
                    exit 1
                fi

                echo "$MAL_UPDATE_OUTPUT"
            fi

            # MAL succeeded (or there's no malId to sync) -- now move
            # the episode from TODO to history.
            RESULT_INFO="$(
                python3 - "$TODO" "$HISTORY" "$SERIES" "$SEASON" "$EPISODE" "$MAL_PREVIOUS" "$SERIES_MAP" "$KIND" <<'PY'
import json
import sys
from datetime import datetime

todo_file = sys.argv[1]
history_file = sys.argv[2]
series = sys.argv[3]
season = int(sys.argv[4])
episode_number = int(sys.argv[5])
mal_previous = json.loads(sys.argv[6])
series_map_file = sys.argv[7]
kind = sys.argv[8]

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
        and episode.get("kind", "episode") == kind
    ):
        completed = episode
    else:
        remaining.append(episode)

is_final = False
final_mal_id = ""
final_title = ""

if completed is not None:
    already_in_history = any(
        x.get("series") == series
        and x.get("season") == season
        and x.get("episode") == episode_number
        and x.get("kind", "episode") == kind
        for x in history
    )

    if not already_in_history:
        completed["watched"] = True
        completed["watchedAt"] = datetime.now().isoformat(timespec="seconds")
        completed["malPrevious"] = mal_previous
        history.append(completed)

    with open(series_map_file, "r", encoding="utf-8") as f:
        series_map = json.load(f)

    map_entry = series_map.get(series)

    if map_entry:
        num_episodes = map_entry.get("numEpisodes")
        mal_id = map_entry.get("malId")

        if num_episodes and mal_id and episode_number >= num_episodes:
            is_final = True
            final_mal_id = str(mal_id)
            final_title = map_entry.get("title") or series

with open(todo_file, "w", encoding="utf-8") as f:
    json.dump(remaining, f, ensure_ascii=False, indent=2)
    f.write("\n")

with open(history_file, "w", encoding="utf-8") as f:
    json.dump(history, f, ensure_ascii=False, indent=2)
    f.write("\n")

print("yes" if completed is not None else "no")
print("yes" if is_final else "no")
print(final_mal_id)
print(final_title)
PY
            )"

            if [ $? -ne 0 ]; then
                echo "MAL was updated, but saving locally failed:"
                echo "$RESULT_INFO"
                echo "MAL and your local list may now be out of sync -- check manually."
                exit 1
            fi

            mapfile -t RESULT_LINES <<< "$RESULT_INFO"
            COMPLETED="${RESULT_LINES[0]}"
            IS_FINAL="${RESULT_LINES[1]}"
            FINAL_MAL_ID="${RESULT_LINES[2]}"
            FINAL_TITLE="${RESULT_LINES[3]}"

            if [ "$IS_FINAL" = "yes" ] && [ -n "$FINAL_MAL_ID" ]; then
                python3 - "$PENDING_GRADES" "$SERIES" "$FINAL_MAL_ID" "$FINAL_TITLE" <<'PY'
import json
import sys

pending_grades_file = sys.argv[1]
series = sys.argv[2]
mal_id = int(sys.argv[3])
title = sys.argv[4]

with open(pending_grades_file, "r", encoding="utf-8") as f:
    pending_grades = json.load(f)

pending_grades[series] = {
    "malId": mal_id,
    "title": title
}

with open(pending_grades_file, "w", encoding="utf-8") as f:
    json.dump(pending_grades, f, ensure_ascii=False, indent=2)
    f.write("\n")
PY
            fi
        ) 200>"$LOCK_FILE"
        ;;

    undo)
        ensure_files

        (
            flock -x 200

            UNDO_TARGET="$(
                python3 - "$HISTORY" "$LAST_REMOVED" <<'PY'
import json
import sys

history_file = sys.argv[1]
last_removed_file = sys.argv[2]

with open(history_file, "r", encoding="utf-8") as f:
    history = json.load(f)

with open(last_removed_file, "r", encoding="utf-8") as f:
    last_removed = json.load(f)

history_at = history[-1].get("watchedAt") if history else None
removed_at = last_removed.get("removedAt") if last_removed else None

if history_at is None and removed_at is None:
    print("none")
elif removed_at is None:
    print("history")
elif history_at is None:
    print("removal")
elif removed_at > history_at:
    print("removal")
else:
    print("history")
PY
            )"

            if [ $? -ne 0 ]; then
                echo "Failed to determine what to undo:"
                echo "$UNDO_TARGET"
                exit 1
            fi

            if [ "$UNDO_TARGET" = "none" ]; then
                echo "Nothing to undo."
                exit 1
            fi

            if [ "$UNDO_TARGET" = "removal" ]; then
                RESTORE_RESULT="$(
                    python3 - "$TODO" "$LAST_REMOVED" <<'PY'
import json
import sys

todo_file = sys.argv[1]
last_removed_file = sys.argv[2]

with open(last_removed_file, "r", encoding="utf-8") as f:
    entry = json.load(f)

if not entry:
    print("Nothing to undo.")
    sys.exit(1)

entry.pop("removedAt", None)

with open(todo_file, "r", encoding="utf-8") as f:
    todo = json.load(f)

already_present = any(
    x.get("series") == entry.get("series")
    and x.get("kind", "episode") == entry.get("kind", "episode")
    and x.get("season") == entry.get("season")
    and x.get("episode") == entry.get("episode")
    for x in todo
)

if not already_present:
    todo.append(entry)

    with open(todo_file, "w", encoding="utf-8") as f:
        json.dump(todo, f, ensure_ascii=False, indent=2)
        f.write("\n")

with open(last_removed_file, "w", encoding="utf-8") as f:
    json.dump({}, f, ensure_ascii=False, indent=2)
    f.write("\n")

print(
    f"Restored removed episode: "
    f"{entry.get('series')} "
    f"S{entry.get('season'):02d}"
    f"E{entry.get('episode'):02d}"
)
PY
                )"

                if [ $? -ne 0 ]; then
                    echo "Failed to restore removed episode:"
                    echo "$RESTORE_RESULT"
                    exit 1
                fi

                echo "$RESTORE_RESULT"
            else
                # Get the last history entry plus its MAL id / previous
                # state in one pass instead of three separate python3
                # invocations.
                UNDO_INFO="$(
                    python3 - "$HISTORY" <<'PY'
import json
import sys

history_file = sys.argv[1]

with open(history_file, "r", encoding="utf-8") as f:
    history = json.load(f)

if history:
    item = history[-1]
    print(json.dumps(item, ensure_ascii=False))
    print(item.get("malId") or "")
    print(json.dumps(
        item.get("malPrevious", {"exists": False}),
        separators=(",", ":")
    ))
PY
                )"

                UNDO_EXIT=$?

                if [ $UNDO_EXIT -ne 0 ]; then
                    echo "Failed to read history:"
                    echo "$UNDO_INFO"
                    exit 1
                fi

                if [ -z "$UNDO_INFO" ]; then
                    echo "Nothing to undo."
                    exit 1
                fi

                mapfile -t UNDO_LINES <<< "$UNDO_INFO"
                LAST_ENTRY="${UNDO_LINES[0]}"
                MAL_ID="${UNDO_LINES[1]}"
                MAL_PREVIOUS="${UNDO_LINES[2]}"

                echo "Last completed episode:"
                echo "$LAST_ENTRY"

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

already_in_todo = any(
    x.get("series") == episode.get("series")
    and x.get("season") == episode.get("season")
    and x.get("episode") == episode.get("episode")
    and x.get("kind", "episode") == episode.get("kind", "episode")
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
            fi
        ) 200>"$LOCK_FILE"
        ;;

    confirm-series)
        SERIES="$2"
        MAL_ID="$3"
        TITLE="$4"

        if [ -z "$SERIES" ] || [ -z "$MAL_ID" ]; then
            echo "Usage: $0 confirm-series SERIES MAL_ID [TITLE]"
            exit 1
        fi

        ensure_files

        NUM_EPISODES=""
        ENGLISH_TITLE=""

        if [ -x "$SCRIPT_DIR/anime-mal-details.py" ]; then
            DETAILS_OUTPUT="$("$SCRIPT_DIR/anime-mal-details.py" "$MAL_ID" 2>/dev/null)"

            if [ -n "$DETAILS_OUTPUT" ]; then
                mapfile -t DETAILS_LINES <<< "$DETAILS_OUTPUT"
                NUM_EPISODES="${DETAILS_LINES[0]}"
                ENGLISH_TITLE="${DETAILS_LINES[1]}"
            fi
        fi

        (
            flock -x 200

            python3 - "$SERIES_MAP" "$PENDING" "$TODO" "$SERIES" "$MAL_ID" "$TITLE" "$NUM_EPISODES" "$ENGLISH_TITLE" <<'PY'
import json
import sys

map_file = sys.argv[1]
pending_file = sys.argv[2]
todo_file = sys.argv[3]
series = sys.argv[4]
mal_id = int(sys.argv[5])
title = sys.argv[6] or series
num_episodes = int(sys.argv[7]) if sys.argv[7] else None
english_title = sys.argv[8] if len(sys.argv) > 8 and sys.argv[8] else None

with open(map_file, "r", encoding="utf-8") as f:
    series_map = json.load(f)

series_map[series] = {
    "malId": mal_id,
    "title": title,
    "englishTitle": english_title,
    "numEpisodes": num_episodes,
    "confirmed": True
}

with open(map_file, "w", encoding="utf-8") as f:
    json.dump(series_map, f, ensure_ascii=False, indent=2)
    f.write("\n")

with open(pending_file, "r", encoding="utf-8") as f:
    pending = json.load(f)

pending.pop(series, None)

with open(pending_file, "w", encoding="utf-8") as f:
    json.dump(pending, f, ensure_ascii=False, indent=2)
    f.write("\n")

# Backfill malId on any already-queued episodes for this series.
with open(todo_file, "r", encoding="utf-8") as f:
    todo = json.load(f)

changed = False

for item in todo:
    if (
        item.get("seriesKey", item.get("series")) == series
        and item.get("malId") != mal_id
    ):
        item["malId"] = mal_id
        changed = True

if changed:
    with open(todo_file, "w", encoding="utf-8") as f:
        json.dump(todo, f, ensure_ascii=False, indent=2)
        f.write("\n")

print(f"Mapped '{series}' -> MAL {mal_id} ({title})")
PY
        ) 200>"$LOCK_FILE"
        ;;


    pending)
        ensure_files
        (
            flock -s 200
            cat "$PENDING"
        ) 200>"$LOCK_FILE"
        ;;

    skip-series)
        SERIES="$2"

        if [ -z "$SERIES" ]; then
            echo "Usage: $0 skip-series SERIES"
            exit 1
        fi

        ensure_files

        (
            flock -x 200

        python3 - "$SERIES_MAP" "$PENDING" "$SERIES" <<'PY'
import json
import sys

map_file = sys.argv[1]
pending_file = sys.argv[2]
series = sys.argv[3]

with open(map_file, "r", encoding="utf-8") as f:
    series_map = json.load(f)

series_map[series] = {
    "malId": None,
    "skipped": True
}

with open(map_file, "w", encoding="utf-8") as f:
    json.dump(series_map, f, ensure_ascii=False, indent=2)
    f.write("\n")

with open(pending_file, "r", encoding="utf-8") as f:
    pending = json.load(f)

pending.pop(series, None)

with open(pending_file, "w", encoding="utf-8") as f:
    json.dump(pending, f, ensure_ascii=False, indent=2)
    f.write("\n")
PY

        if [ $? -ne 0 ]; then
            echo "Failed to mark '$SERIES' as skipped."
            exit 1
        fi

        echo "Marked '$SERIES' as skipped -- won't prompt for MAL matching again."
        ) 200>"$LOCK_FILE"
        ;;

    series-map)
        ensure_files
        (
            flock -s 200
            cat "$SERIES_MAP"
        ) 200>"$LOCK_FILE"
        ;;

    remap-series)
        SERIES="$2"
        QUERY="$3"

        if [ -z "$SERIES" ]; then
            echo "Usage: $0 remap-series SERIES [QUERY]"
            exit 1
        fi

        if [ -z "$QUERY" ]; then
            # Strip a "::kindSNN" group suffix (from multi-group
            # batches) so the default search query is clean, not the
            # raw internal identity key.
            QUERY="${SERIES%%::*}"
        fi

        ensure_files
        (
            flock -x 200

        mark_pending "$SERIES" "$QUERY"

        if [ -x "$SCRIPT_DIR/anime-mal-search.py" ]; then
            "$SCRIPT_DIR/anime-mal-search.py" "$SERIES" "$QUERY" >/dev/null 2>&1 200>&- &
            disown
        else
            echo "anime-mal-search.py not found -- cannot remap right now."
        fi
        ) 200>"$LOCK_FILE"
        ;;

    pending-grades)
        ensure_files
        (
            flock -s 200
            cat "$PENDING_GRADES"
        ) 200>"$LOCK_FILE"
        ;;

    grade-series)
        SERIES="$2"
        SCORE="$3"

        if [ -z "$SERIES" ] || [ -z "$SCORE" ]; then
            echo "Usage: $0 grade-series SERIES SCORE"
            exit 1
        fi

        ensure_files

        (
            flock -x 200

            MAL_ID="$(
                python3 - "$PENDING_GRADES" "$SERIES" <<'PY'
import json
import sys

pending_grades_file = sys.argv[1]
series = sys.argv[2]

with open(pending_grades_file, "r", encoding="utf-8") as f:
    pending_grades = json.load(f)

entry = pending_grades.get(series)

if entry:
    print(entry.get("malId", ""))
PY
            )"

            MAL_ID_LOOKUP_EXIT=$?

            if [ $MAL_ID_LOOKUP_EXIT -ne 0 ]; then
                echo "Failed to look up pending grade for '$SERIES':"
                echo "$MAL_ID"
                exit 1
            fi

            if [ -z "$MAL_ID" ]; then
                echo "No pending grade found for '$SERIES'."
                exit 1
            fi

            "$SCRIPT_DIR/anime-mal-update.py" --finish "$MAL_ID" "$SCORE"

            if [ $? -ne 0 ]; then
                echo "Failed to mark '$SERIES' as finished -- leaving it pending."
                exit 1
            fi

            python3 - "$PENDING_GRADES" "$SERIES" <<'PY'
import json
import sys

pending_grades_file = sys.argv[1]
series = sys.argv[2]

with open(pending_grades_file, "r", encoding="utf-8") as f:
    pending_grades = json.load(f)

pending_grades.pop(series, None)

with open(pending_grades_file, "w", encoding="utf-8") as f:
    json.dump(pending_grades, f, ensure_ascii=False, indent=2)
    f.write("\n")
PY
        ) 200>"$LOCK_FILE"
        ;;

    skip-grade)
        SERIES="$2"

        if [ -z "$SERIES" ]; then
            echo "Usage: $0 skip-grade SERIES"
            exit 1
        fi

        ensure_files

        (
            flock -x 200

            MAL_ID="$(
                python3 - "$PENDING_GRADES" "$SERIES" <<'PY'
import json
import sys

pending_grades_file = sys.argv[1]
series = sys.argv[2]

with open(pending_grades_file, "r", encoding="utf-8") as f:
    pending_grades = json.load(f)

entry = pending_grades.get(series)

if entry:
    print(entry.get("malId", ""))
PY
            )"

            MAL_ID_LOOKUP_EXIT=$?

            if [ $MAL_ID_LOOKUP_EXIT -ne 0 ]; then
                echo "Failed to look up pending grade for '$SERIES':"
                echo "$MAL_ID"
                exit 1
            fi

            if [ -z "$MAL_ID" ]; then
                echo "No pending grade found for '$SERIES'."
                exit 1
            fi

            "$SCRIPT_DIR/anime-mal-update.py" --finish "$MAL_ID"

            if [ $? -ne 0 ]; then
                echo "Failed to mark '$SERIES' as finished -- leaving it pending."
                exit 1
            fi

            python3 - "$PENDING_GRADES" "$SERIES" <<'PY'
import json
import sys

pending_grades_file = sys.argv[1]
series = sys.argv[2]

with open(pending_grades_file, "r", encoding="utf-8") as f:
    pending_grades = json.load(f)

pending_grades.pop(series, None)

with open(pending_grades_file, "w", encoding="utf-8") as f:
    json.dump(pending_grades, f, ensure_ascii=False, indent=2)
    f.write("\n")
PY
        ) 200>"$LOCK_FILE"
        ;;

    get-config)
        ensure_files

        (
            flock -s 200

            if [ -f "$CONFIG_FILE" ]; then
                ANIME_ROOT=""
                source "$CONFIG_FILE"
                echo "$ANIME_ROOT"
            else
                echo ""
            fi
        ) 200>"$LOCK_FILE"
        ;;

    set-config)
        NEW_ROOT="$2"

        ensure_files

        (
            flock -x 200

            mkdir -p "$(dirname "$CONFIG_FILE")"
            printf 'ANIME_ROOT="%s"\n' "$NEW_ROOT" > "$CONFIG_FILE"

            if [ -n "$NEW_ROOT" ]; then
                echo "Anime root set to: $NEW_ROOT"
            else
                echo "Anime root cleared -- all downloads will be tracked."
            fi
        ) 200>"$LOCK_FILE"
        ;;

    batch-warnings)
        ensure_files
        (
            flock -s 200
            cat "$BATCH_WARNINGS"
        ) 200>"$LOCK_FILE"
        ;;

    dismiss-batch-warning)
        WARNING_KEY="$2"

        if [ -z "$WARNING_KEY" ]; then
            echo "Usage: $0 dismiss-batch-warning KEY"
            exit 1
        fi

        ensure_files

        (
            flock -x 200

            python3 - "$BATCH_WARNINGS" "$WARNING_KEY" <<'PY'
import json
import sys

warnings_file = sys.argv[1]
key = sys.argv[2]

try:
    with open(warnings_file, "r", encoding="utf-8") as f:
        warnings = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    warnings = {}

warnings.pop(key, None)

with open(warnings_file, "w", encoding="utf-8") as f:
    json.dump(warnings, f, ensure_ascii=False, indent=2)
    f.write("\n")
PY

            if [ $? -ne 0 ]; then
                echo "Failed to dismiss warning."
                exit 1
            fi
        ) 200>"$LOCK_FILE"
        ;;

            remove-episode)
        SERIES="$2"
        KIND="$3"
        SEASON="$4"
        EPISODE="$5"

        if [ -z "$SERIES" ] || [ -z "$KIND" ] || [ -z "$SEASON" ] || [ -z "$EPISODE" ]; then
            echo "Usage: $0 remove-episode SERIES KIND SEASON EPISODE"
            exit 1
        fi

        ensure_files

        (
            flock -x 200

            REMOVE_RESULT="$(
                python3 - "$TODO" "$LAST_REMOVED" "$SERIES" "$KIND" "$SEASON" "$EPISODE" <<'PY'
import json
import sys
from datetime import datetime

todo_file = sys.argv[1]
last_removed_file = sys.argv[2]
series = sys.argv[3]
kind = sys.argv[4]
season = int(sys.argv[5])
episode_number = int(sys.argv[6])

with open(todo_file, "r", encoding="utf-8") as f:
    todo = json.load(f)

remaining = []
removed = None

for item in todo:
    if (
        item.get("series") == series
        and item.get("kind", "episode") == kind
        and item.get("season") == season
        and item.get("episode") == episode_number
    ):
        removed = item
    else:
        remaining.append(item)

if removed is not None:
    removed["removedAt"] = datetime.now().isoformat(timespec="seconds")

    with open(last_removed_file, "w", encoding="utf-8") as f:
        json.dump(removed, f, ensure_ascii=False, indent=2)
        f.write("\n")

    with open(todo_file, "w", encoding="utf-8") as f:
        json.dump(remaining, f, ensure_ascii=False, indent=2)
        f.write("\n")

print("yes" if removed is not None else "no")
PY
            )"

            if [ $? -ne 0 ]; then
                echo "Failed to remove episode:"
                echo "$REMOVE_RESULT"
                exit 1
            fi

            if [ "$REMOVE_RESULT" = "no" ]; then
                echo "Episode not found in list -- nothing removed."
            fi
        ) 200>"$LOCK_FILE"
        ;;

    last-removed)
        ensure_files
        (
            flock -s 200
            cat "$LAST_REMOVED"
        ) 200>"$LOCK_FILE"
        ;;

    search-only)
        QUERY="$2"

        if [ -z "$QUERY" ]; then
            echo "Usage: $0 search-only QUERY"
            exit 1
        fi

        ensure_files

        if [ ! -x "$SCRIPT_DIR/anime-mal-search.py" ]; then
            echo "anime-mal-search.py not found."
            exit 1
        fi

        TEMP_KEY="__search_only_$$_$(date +%s%N)__"

        # Run the search synchronously, WITHOUT holding our own lock --
        # anime-mal-search.py manages its own locking around the
        # pending-matches file internally. Holding a lock here too
        # would deadlock: the search process opens its own fresh file
        # descriptor on the same lock file and blocks waiting for us,
        # while we're blocked waiting for it to finish.
        "$SCRIPT_DIR/anime-mal-search.py" "$TEMP_KEY" "$QUERY" >/dev/null

        if [ $? -ne 0 ]; then
            echo "Search failed."
            exit 1
        fi

        (
            flock -x 200

            RESULT="$(
                python3 - "$PENDING" "$TEMP_KEY" <<'PY'
import json
import sys

pending_file = sys.argv[1]
key = sys.argv[2]

with open(pending_file, "r", encoding="utf-8") as f:
    pending = json.load(f)

entry = pending.pop(key, None)

with open(pending_file, "w", encoding="utf-8") as f:
    json.dump(pending, f, ensure_ascii=False, indent=2)
    f.write("\n")

print(json.dumps((entry or {}).get("candidates", []), ensure_ascii=False))
PY
            )"

            if [ $? -ne 0 ]; then
                echo "Failed to read search results:"
                echo "$RESULT"
                exit 1
            fi

            echo "$RESULT"
        ) 200>"$LOCK_FILE"
        ;;

    *)
        TORRENT_NAME="$1"
        CONTENT_PATH="$2"
        SAVE_PATH="$3"
        TAGS="$4"

        MAL_ID="$(printf '%s' "$TAGS" | grep -oEi 'mal:[[:space:]]*[0-9]+' | grep -oE '[0-9]+')"

        SERIES="$(basename "$SAVE_PATH")"

        if ! is_within_anime_root "$SAVE_PATH"; then
            echo "Skipping '$TORRENT_NAME' -- save path '$SAVE_PATH' is outside the configured anime root ($ANIME_ROOT)."
            exit 0
        fi

        if [ -d "$CONTENT_PATH" ]; then
            ensure_files

            (
                flock -x 200

                echo "Processing batch: '$TORRENT_NAME'..."

                declare -a BATCH_FILES=()
                declare -a BATCH_KINDS=()
                declare -a BATCH_SEASONS=()
                declare -a BATCH_EPISODES=()
                declare -A GROUPS_SEEN=()

                while IFS= read -r -d '' file; do
                    FILE_NAME="$(basename "$file")"

                    FILE_KIND="episode"
                    FILE_SEASON=""
                    FILE_EPISODE=""

                    if [ -x "$SCRIPT_DIR/anime-parse-episode.py" ]; then
                        EPISODE_INFO="$("$SCRIPT_DIR/anime-parse-episode.py" "$FILE_NAME" "$SERIES" 2>/dev/null)"

                        if [ -n "$EPISODE_INFO" ]; then
                            mapfile -t EPISODE_LINES <<< "$EPISODE_INFO"
                            FILE_KIND="${EPISODE_LINES[0]}"
                            FILE_SEASON="${EPISODE_LINES[1]}"
                            FILE_EPISODE="${EPISODE_LINES[2]}"
                        fi
                    fi

                    if [ -z "$FILE_EPISODE" ]; then
                        echo "Warning: could not parse episode number from '$FILE_NAME' -- skipped."
                        continue
                    fi

                    BATCH_FILES+=("$file")
                    BATCH_KINDS+=("$FILE_KIND")
                    BATCH_SEASONS+=("$FILE_SEASON")
                    BATCH_EPISODES+=("$FILE_EPISODE")
                    GROUPS_SEEN["${FILE_KIND}S${FILE_SEASON}"]=1
                done < <(
                    find "$CONTENT_PATH" -type f \
                        \( -iname '*.mkv' -o -iname '*.mp4' -o -iname '*.avi' \
                           -o -iname '*.ts' -o -iname '*.webm' -o -iname '*.m4v' \) \
                        -print0 | sort -z
                )

                FILE_COUNT="${#BATCH_FILES[@]}"
                GROUP_COUNT="${#GROUPS_SEEN[@]}"

                if [ "$FILE_COUNT" -eq 0 ]; then
                    echo "No video files found in batch '$TORRENT_NAME'."
                fi

                for i in "${!BATCH_FILES[@]}"; do
                    FILE="${BATCH_FILES[$i]}"
                    FILE_KIND="${BATCH_KINDS[$i]}"
                    FILE_SEASON="${BATCH_SEASONS[$i]}"
                    FILE_EPISODE="${BATCH_EPISODES[$i]}"

                    if [ "$GROUP_COUNT" -le 1 ]; then
                        SERIES_KEY="$SERIES"
                        GROUP_LABEL_TEXT="$SERIES"
                    else
                        SERIES_KEY="${SERIES}::${FILE_KIND}S${FILE_SEASON}"
                        GROUP_LABEL_TEXT="$(group_label "$SERIES" "$FILE_KIND" "$FILE_SEASON")"
                    fi

                    process_one_episode \
                        "$SERIES_KEY" "$SERIES" "$GROUP_LABEL_TEXT" \
                        "$FILE_KIND" "$FILE_SEASON" "$FILE_EPISODE" "$FILE"
                done

                if [ "$GROUP_COUNT" -gt 1 ]; then
                    GROUP_LIST=""
                    for group_key in "${!GROUPS_SEEN[@]}"; do
                        GROUP_LIST="$GROUP_LIST $group_key"
                    done

                    echo "Batch '$TORRENT_NAME' contains $GROUP_COUNT distinct groups ($GROUP_LIST) -- each is being matched to MAL independently."
                fi

                if [ "$FILE_COUNT" -gt 0 ]; then
                    run_library_link
                fi
            ) 200>"$LOCK_FILE"

            exit 0
        fi

        if printf '%s' "$TORRENT_NAME" | grep -qi 'batch'; then
            echo "Skipping '$TORRENT_NAME' -- name suggests a batch, but content path isn't a directory (can't safely split into individual episodes)."
            exit 0
        fi

        KIND="episode"
        SEASON=""
        EPISODE=""

        if [ -x "$SCRIPT_DIR/anime-parse-episode.py" ]; then
            EPISODE_INFO="$("$SCRIPT_DIR/anime-parse-episode.py" "$TORRENT_NAME" "$SERIES" 2>/dev/null)"

            if [ -n "$EPISODE_INFO" ]; then
                mapfile -t EPISODE_LINES <<< "$EPISODE_INFO"
                KIND="${EPISODE_LINES[0]}"
                SEASON="${EPISODE_LINES[1]}"
                EPISODE="${EPISODE_LINES[2]}"
            fi
        else
            echo "anime-parse-episode.py not found -- falling back to basic SxxEyy parsing."

            EPISODE_CODE="$(printf '%s' "$TORRENT_NAME" | grep -oEi 'S[0-9]{1,2}E[0-9]{1,4}' | head -1 | tr '[:lower:]' '[:upper:]')"

            if [ -n "$EPISODE_CODE" ]; then
                SEASON="$(printf '%s' "$EPISODE_CODE" | grep -oEi '^S[0-9]+' | grep -oE '[0-9]+')"
                EPISODE="$(printf '%s' "$EPISODE_CODE" | grep -oEi 'E[0-9]+' | grep -oE '[0-9]+')"
            fi
        fi

        if [ -z "$EPISODE" ]; then
            echo "Warning: could not parse episode number from '$TORRENT_NAME' -- skipped, not added to list."
        fi

        if [ -n "$EPISODE" ]; then
            ensure_files

            (
                flock -x 200

                NEEDS_SEARCH="$(
                    python3 - "$SERIES_MAP" "$PENDING" "$TODO" "$SERIES" "$KIND" "$SEASON" "$EPISODE" "$CONTENT_PATH" "$MAL_ID" "$PENDING_TIMEOUT_SECONDS" <<'PY'
import json
import sys
import time

series_map_file = sys.argv[1]
pending_file = sys.argv[2]
todo_file = sys.argv[3]
series = sys.argv[4]
kind = sys.argv[5]
season = int(sys.argv[6])
episode = int(sys.argv[7])
path = sys.argv[8]
explicit_mal_id = int(sys.argv[9]) if sys.argv[9] else None
pending_timeout = int(sys.argv[10])

with open(series_map_file, "r", encoding="utf-8") as f:
    series_map = json.load(f)

entry = series_map.get(series)

mal_id = explicit_mal_id
needs_search = False

if mal_id is None:
    if entry and entry.get("malId"):
        mal_id = entry["malId"]
    elif entry and entry.get("skipped"):
        pass
    else:
        with open(pending_file, "r", encoding="utf-8") as f:
            pending = json.load(f)

        pending_entry = pending.get(series)

        if pending_entry is None:
            needs_search = True
        else:
            status = pending_entry.get("status")

            if status == "error":
                needs_search = True
            elif status == "searching":
                started_at = pending_entry.get("startedAt")

                if (
                    started_at is None
                    or (time.time() - started_at) > pending_timeout
                ):
                    needs_search = True

with open(todo_file, "r", encoding="utf-8") as f:
    todo = json.load(f)

item = {
    "series": series,
    "seriesKey": series,
    "kind": kind,
    "season": season,
    "episode": episode,
    "path": path,
    "malId": mal_id,
    "watched": False
}

if not any(
    x.get("seriesKey", x.get("series")) == series
    and x.get("kind", "episode") == kind
    and x.get("season") == season
    and x.get("episode") == episode
    for x in todo
):
    todo.append(item)

    with open(todo_file, "w", encoding="utf-8") as f:
        json.dump(todo, f, ensure_ascii=False, indent=2)
        f.write("\n")

print("yes" if needs_search else "no")
PY
                )"

                if [ $? -ne 0 ]; then
                    echo "Failed to queue episode from '$TORRENT_NAME':"
                    echo "$NEEDS_SEARCH"
                    exit 1
                fi

                if [ "$NEEDS_SEARCH" = "yes" ]; then
                    start_series_search "$SERIES"
                fi
            ) 200>"$LOCK_FILE"

            QUEUE_EXIT=$?

            if [ "$QUEUE_EXIT" -eq 0 ]; then
                run_library_link
            fi
        fi
        ;;
esac
