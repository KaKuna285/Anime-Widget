#!/bin/bash

set -e

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$HOME/.local/bin"

echo "Installing Anime To Watch..."

mkdir -p "$BIN_DIR"

cp "$SCRIPT_DIR/scripts/anime-downloaded.sh" "$BIN_DIR/anime-downloaded.sh"
cp "$SCRIPT_DIR/scripts/anime-mal-auth.py" "$BIN_DIR/anime-mal-auth.py"
cp "$SCRIPT_DIR/scripts/anime-mal-test.py" "$BIN_DIR/anime-mal-test.py"
cp "$SCRIPT_DIR/scripts/anime-mal-update.py" "$BIN_DIR/anime-mal-update.py"

chmod +x "$BIN_DIR/anime-downloaded.sh"
chmod +x "$BIN_DIR/anime-mal-auth.py"
chmod +x "$BIN_DIR/anime-mal-test.py"
chmod +x "$BIN_DIR/anime-mal-update.py"

kpackagetool6 --type Plasma/Applet --install "$SCRIPT_DIR/plasmoid" 2>/dev/null ||
kpackagetool6 --type Plasma/Applet --upgrade "$SCRIPT_DIR/plasmoid"

echo "Installation complete."
