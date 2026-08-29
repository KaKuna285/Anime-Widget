#!/bin/bash
PREFS_FILE="$HOME/.config/anime-todo/add-series-prefs.json"

case "$1" in
    get)
        mkdir -p "$(dirname "$PREFS_FILE")"
        [ -f "$PREFS_FILE" ] || printf '{}\n' > "$PREFS_FILE"
        cat "$PREFS_FILE"
        ;;
    set)
        if [ -z "$2" ]; then
            echo "Usage: $0 set JSON"
            exit 1
        fi

        mkdir -p "$(dirname "$PREFS_FILE")"
        printf '%s\n' "$2" > "$PREFS_FILE"
        ;;
    *)
        echo "Usage: $0 get|set [JSON]"
        exit 1
        ;;
esac
