"""All state-changing operations -- the server-side port of the old
anime-downloaded.sh subcommands.

Every operation runs under store.op_lock (the replacement for flock),
and MAL is always updated *before* local state changes, so a failed MAL
call leaves things exactly as they were and surfaces as an error.
"""

import threading
import time
from datetime import datetime

from mal import MalError, clean_query

PENDING_TIMEOUT_SECONDS = 120


class OpError(Exception):
    def __init__(self, message, status=400):
        super().__init__(message)
        self.status = status


def _now():
    return datetime.now().isoformat(timespec="seconds")


def _key_of(item):
    return item.get("seriesKey") or item.get("series")


def _same_episode(item, series, kind, season, episode):
    return (
        item.get("series") == series
        and item.get("kind", "episode") == kind
        and item.get("season") == season
        and item.get("episode") == episode
    )


def _ep_code(item):
    return f"{item.get('series')} S{int(item.get('season') or 0):02d}E{int(item.get('episode') or 0):02d}"


class Ops:
    def __init__(self, store, mal, log):
        self.store = store
        self.mal = mal
        self.log = log

    # ---- MAL search queue -----------------------------------------

    def _spawn_search(self, series_key, query):
        threading.Thread(
            target=self._run_search, args=(series_key, query), daemon=True
        ).start()

    def _run_search(self, series_key, query):
        try:
            candidates = self.mal.search(query)
            entry = {
                "status": "ready" if candidates else "no_results",
                "query": query,
                "candidates": candidates,
            }
        except Exception as e:
            self.log(f"MAL search failed for '{series_key}': {e}")
            entry = {"status": "error", "query": query, "error": str(e)}

        with self.store.op_lock:
            pending = self.store.get("pendingMatches")
            current = pending.get(series_key)

            # Only write results that are still wanted -- the series may
            # have been confirmed/skipped while the search was running.
            if not current or current.get("status") != "searching":
                return

            pending[series_key] = entry
            self.store.commit({"pendingMatches": pending})

    def resume_interrupted_searches(self):
        """Re-run searches that were in flight when the server stopped."""
        for key, entry in self.store.get("pendingMatches").items():
            if entry.get("status") == "searching":
                self.log(f"Resuming interrupted MAL search for '{key}'")
                self._spawn_search(key, entry.get("query") or clean_query(key))

    @staticmethod
    def _mark_searching(pending, series_key, query):
        pending[series_key] = {
            "status": "searching",
            "query": query,
            "startedAt": time.time(),
        }

    # ---- queueing new downloads -----------------------------------

    def queue_episodes(self, items, explicit_mal_id=None):
        """items: [{seriesKey, series, groupLabel, kind, season, episode, path}]"""
        if not isinstance(items, list) or not items:
            raise OpError("No episodes given.")

        to_search = {}
        added = 0

        with self.store.op_lock:
            series_map = self.store.get("seriesMap")
            pending = self.store.get("pendingMatches")
            episodes = self.store.get("episodes")

            for raw in items:
                try:
                    series = str(raw["series"])
                    key = str(raw.get("seriesKey") or series)
                    kind = str(raw.get("kind") or "episode")
                    season = int(raw.get("season") or 1)
                    episode = int(raw["episode"])
                except (KeyError, TypeError, ValueError) as e:
                    raise OpError(f"Invalid episode entry {raw!r}: {e}")

                mal_id = int(explicit_mal_id) if explicit_mal_id else None
                entry = series_map.get(key)

                if mal_id is None:
                    if entry and entry.get("malId"):
                        mal_id = entry["malId"]
                    elif entry and entry.get("skipped"):
                        pass
                    elif key not in to_search:
                        p = pending.get(key)
                        stale = (
                            p is None
                            or p.get("status") == "error"
                            or (
                                p.get("status") == "searching"
                                and time.time() - (p.get("startedAt") or 0) > PENDING_TIMEOUT_SECONDS
                            )
                        )

                        if stale:
                            to_search[key] = raw.get("groupLabel") or series

                exists = any(
                    _key_of(x) == key
                    and x.get("kind", "episode") == kind
                    and x.get("season") == season
                    and x.get("episode") == episode
                    for x in episodes
                )

                if not exists:
                    episodes.append({
                        "series": series,
                        "seriesKey": key,
                        "kind": kind,
                        "season": season,
                        "episode": episode,
                        "path": raw.get("path") or "",
                        "malId": mal_id,
                        "watched": False,
                        "addedAt": _now(),
                    })
                    added += 1

            for key, query in to_search.items():
                self._mark_searching(pending, key, query)

            self.store.commit({"episodes": episodes, "pendingMatches": pending})

        for key, query in to_search.items():
            self._spawn_search(key, query)

        return {
            "message": f"Queued {added} new item(s), {len(items) - added} already listed.",
            "added": added,
            "searching": list(to_search),
        }

    # ---- checking off / undo / remove -----------------------------

    def done(self, series, season, episode, kind="episode"):
        season, episode = int(season), int(episode)

        with self.store.op_lock:
            episodes = self.store.get("episodes")
            item = next((x for x in episodes if _same_episode(x, series, kind, season, episode)), None)

            if item is None:
                return {"message": "Episode is no longer in the list -- nothing to do.", "final": False}

            mal_previous = {"exists": False}
            message = "Marked watched."

            if item.get("malId"):
                try:
                    mal_previous, message = self.mal.update_watched(item["malId"], episode)
                except Exception as e:
                    self.log(f"MAL update failed for {item['malId']} ep {episode}: {e}")
                    raise OpError(f"MAL update failed: {e}\nEpisode NOT marked done.", 502)

            # MAL succeeded (or nothing to sync) -- move TODO -> history.
            history = self.store.get("history")
            remaining = [x for x in episodes if x is not item]

            if not any(_same_episode(x, series, kind, season, episode) for x in history):
                done_item = dict(item)
                done_item["watched"] = True
                done_item["watchedAt"] = _now()
                done_item["malPrevious"] = mal_previous
                history.append(done_item)

            changes = {"episodes": remaining, "history": history}

            key = _key_of(item)
            series_map = self.store.get("seriesMap")
            map_entry = series_map.get(key) or series_map.get(series) or {}
            num = map_entry.get("numEpisodes")
            final = bool(num and map_entry.get("malId") and episode >= num)

            if final:
                grades = self.store.get("pendingGrades")
                grades[key] = {
                    "malId": map_entry["malId"],
                    "title": map_entry.get("title") or series,
                    "englishTitle": map_entry.get("englishTitle"),
                }
                changes["pendingGrades"] = grades

            self.store.commit(changes)

        return {"message": message, "final": final, "seriesKey": key}

    def undo(self):
        with self.store.op_lock:
            history = self.store.get("history")
            last_removed = self.store.get("lastRemoved")

            history_at = history[-1].get("watchedAt") if history else None
            removed_at = last_removed.get("removedAt") if last_removed else None

            if history_at is None and removed_at is None:
                raise OpError("Nothing to undo.", 409)

            undo_removal = removed_at is not None and (history_at is None or removed_at > history_at)
            episodes = self.store.get("episodes")

            if undo_removal:
                # A whole-series removal stores its episodes under
                # "items"; a single removal is the episode itself.
                restore = last_removed.get("items") or [last_removed]

                for raw in restore:
                    entry = dict(raw)
                    entry.pop("removedAt", None)

                    if not any(
                        _same_episode(x, entry.get("series"), entry.get("kind", "episode"),
                                      entry.get("season"), entry.get("episode"))
                        for x in episodes
                    ):
                        episodes.append(entry)

                self.store.commit({"episodes": episodes, "lastRemoved": {}})

                if "items" in last_removed:
                    return {"message": f"Restored {len(restore)} episode(s) of {last_removed.get('label') or last_removed.get('seriesKey')}"}

                return {"message": f"Restored removed episode: {_ep_code(restore[0])}"}

            item = history[-1]

            if item.get("malId"):
                try:
                    self.mal.restore_state(item["malId"], item.get("malPrevious") or {"exists": False})
                except Exception as e:
                    raise OpError(f"MAL restore failed: {e}\nHistory was NOT changed.", 502)

            history.pop()
            restored = dict(item)
            restored["watched"] = False
            restored.pop("watchedAt", None)
            restored.pop("malPrevious", None)

            if not any(
                _same_episode(x, restored.get("series"), restored.get("kind", "episode"),
                              restored.get("season"), restored.get("episode"))
                for x in episodes
            ):
                episodes.append(restored)

            changes = {"episodes": episodes, "history": history}

            # Undoing the final episode also withdraws its grade prompt.
            grades = self.store.get("pendingGrades")

            if grades.pop(_key_of(restored), None) is not None:
                changes["pendingGrades"] = grades

            self.store.commit(changes)
            return {"message": f"Undo successful: {_ep_code(restored)}"}

    def remove_episode(self, series, kind, season, episode):
        season, episode = int(season), int(episode)

        with self.store.op_lock:
            episodes = self.store.get("episodes")
            removed = next((x for x in episodes if _same_episode(x, series, kind, season, episode)), None)

            if removed is None:
                return {"message": "Episode not found in list -- nothing removed."}

            remaining = [x for x in episodes if x is not removed]
            removed = dict(removed)
            removed["removedAt"] = _now()
            self.store.commit({"episodes": remaining, "lastRemoved": removed})

        return {"message": f"Removed {_ep_code(removed)}"}

    def remove_series(self, series_key, label=None):
        """Remove every listed episode of one series (undoable as one action).

        The MAL mapping is kept, so future downloads still match.
        """
        with self.store.op_lock:
            episodes = self.store.get("episodes")
            removed = [x for x in episodes if _key_of(x) == series_key]

            if not removed:
                return {"message": "No episodes of that series in the list -- nothing removed."}

            remaining = [x for x in episodes if _key_of(x) != series_key]
            self.store.commit({
                "episodes": remaining,
                "lastRemoved": {
                    "removedAt": _now(),
                    "seriesKey": series_key,
                    "label": label or series_key,
                    "items": removed,
                },
            })

        return {"message": f"Removed {len(removed)} episode(s) of {label or series_key}"}

    def set_library_paths(self, items):
        """Record where each episode's hardlink sits in the Jellyfin
        library (path relative to the library root), as found by the
        PC client. Used to match Jellyfin's played items to the list."""
        if not isinstance(items, list):
            raise OpError("items must be a list")

        updated = 0

        with self.store.op_lock:
            episodes = self.store.get("episodes")

            for raw in items:
                try:
                    series, kind = raw["series"], raw.get("kind") or "episode"
                    season, episode = int(raw["season"]), int(raw["episode"])
                    rel = str(raw["libraryPath"]).strip()
                except (KeyError, TypeError, ValueError) as e:
                    raise OpError(f"Invalid entry {raw!r}: {e}")

                for item in episodes:
                    if _same_episode(item, series, kind, season, episode) and item.get("libraryPath") != rel:
                        item["libraryPath"] = rel
                        updated += 1

            if updated:
                self.store.commit({"episodes": episodes})

        return {"message": f"Recorded {updated} library path(s).", "updated": updated}

    # ---- series mapping -------------------------------------------

    def confirm_series(self, series_key, mal_id, title=None):
        mal_id = int(mal_id)
        details = {}

        try:
            details = self.mal.details(mal_id)
        except Exception as e:
            # Not fatal -- the mapping still works, we just won't know
            # the episode count (no grade prompt) or English title.
            self.log(f"Could not fetch details for MAL {mal_id}: {e}")

        # A bare MAL ID (no title) gets MAL's own title.
        title = title or details.get("title") or series_key

        with self.store.op_lock:
            series_map = self.store.get("seriesMap")
            pending = self.store.get("pendingMatches")
            episodes = self.store.get("episodes")

            series_map[series_key] = {
                "malId": mal_id,
                "title": title,
                "englishTitle": details.get("englishTitle"),
                "numEpisodes": details.get("numEpisodes"),
                "picture": details.get("picture"),
                "confirmed": True,
            }
            pending.pop(series_key, None)

            for item in episodes:
                if _key_of(item) == series_key:
                    item["malId"] = mal_id

            self.store.commit({"seriesMap": series_map, "pendingMatches": pending, "episodes": episodes})

        return {"message": f"Mapped '{series_key}' -> MAL {mal_id} ({title})"}

    def skip_series(self, series_key):
        with self.store.op_lock:
            series_map = self.store.get("seriesMap")
            pending = self.store.get("pendingMatches")
            series_map[series_key] = {"malId": None, "skipped": True}
            pending.pop(series_key, None)
            self.store.commit({"seriesMap": series_map, "pendingMatches": pending})

        return {"message": f"Marked '{series_key}' as skipped -- won't prompt for MAL matching again."}

    def remap_series(self, series_key, query=None):
        query = (query or "").strip() or series_key.split("::")[0]

        with self.store.op_lock:
            pending = self.store.get("pendingMatches")
            self._mark_searching(pending, series_key, query)
            self.store.commit({"pendingMatches": pending})

        self._spawn_search(series_key, query)
        return {"message": f"Searching MAL for '{query}'..."}

    # ---- grading --------------------------------------------------

    def grade(self, series_key, score=None):
        with self.store.op_lock:
            grades = self.store.get("pendingGrades")
            entry = grades.get(series_key)

            if not entry or not entry.get("malId"):
                raise OpError(f"No pending grade found for '{series_key}'.", 404)

            try:
                self.mal.mark_finished(entry["malId"], score)
            except Exception as e:
                raise OpError(f"Failed to mark '{series_key}' as finished -- leaving it pending.\n{e}", 502)

            grades.pop(series_key, None)
            self.store.commit({"pendingGrades": grades})

        return {"message": "Marked completed on MAL" + (f" with score {score}." if score else ".")}

    def dismiss_batch_warning(self, key):
        with self.store.op_lock:
            warnings = self.store.get("batchWarnings")
            warnings.pop(key, None)
            self.store.commit({"batchWarnings": warnings})

        return {"message": "Dismissed."}

    # ---- migration ------------------------------------------------

    def import_state(self, docs, force=False):
        allowed = ("episodes", "history", "seriesMap", "pendingMatches",
                   "pendingGrades", "batchWarnings", "lastRemoved")

        with self.store.op_lock:
            current = self.store.snapshot()

            if (current["episodes"] or current["history"] or current["seriesMap"]) and not force:
                raise OpError(
                    "The server already has data. Re-run with --force to overwrite it.", 409
                )

            changes = {k: docs[k] for k in allowed if k in docs and docs[k] is not None}

            # Searches can't resume from another machine's state.
            pending = changes.get("pendingMatches") or {}
            changes["pendingMatches"] = {
                k: v for k, v in pending.items() if v.get("status") != "searching"
            }

            self.store.commit(changes)

        return {"message": "Imported: " + ", ".join(f"{k} ({len(v)})" for k, v in changes.items())}
