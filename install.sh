#!/bin/bash
set -e

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$HOME/.local/bin"

echo "Installing Anime-Widget"

mkdir -p "$BIN_DIR"

setup_server_conf() {
    local conf="$HOME/.config/anime-todo/server.conf"

    if [ -f "$conf" ]; then
        return
    fi

    echo ""
    echo "Anime-Widget now keeps its list on the Home Assistant add-on."
    echo "You'll find the API token on the add-on's web page in Home Assistant."

    if [ ! -t 0 ]; then
        echo "Create $conf with SERVER_URL=... and API_TOKEN=... before using the widget."
        return
    fi

    read -p "Server URL [http://homeassistant.local:8099]: " -r SERVER_URL
    SERVER_URL="${SERVER_URL:-http://homeassistant.local:8099}"
    read -p "API token: " -r API_TOKEN

    mkdir -p "$(dirname "$conf")"
    printf 'SERVER_URL=%s\nAPI_TOKEN=%s\n' "$SERVER_URL" "$API_TOKEN" > "$conf"
    chmod 600 "$conf"
    echo "Saved $conf"
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

choose_install_mode

for f in anime-downloaded.sh anime-client.py anime-parse-episode.py \
         anime-watch-changes.sh anime-rss-helper.py anime-gui-prefs.sh; do
    cp "$SCRIPT_DIR/scripts/$f" "$BIN_DIR/$f"
    chmod +x "$BIN_DIR/$f"
done

# MAL access moved to the server add-on -- remove the old local scripts
# so nothing keeps using a stale local token by accident.
for f in anime-mal-auth.py anime-mal-update.py anime-mal-search.py anime-mal-details.py; do
    rm -f "$BIN_DIR/$f"
done

setup_server_conf

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
    cp "$SCRIPT_DIR/plasmoid/contents/ui/AnimeDialogs.qml" "$SCRIPT_DIR/standalone/AnimeDialogs.qml"

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
