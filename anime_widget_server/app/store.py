"""Persistent state, kept in SQLite.

The data keeps the same shape as the old ~/.local/share/anime-*.json
files (one JSON document per former file), so the widget's QML can
parse it unchanged. Every committed change bumps a revision number and
wakes up long-poll waiters, which is how the widget, standalone app and
phone get updates instantly.
"""

import copy
import json
import sqlite3
import threading
import time

DOCS = {
    "episodes": [],        # was anime-todo.json
    "history": [],         # anime-history.json
    "seriesMap": {},       # anime-series-map.json
    "pendingMatches": {},  # anime-pending-matches.json
    "pendingGrades": {},   # anime-pending-grades.json
    "batchWarnings": {},   # anime-batch-warnings.json
    "lastRemoved": {},     # anime-last-removed.json
    "jellyfinSeen": {},    # Jellyfin item id -> last played date already handled
}


class Store:
    def __init__(self, path):
        self._db = sqlite3.connect(path, check_same_thread=False)
        self._db.execute("PRAGMA journal_mode=WAL")
        self._db.execute("CREATE TABLE IF NOT EXISTS docs (name TEXT PRIMARY KEY, json TEXT NOT NULL)")
        self._db.execute("CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
        self._db.commit()

        self._cond = threading.Condition()
        # Serializes whole operations (including slow MAL calls made in
        # the middle of them) -- the server-side replacement for the
        # old flock on anime-todo.lock.
        self.op_lock = threading.RLock()

        self._docs = {}
        self._raw = {}

        for name, default in DOCS.items():
            row = self._db.execute("SELECT json FROM docs WHERE name=?", (name,)).fetchone()
            raw = row[0] if row else json.dumps(default)
            self._raw[name] = raw
            self._docs[name] = json.loads(raw)

        row = self._db.execute("SELECT value FROM meta WHERE key='rev'").fetchone()
        self.rev = int(row[0]) if row else 0
        self.changed_at = time.time()

    def snapshot(self):
        """Deep copy of every document plus the current revision."""
        with self._cond:
            data = copy.deepcopy(self._docs)
            data["rev"] = self.rev
            return data

    def get(self, name):
        with self._cond:
            return copy.deepcopy(self._docs[name])

    def commit(self, changes):
        """Persist the given {docName: value} changes atomically.

        Only documents whose serialized content actually changed are
        written; the revision is bumped only if something did.
        """
        with self._cond:
            dirty = {}

            for name, value in changes.items():
                if name not in DOCS:
                    raise KeyError(name)

                raw = json.dumps(value, ensure_ascii=False)

                if raw != self._raw[name]:
                    dirty[name] = (value, raw)

            if not dirty:
                return self.rev

            with self._db:
                for name, (_, raw) in dirty.items():
                    self._db.execute(
                        "INSERT INTO docs(name, json) VALUES(?, ?) "
                        "ON CONFLICT(name) DO UPDATE SET json=excluded.json",
                        (name, raw),
                    )

                self._db.execute(
                    "INSERT INTO meta(key, value) VALUES('rev', ?) "
                    "ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                    (str(self.rev + 1),),
                )

            for name, (value, raw) in dirty.items():
                self._raw[name] = raw
                self._docs[name] = copy.deepcopy(value)

            self.rev += 1
            self.changed_at = time.time()
            self._cond.notify_all()
            return self.rev

    def wait_for_change(self, since, timeout):
        with self._cond:
            self._cond.wait_for(lambda: self.rev != since, timeout=timeout)
            return self.rev
