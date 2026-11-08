# Anime-Widget Server

Central store for the Anime-Widget episode checklist. The KDE widget, the
standalone app and (soon) the phone web app all read and write the same
list here, and this add-on talks to MyAnimeList for all of them.

## Setup

1. **Configuration tab**: set `mal_client_id` to your MAL API Client ID (the
   same value as `CLIENT_ID` in `~/.config/anime-todo/mal.conf`). Leave
   `api_token` empty to have one generated for you.
2. Start the add-on and open its web UI (the **Anime** sidebar entry, or
   "Open Web UI"). Copy the API token shown there.
3. On the PC, put the server address and token in
   `~/.config/anime-todo/server.conf`, then run
   `anime-client.py migrate` once to upload your existing list and MAL
   login. (Or log in to MAL from the web UI instead.)

## Network

Port 8099 is the API. It requires the API token, except for requests coming
through Home Assistant's own sidebar (ingress), which HA has already
authenticated.

## Data

Everything lives in `/data/anime.db` (SQLite) plus `/data/mal-token.json`,
so it's included in Home Assistant backups.
