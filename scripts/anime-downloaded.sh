#!/bin/bash
# Entry point kept for compatibility: the widget, standalone app,
# add-series tool and qBittorrent's completion hook all call this.
# The real work now happens in anime-client.py, which talks to the
# Anime-Widget server add-on on Home Assistant.
exec python3 "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/anime-client.py" "$@"
