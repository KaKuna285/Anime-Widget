#!/bin/bash
# Blocks until exactly one of the anime-todo data files changes,
# then exits. Meant to be re-invoked in a loop by the widget so it
# reacts to changes instead of polling on a fixed timer.
# Requires inotify-tools (inotifywait).

DATA_DIR="$HOME/.local/share"

FILES=(
    "$DATA_DIR/anime-todo.json"
    "$DATA_DIR/anime-history.json"
    "$DATA_DIR/anime-series-map.json"
    "$DATA_DIR/anime-pending-matches.json"
    "$DATA_DIR/anime-pending-grades.json"
    "$DATA_DIR/anime-batch-warnings.json"
    "$DATA_DIR/anime-last-removed.json"
)

for f in "${FILES[@]}"; do
    [ -f "$f" ] || : > "$f"
done

exec inotifywait -q -e close_write -e create -e moved_to "${FILES[@]}"
