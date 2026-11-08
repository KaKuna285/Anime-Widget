# Anime-Widget

A KDE Plasma 6 widget that turns newly-downloaded anime episodes into a persistent checklist, and keeps your [MyAnimeList](https://myanimelist.net) list in sync automatically as you watch.

Point qBittorrent's "run on torrent completion" hook at this project's script, and every new episode shows up in your Plasma panel as a checkbox. Check it off, and your MAL entry updates — episode count, completion status, even a rating prompt when you finish a show — all without touching a browser.

## What it does

- **Automatic checklist** — new episodes appear in the widget the moment a torrent finishes, grouped by series.
- **Automatic MAL matching** — the first time a new series shows up, the widget searches MyAnimeList and asks you to confirm which entry it is. It remembers your choice, so every future episode of that series maps correctly with no further input.
- **Movies, OVAs, and specials** — detected and labeled distinctly from regular episodes (e.g. "Movie", "OVA 2"), each still mapping correctly to its own MAL entry.
- **Batch torrents** — a torrent containing multiple episodes (a season pack, a full-series batch) is unpacked and every episode queued individually. If everything in the batch is the same season and kind, it's matched to MAL once; if a batch spans multiple seasons or mixes in movies/OVAs/specials, each distinct group gets its own independent MAL match automatically.
- **Automatic MAL sync on checkoff** — checking an episode updates your MAL `num_episodes_watched`. When you reach the final episode of an entry, a popup lets you rate it (or skip), and MAL is set to "completed."
- **Undo** — reverses your most recent action, whether that was completing an episode or removing one from the list. Restores MAL state where relevant.
- **Remove wrongly-queued entries** — right-click any episode to remove it from the list (e.g. a mis-parsed or duplicate entry).
- **Resilient by design** — file locking prevents races between concurrent downloads, failures surface as visible error dialogs instead of failing silently, and the MAL OAuth token refreshes itself automatically so you won't need to re-authenticate every month.
- **Real titles, not folder names** — once a series is matched, its entry in the widget shows the actual MAL title instead of the raw download folder name (with an optional setting to prefer the English title over the Japanese/romaji one).

## How it fits together

```
qBittorrent hook ─┐                         ┌─ MyAnimeList API
Plasma widget ────┼─ anime-client.py ──HTTP─┤  Anime-Widget Server
Standalone app ───┤  (on the PC)            │  (Home Assistant add-on,
Add-series tool ──┘                         │   SQLite in /data)
                                 phone ─────┘  (web app: coming next)
```

The checklist, history, series mappings and MAL login live on the **Anime-Widget Server** add-on on Home Assistant. Every client on the PC goes through `anime-client.py` (still called as `anime-downloaded.sh`, so the qBittorrent hook is unchanged). Filename parsing, the anime-root filter and the library-link script still run on the PC, because they need the files.

If the server is unreachable, the widget shows the last known list with a disconnected icon. New downloads wait in a local outbox and are sent automatically once the server is back.

## Requirements

- KDE Plasma 6
- Python 3
- Home Assistant OS/Supervised (for the add-on)
- A MyAnimeList account and a registered [MAL API application](https://myanimelist.net/apiconfig) (free, takes a couple of minutes) for the Client ID. App type "other", redirect URI `http://localhost:8080/callback`.

## Installation

### 1. The server (Home Assistant)

1. **Settings → Add-ons → Add-on Store → ⋮ → Repositories**, add `https://github.com/KaKuna285/Anime-Widget`. Then install **Anime-Widget Server**.
   (Or copy the `anime_widget_server` folder into HA's `/addons` share and install it from "Local add-ons".)
2. In the add-on's **Configuration** tab, set `mal_client_id`. Start the add-on.
3. Open the add-on's web UI (the **Anime** sidebar entry) and copy the **API token**.

### 2. The PC

```bash
git clone https://github.com/KaKuna285/Anime-Widget.git
cd Anime-Widget
./install.sh
```

The installer deploys the scripts to `~/.local/bin/` and asks for the server URL (e.g. `http://192.168.1.20:8099`) and the API token. It saves them in `~/.config/anime-todo/server.conf`. Then it installs the widget and/or standalone app.

Check the connection:

```bash
~/.local/bin/anime-client.py info
```

### 3. MyAnimeList login

- **Coming from the old local version?** Run `~/.local/bin/anime-client.py migrate` once. It uploads your existing list, history, series mappings and MAL token to the server.
- **Fresh install:** log in from the add-on's web UI. Click "Open MAL login", approve, then paste back the `localhost` address your browser lands on.

Add the widget to your panel: right-click → **Add Widgets** → "Anime-Widget".

## Connecting qBittorrent

In qBittorrent: **Tools → Options → Downloads → Run external program on torrent completion**, and set it to:

/home/YOUR_USERNAME/.local/bin/anime-downloaded.sh "%N" "%F" "%D" "%T"


(`%N` = torrent name, `%F` = content path, `%D` = save path, `%T` = tags — the save path is what determines which "series folder" an episode belongs to.)

**Folder structure matters.** Each show — and each *season* of a show — should download into its own distinct folder. That folder is what the widget uses to identify which MAL entry an episode belongs to. Movies, OVAs, and specials should also get their own folder, separate from the main series.

## Using it day to day

**First episode of a new series:** the widget will pop up a picker showing MAL search results — pick the right one (or search manually if the automatic guess misses), and it's remembered from then on. If it's something you don't want tracked on MAL at all, hit Skip.

**Checking things off:** click a checkbox to mark an episode watched — this updates MAL immediately. If something goes wrong (network issue, MAL API hiccup), you'll get an error dialog explaining what happened, and the episode stays unchecked rather than silently failing.

**Finishing a show:** when you check off a show's final episode, a "rate it?" popup appears. Give it a score, or skip — either way, MAL gets marked completed.

**Made a mistake?** The undo button (top-right of the widget) reverses your most recent action — whether that was checking off an episode or removing one. Right-click any episode for "Show in folder" (opens the file's location) or "Remove" if something's wrongly queued (duplicate, mis-parsed episode number, etc.).

**Managing series matches:** the gear icon opens a list of every series you've matched. Active ones (still have episodes pending) show at the top; finished ones collapse behind a "Show N finished series" toggle so the list doesn't get cluttered. From here you can re-search a series or manually set a MAL ID.

## Settings

Right-click the widget → **Configure**:
- **General** — title text, whether the compact panel view shows an episode count
- **Appearance** — font sizes, spacing, background opacity
- **Behavior** — fallback refresh interval, whether to confirm before undoing, whether to prompt for a rating when finishing a show, whether to prefer English titles over Japanese/romaji ones

## Known limitations

- **Filename parsing is best-effort.** It handles most common release naming conventions (`S01E01`, `1x03`, absolute episode numbers, movie/OVA/special markers), but unusual or heavily abbreviated names may need manual correction via the manage-series dialog. Parsing also relies on the release's embedded title roughly matching the download folder name — if they're inconsistent, an episode number or kind marker could occasionally be misread.
- **MAL's OAuth only supports the "plain" PKCE method**, not the more modern S256 — this is a limitation on MAL's end, not something this project can fix.

## Where things live

| What | Where |
|---|---|
| Checklist, history, series mappings | Home Assistant add-on: `/data/anime.db` (in HA backups) |
| MAL token | Home Assistant add-on: `/data/mal-token.json` |
| Server log | Add-on **Log** tab, plus `/data/anime-server.log` |
| Deployed PC scripts | `~/.local/bin/anime-*` |
| Server address + API token | `~/.config/anime-todo/server.conf` |
| Anime root filter | `~/.config/anime-todo/anime-todo.conf` |
| Offline cache / outbox | `~/.cache/anime-todo/state.json`, `~/.local/share/anime-todo-outbox.json` |

## Development

`python3 tests/e2e-test.py` runs the real server and client against a fake MyAnimeList in a temp dir. It never touches your real data.
