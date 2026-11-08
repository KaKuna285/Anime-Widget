## 0.2.0
- New: phone web app. The add-on copies it into Home Assistant's `www/anime-widget/` folder on start, so it opens on HA's own https address (e.g. Tailscale) with your normal HA login, and it can be installed to the home screen. You can tick episodes, undo, remove episodes, delete a series, rate finished shows, match series to MAL (search, MAL ID, or "not on MAL") and manage matches. Changes show up live on every device.
- The add-on now has access to the HA config folder (to write the phone app there) and to the Supervisor API (to look up its own ingress address).

## 0.1.2
- New: remove a whole series from the list in one go (undoable).

## 0.1.1
- Confirming a series by MAL ID alone now stores MAL's own title instead of the folder name.

## 0.1.0
- First version: shared checklist/history/series map in SQLite, MAL sync and
  OAuth token handled server-side, long-poll change feed, MAL web login.
