#!/bin/bash
FILE_NAME="$1"
COMMAND="$2"
VALUE="$3"

if [ -z "$FILE_NAME" ] || [ -z "$COMMAND" ]; then
    echo "Usage: $0 FILE_NAME get|set [JSON]"
    exit 1
fi

# Basic safety: don't allow the caller to escape the config directory.
case "$FILE_NAME" in
    */*|*..*)
        echo "Invalid file name: $FILE_NAME"
        exit 1
        ;;
esac

PREFS_FILE="$HOME/.config/anime-todo/$FILE_NAME"

case "$COMMAND" in
    get)
        mkdir -p "$(dirname "$PREFS_FILE")"
        [ -f "$PREFS_FILE" ] || printf '{}\n' > "$PREFS_FILE"
        cat "$PREFS_FILE"
        ;;
    set)
        if [ -z "$VALUE" ]; then
            echo "Usage: $0 FILE_NAME set JSON"
            exit 1
        fi

        mkdir -p "$(dirname "$PREFS_FILE")"
        printf '%s\n' "$VALUE" > "$PREFS_FILE"
        ;;
    *)
        echo "Usage: $0 FILE_NAME get|set [JSON]"
        exit 1
        ;;
esac
