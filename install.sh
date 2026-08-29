#!/bin/bash

set -e
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$HOME/.local/bin"
echo "Installing Anime-Widget"
mkdir -p "$BIN_DIR"

check_inotify_tools() {
    if command -v inotifywait >/dev/null 2>&1; then
        return
    fi

    echo ""
    echo "inotify-tools is not installed."
    echo "It's optional -- without it, the widget falls back to polling"
    echo "every few seconds instead of updating instantly when a new"
    echo "episode is added or a background search finishes."
    echo ""

    read -p "Install it now? [y/N] " -n 1 -r
    echo ""

    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Skipping -- the widget will still work, just with slightly delayed updates."
        return
    fi

    if command -v pacman >/dev/null 2>&1; then
        sudo pacman -S --needed inotify-tools
    elif command -v apt >/dev/null 2>&1; then
        sudo apt install -y inotify-tools
    elif command -v dnf >/dev/null 2>&1; then
        sudo dnf install -y inotify-tools
    elif command -v zypper >/dev/null 2>&1; then
        sudo zypper install -y inotify-tools
    else
        echo "Couldn't detect a supported package manager (pacman/apt/dnf/zypper)."
        echo "Please install inotify-tools manually if you'd like instant updates."
        return
    fi

    if command -v inotifywait >/dev/null 2>&1; then
        echo "inotify-tools installed successfully."
    else
        echo "Installation may have failed -- the widget will fall back to polling."
    fi
}

check_inotify_tools

cp "$SCRIPT_DIR/scripts/anime-downloaded.sh" "$BIN_DIR/anime-downloaded.sh"
cp "$SCRIPT_DIR/scripts/anime-mal-auth.py" "$BIN_DIR/anime-mal-auth.py"
cp "$SCRIPT_DIR/scripts/anime-mal-update.py" "$BIN_DIR/anime-mal-update.py"
cp "$SCRIPT_DIR/scripts/anime-mal-search.py" "$BIN_DIR/anime-mal-search.py"
cp "$SCRIPT_DIR/scripts/anime-parse-episode.py" "$BIN_DIR/anime-parse-episode.py"
cp "$SCRIPT_DIR/scripts/anime-watch-changes.sh" "$BIN_DIR/anime-watch-changes.sh"
cp "$SCRIPT_DIR/scripts/anime-mal-details.py" "$BIN_DIR/anime-mal-details.py"
cp "$SCRIPT_DIR/scripts/anime-rss-helper.py" "$BIN_DIR/anime-rss-helper.py"
cp "$SCRIPT_DIR/scripts/anime-gui-prefs.sh" "$BIN_DIR/anime-gui-prefs.sh"

chmod +x "$BIN_DIR/anime-downloaded.sh"
chmod +x "$BIN_DIR/anime-mal-auth.py"
chmod +x "$BIN_DIR/anime-mal-update.py"
chmod +x "$BIN_DIR/anime-mal-search.py"
chmod +x "$BIN_DIR/anime-parse-episode.py"
chmod +x "$BIN_DIR/anime-watch-changes.sh"
chmod +x "$BIN_DIR/anime-mal-details.py"
chmod +x "$BIN_DIR/anime-rss-helper.py"
chmod +x "$BIN_DIR/anime-gui-prefs.sh"

DESKTOP_DIR="$HOME/.local/share/applications"
mkdir -p "$DESKTOP_DIR"

cat > "$DESKTOP_DIR/anime-add-series.desktop" << EOF
[Desktop Entry]
Type=Application
Name=Add Anime Series
Comment=Create a qBittorrent RSS rule and pre-map it to MyAnimeList
Exec=env QT_QUICK_CONTROLS_STYLE=org.kde.desktop qml6 "$SCRIPT_DIR/tools/add-series.qml"
Icon=view-media-track
Terminal=false
Categories=Utility;
EOF

kpackagetool6 --type Plasma/Applet --install "$SCRIPT_DIR/plasmoid" 2>/dev/null ||
kpackagetool6 --type Plasma/Applet --upgrade "$SCRIPT_DIR/plasmoid"

echo "Installation complete."
