import QtQuick
import org.kde.plasma.plasma5support as Plasma5Support

// Shared data/logic layer for the anime tracker. Holds all state,
// talks to anime-downloaded.sh, and exposes plain methods so any
// host (the Plasma widget, or a standalone app) can drive it without
// knowing anything about plasmoid.configuration or Plasma5Support.
Item {
    id: backend

    property string scriptPath: "$HOME/.local/bin/anime-downloaded.sh"
    property string watchScriptPath: "$HOME/.local/bin/anime-watch-changes.sh"
    property bool watcherFallbackWarned: false

    property int refreshInterval: 3
    property bool preferEnglishTitle: false

    property var episodes: []
    property var history: []
    property var pendingMatches: ({})
    property var seriesMap: ({})
    property var pendingGrades: ({})
    property var lastRemoved: ({})
    property var batchWarnings: ({})

    // Set when the server (Home Assistant add-on) can't be reached --
    // the lists above then show the last known state, and new
    // downloads wait in a local outbox until it's back.
    property bool offline: false
    property string offlineReason: ""
    property int outboxCount: 0

    property string errorSource: ""
    property string errorMessage: ""
    property string lastShownError: ""
    property string animeRoot: ""

    function preferredTitle(entry) {
        if (!entry) {
            return null
        }

        if (backend.preferEnglishTitle && entry.englishTitle) {
            return entry.englishTitle
        }

        return entry.title || null
    }

    // Derives a human-readable label from a MAL-matching identity
    // key. Plain folder-name keys are returned as-is; composite keys
    // from multi-group batches ("<folder>::<kind>S<season>") are
    // turned into something like "Show Season 2" or "Show (OVA)".
    function seriesKeyLabel(key) {
        var parts = key.split("::")

        if (parts.length !== 2) {
            return key
        }

        var match = parts[1].match(/^(episode|movie|ova|special)S(\d+)$/)

        if (!match) {
            return key
        }

        var kind = match[1]
        var season = parseInt(match[2])

        if (kind === "episode") {
            return parts[0] + " Season " + season
        }

        var kindLabel = kind === "ova" ? "OVA" : (kind.charAt(0).toUpperCase() + kind.slice(1))

        return parts[0] + " (" + kindLabel + ")"
    }

    function groupDisplayLabel(seriesKey) {
        var mapEntry = backend.seriesMap[seriesKey]

        if (mapEntry && mapEntry.malId) {
            var preferred = backend.preferredTitle(mapEntry)

            if (preferred) {
                return preferred
            }
        }

        return backend.seriesKeyLabel(seriesKey)
    }

    function groupedEpisodes() {
        var groups = {}
        var kindPriority = { episode: 0, special: 1, ova: 2, movie: 3 }

        for (var i = 0; i < backend.episodes.length; i++) {
            var episode = backend.episodes[i]
            var key = episode.seriesKey || episode.series

            if (!groups[key]) {
                groups[key] = []
            }

            groups[key].push(episode)
        }

        var result = []

        for (var key in groups) {
            var groupEpisodes = groups[key]

            // Count how many items share each kind within this
            // group, so a Movie/OVA/Special label can tell "the
            // only one" from "one of several" instead of just
            // checking its own episode number in isolation.
            var kindCounts = {}

            for (var j = 0; j < groupEpisodes.length; j++) {
                var epKind = groupEpisodes[j].kind || "episode"
                kindCounts[epKind] = (kindCounts[epKind] || 0) + 1
            }

            for (var j = 0; j < groupEpisodes.length; j++) {
                var epKind = groupEpisodes[j].kind || "episode"
                groupEpisodes[j].kindCount = kindCounts[epKind]
            }

            groupEpisodes.sort(function(a, b) {
                var aKind = kindPriority[a.kind || "episode"]
                var bKind = kindPriority[b.kind || "episode"]

                if (aKind === undefined) aKind = 99
                if (bKind === undefined) bKind = 99

                if (aKind !== bKind) {
                    return aKind - bKind
                }

                if (a.season !== b.season) {
                    return a.season - b.season
                }

                return a.episode - b.episode
            })

            result.push({
                seriesKey: key,
                label: backend.groupDisplayLabel(key),
                episodes: groupEpisodes
            })
        }

        result.sort(function(a, b) {
            return a.label.localeCompare(b.label)
        })

        return result
    }

    function seriesMapList() {
        var arr = []

        for (var key in backend.seriesMap) {
            arr.push({ key: key, entry: backend.seriesMap[key] })
        }

        arr.sort(function(a, b) {
            return a.key.localeCompare(b.key)
        })

        return arr
    }

    function activeSeriesMapList() {
        return backend.seriesMapList().filter(function(x) {
            return backend.episodes.some(function(e) { return (e.seriesKey || e.series) === x.key })
        })
    }

    function inactiveSeriesMapList() {
        return backend.seriesMapList().filter(function(x) {
            return !backend.episodes.some(function(e) { return (e.seriesKey || e.series) === x.key })
        })
    }

    function episodeLabel(episode) {
        var kind = episode.kind || "episode"

        if (kind === "episode") {
            return i18n("Episode %1", episode.episode)
        }

        var kindLabel

        if (kind === "ova") {
            kindLabel = "OVA"
        } else if (kind === "ona") {
            kindLabel = "ONA"
        } else {
            kindLabel = kind.charAt(0).toUpperCase() + kind.slice(1)
        }

        var count = episode.kindCount || 1

        return count > 1 ? i18n("%1 %2", kindLabel, episode.episode) : kindLabel
    }

    function reportError(source, detail) {
        var command = source.replace(scriptPath + " ", "")
        var key = command + "|" + detail

        if (key === backend.lastShownError) {
            return
        }

        backend.lastShownError = key
        backend.errorSource = command
        backend.errorMessage = detail
    }

    function removeEpisode(episode) {
        executable.run(
            scriptPath + " remove-episode " +
            JSON.stringify(episode.series) + " " +
            JSON.stringify(episode.kind || "episode") + " " +
            episode.season + " " +
            episode.episode
        )

        refreshTimer.restart()
    }

    // Removes every listed episode of one series in a single,
    // undoable step. The MAL match is kept for future downloads.
    function removeSeries(seriesKey, label) {
        executable.run(
            scriptPath + " remove-series " +
            JSON.stringify(seriesKey) + " " +
            JSON.stringify(label || seriesKey)
        )

        refreshTimer.restart()
    }

    function openContainingFolder(episode) {
        var path = episode.path
        var lastSlash = path.lastIndexOf("/")
        var dir = lastSlash >= 0 ? path.substring(0, lastSlash) : path

        executable.run(
            "xdg-open " + JSON.stringify(dir)
        )
    }

    function openFile(path) {
        executable.run(
            "xdg-open " + JSON.stringify(path)
        )
    }

    function markDone(episode) {
        executable.run(
            scriptPath + " done " +
            JSON.stringify(episode.series) + " " +
            episode.season + " " +
            episode.episode + " " +
            JSON.stringify(episode.kind || "episode")
        )

        refreshTimer.restart()
    }

    function undoLast() {
        executable.run(
            scriptPath + " undo"
        )

        refreshTimer.restart()
    }

    function confirmSeries(seriesKey, malId, title) {
        executable.run(
            scriptPath + " confirm-series " +
            JSON.stringify(seriesKey) + " " +
            malId + " " +
            JSON.stringify(title)
        )

        refreshTimer.restart()
    }

    function skipSeries(seriesKey) {
        executable.run(
            scriptPath + " skip-series " + JSON.stringify(seriesKey)
        )

        refreshTimer.restart()
    }

    function remapSeries(seriesKey, query) {
        executable.run(
            scriptPath + " remap-series " +
            JSON.stringify(seriesKey) + " " +
            JSON.stringify(query)
        )

        refreshTimer.restart()
    }

    function gradeSeries(seriesKey, score) {
        executable.run(
            scriptPath + " grade-series " +
            JSON.stringify(seriesKey) + " " +
            score
        )

        refreshTimer.restart()
    }

    function skipGradeSeries(seriesKey) {
        executable.run(
            scriptPath + " skip-grade " + JSON.stringify(seriesKey)
        )

        refreshTimer.restart()
    }

    function dismissBatchWarning(key) {
        executable.run(
            scriptPath + " dismiss-batch-warning " + JSON.stringify(key)
        )

        refreshTimer.restart()
    }

    function setAnimeRoot(path) {
        executable.run(
            scriptPath + " set-config " + JSON.stringify(path)
        )

        refreshTimer.restart()
    }

    // One round-trip fetches everything (episodes, history, series
    // map, pending matches/grades, last removed, batch warnings).
    function refresh() {
        executable.run(scriptPath + " state")
        executable.run(scriptPath + " get-config")
    }

    function applyState(state) {
        backend.episodes = state.episodes || []
        backend.history = state.history || []
        backend.pendingMatches = state.pendingMatches || {}
        backend.seriesMap = state.seriesMap || {}
        backend.pendingGrades = state.pendingGrades || {}
        backend.lastRemoved = state.lastRemoved || {}
        backend.batchWarnings = state.batchWarnings || {}
        backend.offline = !!state.offline
        backend.offlineReason = state.offlineReason || ""
        backend.outboxCount = state.outboxCount || 0
    }

    Plasma5Support.DataSource {
        id: executable
        engine: "executable"
        connectedSources: []

        onNewData: function(source, data) {
            disconnectSource(source)

            var exitCode = data["exit code"]

            // The file watcher is a special case: it blocks until one
            // change happens, then exits. A non-zero exit usually means
            // inotify-tools isn't installed -- fall back to timer-only
            // polling silently rather than nagging with an error dialog
            // every time. A zero exit means a real change happened --
            // refresh now and immediately start watching again.
            if (source === backend.watchScriptPath) {
                if (exitCode !== 0) {
                    if (!backend.watcherFallbackWarned) {
                        backend.watcherFallbackWarned = true
                        console.log(
                            "anime-todo: file watcher unavailable, falling back to timer polling.",
                            data["stderr"] || ""
                        )
                    }
                    return
                }

                backend.refresh()
                executable.run(backend.watchScriptPath)
                return
            }

            if (exitCode !== undefined && exitCode !== 0) {
                var stderrText = (data["stderr"] || "").trim()
                var stdoutText = (data["stdout"] || "").trim()
                var detail

                if (stdoutText && stderrText) {
                    detail = stdoutText + "\n\n" + stderrText
                } else {
                    detail = stdoutText || stderrText || i18n("No error output was captured.")
                }

                backend.reportError(source, detail)
                return
            }

            if (source === backend.scriptPath + " state") {
                try {
                    backend.applyState(JSON.parse(data["stdout"] || "{}"))
                } catch (error) {
                    console.log("Failed to parse anime state JSON:", error)
                }
            }

            if (source === backend.scriptPath + " get-config") {
                backend.animeRoot = (data["stdout"] || "").trim()
            }
        }

        function run(command) {
            connectSource(command)
        }
    }

    Timer {
        id: refreshTimer
        interval: backend.refreshInterval * 1000
        repeat: true
        running: true
        onTriggered: backend.refresh()
    }

    Component.onCompleted: {
        backend.refresh()
        executable.run(backend.watchScriptPath)
    }
}
