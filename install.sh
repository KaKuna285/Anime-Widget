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

choose_install_mode() {
    # Default to "both" if stdin isn't a real terminal (e.g. the
    # script is being piped/run non-interactively), so install.sh
    # never hangs waiting for input it can't get.
    if [ ! -t 0 ]; then
        INSTALL_MODE="both"
        return
    fi

    echo ""
    echo "How would you like to run Anime-Widget?"
    echo "  1) Plasma panel widget only"
    echo "  2) Standalone application only"
    echo "  3) Both (default)"
    echo ""

    read -p "Choice [1/2/3]: " -r MODE_CHOICE
    echo ""

    case "$MODE_CHOICE" in
        1) INSTALL_MODE="widget" ;;
        2) INSTALL_MODE="standalone" ;;
        *) INSTALL_MODE="both" ;;
    esac
}

check_inotify_tools
choose_install_mode

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

if [ "$INSTALL_MODE" = "widget" ] || [ "$INSTALL_MODE" = "both" ]; then
    echo "Installing Plasma widget..."

    kpackagetool6 --type Plasma/Applet --install "$SCRIPT_DIR/plasmoid" 2>/dev/null ||
    kpackagetool6 --type Plasma/Applet --upgrade "$SCRIPT_DIR/plasmoid"
fi

if [ "$INSTALL_MODE" = "standalone" ] || [ "$INSTALL_MODE" = "both" ]; then
    echo "Setting up standalone application..."

    mkdir -p "$SCRIPT_DIR/standalone"
    cp "$SCRIPT_DIR/plasmoid/contents/ui/AnimeBackend.qml" "$SCRIPT_DIR/standalone/AnimeBackend.qml"
    cp "$SCRIPT_DIR/plasmoid/contents/ui/AnimeContent.qml" "$SCRIPT_DIR/standalone/AnimeContent.qml"

    cat > "$DESKTOP_DIR/anime-widget-standalone.desktop" << EOF
[Desktop Entry]
Type=Application
Name=Anime-Widget
Comment=Track downloaded anime episodes and sync progress to MyAnimeList
Exec=env QT_QUICK_CONTROLS_STYLE=org.kde.desktop qml6 "$SCRIPT_DIR/standalone/main.qml"
Icon=view-media-track
Terminal=false
Categories=Utility;AudioVideo;
EOF
fi

echo "Installation complete."
