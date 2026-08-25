import QtQuick
import QtQuick.Controls as Controls
import QtQuick.Layouts
import QtCore
import org.kde.plasma.plasmoid
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.plasma5support as Plasma5Support
import org.kde.kirigami as Kirigami

PlasmoidItem {
    id: root
    Plasmoid.backgroundHints: PlasmaCore.Types.NoBackground
    property var episodes: []
    property string scriptPath: "$HOME/.local/bin/anime-downloaded.sh"
    property string watchScriptPath: "$HOME/.local/bin/anime-watch-changes.sh"
    property bool watcherFallbackWarned: false

    property var history: []
    property var pendingMatches: ({})
    property var seriesMap: ({})
    property var pendingGrades: ({})
    property var lastRemoved: ({})
    property string errorSource: ""
    property string errorMessage: ""
    property string lastShownError: ""

    function groupedEpisodes() {
        var groups = {}

        for (var i = 0; i < root.episodes.length; i++) {
            var episode = root.episodes[i]
            var series = episode.series

            if (!groups[series]) {
                groups[series] = []
            }

            groups[series].push(episode)
        }

        var result = []

        for (var series in groups) {
            groups[series].sort(function(a, b) {
                if (a.season !== b.season) {
                    return a.season - b.season
                }

                return a.episode - b.episode
            })

            result.push({
                series: series,
                episodes: groups[series]
            })
        }

        result.sort(function(a, b) {
            return a.series.localeCompare(b.series)
        })
        return result
    }

    function seriesMapList() {
        var arr = []

        for (var key in root.seriesMap) {
            arr.push({ key: key, entry: root.seriesMap[key] })
        }

        arr.sort(function(a, b) {
            return a.key.localeCompare(b.key)
        })

        return arr
    }

    function activeSeriesMapList() {
        return root.seriesMapList().filter(function(x) {
            return root.episodes.some(function(e) { return e.series === x.key })
        })
    }

    function inactiveSeriesMapList() {
        return root.seriesMapList().filter(function(x) {
            return !root.episodes.some(function(e) { return e.series === x.key })
        })
    }

    function episodeLabel(episode) {
        var kind = episode.kind || "episode"

        if (kind === "movie") {
            return episode.episode > 1 ? i18n("Movie %1", episode.episode) : i18n("Movie")
        }

        if (kind === "ova") {
            return episode.episode > 1 ? i18n("OVA %1", episode.episode) : i18n("OVA")
        }

        if (kind === "special") {
            return episode.episode > 1 ? i18n("Special %1", episode.episode) : i18n("Special")
        }

        return "S"
        + ("0" + episode.season).slice(-2)
        + "E"
        + ("0" + episode.episode).slice(-2)
    }

    function reportError(source, detail) {
        var command = source.replace(scriptPath + " ", "")
        var key = command + "|" + detail

        if (key === root.lastShownError) {
            return
        }

        root.lastShownError = key
        root.errorSource = command
        root.errorMessage = detail
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
            if (source === root.watchScriptPath) {
                if (exitCode !== 0) {
                    if (!root.watcherFallbackWarned) {
                        root.watcherFallbackWarned = true
                        console.log(
                            "anime-todo: file watcher unavailable, falling back to timer polling.",
                            data["stderr"] || ""
                        )
                    }
                    return
                }

                root.refresh()
                executable.run(root.watchScriptPath)
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

                root.reportError(source, detail)
                return
            }

            if (source === scriptPath + " list") {
                var output = data["stdout"] || ""

                try {
                    root.episodes = JSON.parse(output)
                } catch (error) {
                    console.log("Failed to parse anime JSON:", error)
                    root.episodes = []
                }
            }

            if (source === scriptPath + " history") {
                var historyOutput = data["stdout"] || ""

                try {
                    root.history = JSON.parse(historyOutput)
                } catch (error) {
                    console.log("Failed to parse anime history JSON:", error)
                    root.history = []
                }
            }

            if (source === scriptPath + " pending") {
                var pendingOutput = data["stdout"] || ""

                try {
                    root.pendingMatches = JSON.parse(pendingOutput)
                } catch (error) {
                    console.log("Failed to parse pending matches JSON:", error)
                    root.pendingMatches = {}
                }
            }

            if (source === scriptPath + " series-map") {
                var seriesMapOutput = data["stdout"] || ""

                try {
                    root.seriesMap = JSON.parse(seriesMapOutput)
                } catch (error) {
                    console.log("Failed to parse series map JSON:", error)
                    root.seriesMap = {}
                }
            }

            if (source === scriptPath + " pending-grades") {
                var pendingGradesOutput = data["stdout"] || ""

                try {
                    root.pendingGrades = JSON.parse(pendingGradesOutput)
                } catch (error) {
                    console.log("Failed to parse pending grades JSON:", error)
                    root.pendingGrades = {}
                }
            }

            if (source === scriptPath + " last-removed") {
                var lastRemovedOutput = data["stdout"] || ""

                try {
                    root.lastRemoved = JSON.parse(lastRemovedOutput)
                } catch (error) {
                    console.log("Failed to parse last-removed JSON:", error)
                    root.lastRemoved = {}
                }
            }
        }

        function run(command) {
            connectSource(command)
        }
    }

    function refresh() {
        executable.run(
            scriptPath + " list"
        )
        executable.run(
            scriptPath + " history"
        )
        executable.run(
            scriptPath + " pending"
        )
        executable.run(
            scriptPath + " series-map"
        )
        executable.run(
            scriptPath + " pending-grades"
        )
        executable.run(
            scriptPath + " last-removed"
        )
    }

    function markDone(episode) {
        executable.run(
            scriptPath + " done " +
            JSON.stringify(episode.series) + " " +
            episode.season + " " +
            episode.episode
        )

        refreshTimer.restart()

    }

    function undoLast() {
        executable.run(
            scriptPath + " undo"
        )

        refreshTimer.restart()
    }

    // Fallback safety net -- the file watcher (started below) is the
    // primary refresh trigger. This timer covers the case where
    // inotify-tools isn't installed, or the watcher misses something.
    Timer {
        id: refreshTimer

        interval: plasmoid.configuration.refreshInterval * 1000
        repeat: true
        running: true

        onTriggered: root.refresh()
    }

    Component.onCompleted: {
        root.refresh()
        executable.run(root.watchScriptPath)
    }

    compactRepresentation: Controls.Label {
        text: plasmoid.configuration.showEpisodeCount &&
        root.episodes.length > 0
        ? root.episodes.length
        : ""

        color: Kirigami.Theme.textColor
        font.pixelSize: Kirigami.Units.gridUnit * 1.2
    }

    fullRepresentation: Item {
        id: fullRep

        property string activeSeriesKey: ""
        property string activeGradeSeriesKey: ""

        function nextPendingSeries() {
            for (var key in root.pendingMatches) {
                if (root.pendingMatches[key].status === "ready") {
                    return key
                }
            }
            return ""
        }

        function maybeShowNextPending() {
            if (seriesMatchDialog.visible) {
                return
            }

            var key = nextPendingSeries()

            if (key === "") {
                return
            }

            activeSeriesKey = key
            seriesMatchDialog.seriesKey = key
            seriesMatchDialog.candidates = root.pendingMatches[key].candidates || []
            seriesMatchDialog.open()
        }

        function confirmActiveSeries(malId, title) {
            executable.run(
                scriptPath + " confirm-series " +
                JSON.stringify(activeSeriesKey) + " " +
                malId + " " +
                JSON.stringify(title)
            )

            activeSeriesKey = ""
            refreshTimer.restart()
        }

        function skipActiveSeries() {
            executable.run(
                scriptPath + " skip-series " + JSON.stringify(activeSeriesKey)
            )

            activeSeriesKey = ""
            refreshTimer.restart()
        }

        function nextPendingGrade() {
            for (var key in root.pendingGrades) {
                return key
            }
            return ""
        }

        function maybeShowNextGrade() {
            if (gradeDialog.visible) {
                return
            }

            var key = nextPendingGrade()

            if (key === "") {
                return
            }

            if (!plasmoid.configuration.askToGrade) {
                activeGradeSeriesKey = key
                skipGrade()
                return
            }

            activeGradeSeriesKey = key
            gradeDialog.seriesKey = key
            gradeDialog.seriesTitle = root.pendingGrades[key].title || key
            gradeDialog.open()
        }

        function submitGrade(score) {
            executable.run(
                scriptPath + " grade-series " +
                JSON.stringify(activeGradeSeriesKey) + " " +
                score
            )

            activeGradeSeriesKey = ""
            refreshTimer.restart()
        }

        function skipGrade() {
            executable.run(
                scriptPath + " skip-grade " + JSON.stringify(activeGradeSeriesKey)
            )

            activeGradeSeriesKey = ""
            refreshTimer.restart()
        }

        function nextBatchWarning() {
            for (var key in root.batchWarnings) {
                return key
            }
            return ""
        }

        function maybeShowNextBatchWarning() {
            if (batchWarningDialog.visible) {
                return
            }

            var key = nextBatchWarning()

            if (key === "") {
                return
            }

            batchWarningDialog.warningKey = key
            batchWarningDialog.message = root.batchWarnings[key].message || ""
            batchWarningDialog.open()
        }

        function dismissBatchWarning(key) {
            executable.run(
                scriptPath + " dismiss-batch-warning " + JSON.stringify(key)
            )

            refreshTimer.restart()
        }

        Connections {
            target: root
            function onPendingMatchesChanged() {
                fullRep.maybeShowNextPending()
            }
        }

        Connections {
            target: root
            function onPendingGradesChanged() {
                fullRep.maybeShowNextGrade()
            }
        }

        Connections {
            target: root
            function onBatchWarningsChanged() {
                fullRep.maybeShowNextBatchWarning()
            }
        }

        Connections {
            target: root
            function onErrorMessageChanged() {
                if (root.errorMessage !== "") {
                    errorDialog.open()
                }
            }
        }

        Component.onCompleted: {
            maybeShowNextPending()
            maybeShowNextGrade()
            maybeShowNextBatchWarning()
        }

        Controls.Dialog {
            id: seriesMatchDialog

            modal: true
            parent: Controls.Overlay.overlay
            x: Math.round((parent.width - width) / 2)
            y: Math.round((parent.height - height) / 2)
            width: Math.min(parent.width - Kirigami.Units.gridUnit * 2, Kirigami.Units.gridUnit * 24)
            title: i18n("Match series")

            property string seriesKey: ""
            property var candidates: []
            property int selectedId: -1

            onOpened: selectedId = -1

            contentItem: ColumnLayout {
                spacing: Kirigami.Units.smallSpacing

                Controls.Label {
                    Layout.fillWidth: true
                    wrapMode: Text.WordWrap
                    text: i18n("Which anime is \"%1\"?", seriesMatchDialog.seriesKey)
                }

                ListView {
                    Layout.fillWidth: true
                    Layout.preferredHeight: Kirigami.Units.gridUnit * 16
                    clip: true
                    model: seriesMatchDialog.candidates
                    spacing: Kirigami.Units.smallSpacing

                    delegate: Controls.ItemDelegate {
                        width: ListView.view.width
                        highlighted: seriesMatchDialog.selectedId === modelData.id

                        onClicked: seriesMatchDialog.selectedId = modelData.id

                        contentItem: RowLayout {
                            spacing: Kirigami.Units.smallSpacing

                            Image {
                                source: modelData.picture || ""
                                Layout.preferredWidth: Kirigami.Units.gridUnit * 3
                                Layout.preferredHeight: Kirigami.Units.gridUnit * 4
                                fillMode: Image.PreserveAspectCrop
                                asynchronous: true
                            }

                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 0

                                Controls.Label {
                                    Layout.fillWidth: true
                                    wrapMode: Text.WordWrap
                                    font.bold: true
                                    text: modelData.title
                                }

                                Controls.Label {
                                    Layout.fillWidth: true
                                    opacity: 0.7
                                    text: [modelData.mediaType, modelData.startYear].filter(x => x).join(" \u2022 ")
                                }
                            }
                        }
                    }
                }
            }

            footer: Controls.DialogButtonBox {
                Controls.Button {
                    text: i18n("Skip")
                    Controls.DialogButtonBox.buttonRole: Controls.DialogButtonBox.RejectRole
                    onClicked: {
                        fullRep.skipActiveSeries()
                        seriesMatchDialog.close()
                    }
                }

                Controls.Button {
                    text: i18n("Confirm")
                    enabled: seriesMatchDialog.selectedId !== -1
                    Controls.DialogButtonBox.buttonRole: Controls.DialogButtonBox.AcceptRole
                    onClicked: {
                        var chosen = seriesMatchDialog.candidates.find(
                            function(c) { return c.id === seriesMatchDialog.selectedId }
                        )

                        if (chosen) {
                            fullRep.confirmActiveSeries(chosen.id, chosen.title)
                        }

                        seriesMatchDialog.close()
                    }
                }
            }
        }

        Controls.Dialog {
            id: manageSeriesDialog

            modal: true
            parent: Controls.Overlay.overlay
            x: Math.round((parent.width - width) / 2)
            y: Math.round((parent.height - height) / 2)
            width: Math.min(parent.width - Kirigami.Units.gridUnit * 2, Kirigami.Units.gridUnit * 28)
            height: Math.min(parent.height - Kirigami.Units.gridUnit * 2, Kirigami.Units.gridUnit * 24)
            title: i18n("Manage series matches")

            property bool showFinished: false

            onOpened: root.refresh()

            contentItem: Controls.ScrollView {
                clip: true

                ColumnLayout {
                    width: manageSeriesDialog.availableWidth
                    spacing: Kirigami.Units.smallSpacing

                    Repeater {
                        model: root.activeSeriesMapList()

                        delegate: Kirigami.AbstractCard {
                            Layout.fillWidth: true

                            contentItem: ColumnLayout {
                                spacing: Kirigami.Units.smallSpacing

                                Controls.Label {
                                    Layout.fillWidth: true
                                    wrapMode: Text.WordWrap
                                    font.bold: true
                                    text: modelData.key
                                }

                                Controls.Label {
                                    Layout.fillWidth: true
                                    opacity: 0.7
                                    wrapMode: Text.WordWrap
                                    text: modelData.entry.skipped
                                    ? i18n("Skipped -- not tracked on MAL")
                                    : modelData.entry.malId
                                    ? i18n("Mapped to \"%1\" (MAL %2)", modelData.entry.title || "?", modelData.entry.malId)
                                    : i18n("Not mapped yet")
                                }

                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: Kirigami.Units.smallSpacing

                                    Controls.TextField {
                                        id: queryField
                                        Layout.fillWidth: true
                                        placeholderText: i18n("Search MAL as...")
                                        text: modelData.key
                                    }

                                    Controls.Button {
                                        text: i18n("Search")
                                        onClicked: {
                                            executable.run(
                                                root.scriptPath + " remap-series " +
                                                JSON.stringify(modelData.key) + " " +
                                                JSON.stringify(queryField.text)
                                            )
                                            refreshTimer.restart()
                                        }
                                    }
                                }

                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: Kirigami.Units.smallSpacing

                                    Controls.TextField {
                                        id: idField
                                        Layout.preferredWidth: Kirigami.Units.gridUnit * 6
                                        placeholderText: i18n("MAL ID")
                                        validator: IntValidator { bottom: 1 }
                                    }

                                    Controls.Button {
                                        text: i18n("Set ID")
                                        enabled: idField.text.length > 0
                                        onClicked: {
                                            executable.run(
                                                root.scriptPath + " confirm-series " +
                                                JSON.stringify(modelData.key) + " " +
                                                idField.text + " " +
                                                JSON.stringify("")
                                            )
                                            idField.text = ""
                                            refreshTimer.restart()
                                        }
                                    }
                                }
                            }
                        }
                    }

                    Controls.Button {
                        Layout.fillWidth: true
                        visible: root.inactiveSeriesMapList().length > 0
                        text: manageSeriesDialog.showFinished
                        ? i18n("Hide finished series")
                        : i18n("Show %1 finished series", root.inactiveSeriesMapList().length)
                        onClicked: manageSeriesDialog.showFinished = !manageSeriesDialog.showFinished
                    }

                    Repeater {
                        model: manageSeriesDialog.showFinished ? root.inactiveSeriesMapList() : []

                        delegate: Kirigami.AbstractCard {
                            Layout.fillWidth: true

                            contentItem: ColumnLayout {
                                spacing: Kirigami.Units.smallSpacing

                                Controls.Label {
                                    Layout.fillWidth: true
                                    wrapMode: Text.WordWrap
                                    font.bold: true
                                    text: modelData.key
                                }

                                Controls.Label {
                                    Layout.fillWidth: true
                                    opacity: 0.7
                                    wrapMode: Text.WordWrap
                                    text: modelData.entry.skipped
                                    ? i18n("Skipped -- not tracked on MAL")
                                    : modelData.entry.malId
                                    ? i18n("Mapped to \"%1\" (MAL %2)", modelData.entry.title || "?", modelData.entry.malId)
                                    : i18n("Not mapped yet")
                                }

                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: Kirigami.Units.smallSpacing

                                    Controls.TextField {
                                        id: queryFieldFinished
                                        Layout.fillWidth: true
                                        placeholderText: i18n("Search MAL as...")
                                        text: modelData.key
                                    }

                                    Controls.Button {
                                        text: i18n("Search")
                                        onClicked: {
                                            executable.run(
                                                root.scriptPath + " remap-series " +
                                                JSON.stringify(modelData.key) + " " +
                                                JSON.stringify(queryFieldFinished.text)
                                            )
                                            refreshTimer.restart()
                                        }
                                    }
                                }

                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: Kirigami.Units.smallSpacing

                                    Controls.TextField {
                                        id: idFieldFinished
                                        Layout.preferredWidth: Kirigami.Units.gridUnit * 6
                                        placeholderText: i18n("MAL ID")
                                        validator: IntValidator { bottom: 1 }
                                    }

                                    Controls.Button {
                                        text: i18n("Set ID")
                                        enabled: idFieldFinished.text.length > 0
                                        onClicked: {
                                            executable.run(
                                                root.scriptPath + " confirm-series " +
                                                JSON.stringify(modelData.key) + " " +
                                                idFieldFinished.text + " " +
                                                JSON.stringify("")
                                            )
                                            idFieldFinished.text = ""
                                            refreshTimer.restart()
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }

            footer: Controls.DialogButtonBox {
                Controls.Button {
                    text: i18n("Close")
                    Controls.DialogButtonBox.buttonRole: Controls.DialogButtonBox.RejectRole
                    onClicked: manageSeriesDialog.close()
                }
            }
        }

        Controls.Dialog {
            id: gradeDialog

            modal: true
            parent: Controls.Overlay.overlay
            x: Math.round((parent.width - width) / 2)
            y: Math.round((parent.height - height) / 2)
            width: Math.min(parent.width - Kirigami.Units.gridUnit * 2, Kirigami.Units.gridUnit * 22)
            title: i18n("Finished!")

            property string seriesKey: ""
            property string seriesTitle: ""

            onOpened: scoreSpinBox.value = 7

            contentItem: ColumnLayout {
                spacing: Kirigami.Units.smallSpacing

                Controls.Label {
                    Layout.fillWidth: true
                    wrapMode: Text.WordWrap
                    text: i18n("You finished \"%1\". Want to rate it?", gradeDialog.seriesTitle)
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Kirigami.Units.smallSpacing

                    Controls.Label {
                        text: i18n("Score:")
                    }

                    Controls.SpinBox {
                        id: scoreSpinBox
                        from: 1
                        to: 10
                        value: 7
                    }
                }
            }

            footer: Controls.DialogButtonBox {
                Controls.Button {
                    text: i18n("Skip")
                    Controls.DialogButtonBox.buttonRole: Controls.DialogButtonBox.RejectRole
                    onClicked: {
                        fullRep.skipGrade()
                        gradeDialog.close()
                    }
                }

                Controls.Button {
                    text: i18n("Submit")
                    Controls.DialogButtonBox.buttonRole: Controls.DialogButtonBox.AcceptRole
                    onClicked: {
                        fullRep.submitGrade(scoreSpinBox.value)
                        gradeDialog.close()
                    }
                }
            }
        }

        Controls.Dialog {
            id: batchWarningDialog

            modal: true
            parent: Controls.Overlay.overlay
            x: Math.round((parent.width - width) / 2)
            y: Math.round((parent.height - height) / 2)
            width: Math.min(parent.width - Kirigami.Units.gridUnit * 2, Kirigami.Units.gridUnit * 24)
            title: i18n("Batch warning")

            property string warningKey: ""
            property string message: ""

            contentItem: ColumnLayout {
                spacing: Kirigami.Units.smallSpacing

                Controls.Label {
                    Layout.fillWidth: true
                    wrapMode: Text.WordWrap
                    text: batchWarningDialog.message
                }
            }

            footer: Controls.DialogButtonBox {
                Controls.Button {
                    text: i18n("Dismiss")
                    Controls.DialogButtonBox.buttonRole: Controls.DialogButtonBox.AcceptRole
                    onClicked: {
                        fullRep.dismissBatchWarning(batchWarningDialog.warningKey)
                        batchWarningDialog.close()
                    }
                }
            }
        }

        Controls.Dialog {
            id: undoConfirmDialog

            modal: true
            parent: Controls.Overlay.overlay
            x: Math.round((parent.width - width) / 2)
            y: Math.round((parent.height - height) / 2)
            width: Math.min(parent.width - Kirigami.Units.gridUnit * 2, Kirigami.Units.gridUnit * 20)
            title: i18n("Undo last action?")

            contentItem: Controls.Label {
                wrapMode: Text.WordWrap
                text: i18n("This will undo your most recent action -- either the last checked-off episode or the last removed one, whichever happened more recently.")
            }

            footer: Controls.DialogButtonBox {
                Controls.Button {
                    text: i18n("Cancel")
                    Controls.DialogButtonBox.buttonRole: Controls.DialogButtonBox.RejectRole
                    onClicked: undoConfirmDialog.close()
                }

                Controls.Button {
                    text: i18n("Undo")
                    Controls.DialogButtonBox.buttonRole: Controls.DialogButtonBox.AcceptRole
                    onClicked: {
                        root.undoLast()
                        undoConfirmDialog.close()
                    }
                }
            }
        }

        Controls.Dialog {
            id: errorDialog

            modal: true
            parent: Controls.Overlay.overlay
            x: Math.round((parent.width - width) / 2)
            y: Math.round((parent.height - height) / 2)
            width: Math.min(parent.width - Kirigami.Units.gridUnit * 2, Kirigami.Units.gridUnit * 24)
            title: i18n("Something went wrong")

            contentItem: ColumnLayout {
                spacing: Kirigami.Units.smallSpacing

                Controls.Label {
                    Layout.fillWidth: true
                    wrapMode: Text.WordWrap
                    text: i18n("Command \"%1\" failed:", root.errorSource)
                }

                Controls.ScrollView {
                    Layout.fillWidth: true
                    Layout.preferredHeight: Kirigami.Units.gridUnit * 8

                    Controls.TextArea {
                        readOnly: true
                        wrapMode: Text.WordWrap
                        text: root.errorMessage
                        font.family: "monospace"
                    }
                }
            }

            footer: Controls.DialogButtonBox {
                Controls.Button {
                    text: i18n("OK")
                    Controls.DialogButtonBox.buttonRole: Controls.DialogButtonBox.AcceptRole
                    onClicked: errorDialog.close()
                }
            }
        }

        Rectangle {
            anchors.fill: parent
            color: Kirigami.Theme.backgroundColor
            opacity: plasmoid.configuration.backgroundOpacity / 100.0
            radius: Kirigami.Units.smallSpacing
        }

        Layout.minimumWidth: Kirigami.Units.gridUnit * 10
        Layout.minimumHeight: Kirigami.Units.gridUnit * 8
        Layout.preferredWidth: Kirigami.Units.gridUnit * 22
        Layout.preferredHeight: Kirigami.Units.gridUnit * 14

        ColumnLayout {
            id: verticalLayout

            anchors.fill: parent
            spacing: plasmoid.configuration.itemSpacing

            Item {
                Layout.fillWidth: true
                Layout.preferredHeight: Math.max(
                    plasmoid.configuration.titleSize,
                    plasmoid.configuration.episodeSize
                ) + Kirigami.Units.smallSpacing * 2

                Controls.Label {
                    anchors.centerIn: parent

                    text: root.episodes.length > 0
                    ? plasmoid.configuration.title
                    : plasmoid.configuration.emptyTitle

                    color: Kirigami.Theme.textColor
                    font.bold: true
                    font.pixelSize: plasmoid.configuration.titleSize
                }

                RowLayout {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 0

                    Controls.ToolButton {
                        icon.name: "configure"

                        onClicked: manageSeriesDialog.open()

                        Controls.ToolTip.visible: hovered
                        Controls.ToolTip.text: "Manage series matches"
                    }

                    Controls.ToolButton {
                        icon.name: "edit-undo"

                        enabled: root.history.length > 0 || Object.keys(root.lastRemoved).length > 0

                        onClicked: {
                            if (plasmoid.configuration.confirmUndo) {
                                undoConfirmDialog.open()
                            } else {
                                root.undoLast()
                            }
                        }

                        Controls.ToolTip.visible: hovered
                        Controls.ToolTip.text: "Undo last action"
                    }
                }
            }

            EpisodeList {
                Layout.fillWidth: true
                Layout.fillHeight: true
            }
        }
    }

    component EpisodeList: ColumnLayout {
        spacing: plasmoid.configuration.itemSpacing

        ListView {
            visible: root.episodes.length > 0

            model: root.groupedEpisodes()

            clip: true

            Layout.fillWidth: true
            Layout.fillHeight: true

            spacing: plasmoid.configuration.itemSpacing

            delegate: ColumnLayout {
                width: ListView.view.width
                spacing: plasmoid.configuration.itemSpacing

                property var group: modelData

                Controls.Label {
                    text: group.series

                    font.bold: true
                    font.pixelSize: plasmoid.configuration.episodeSize
                    color: Kirigami.Theme.textColor

                    Layout.fillWidth: true
                }

                Repeater {
                    model: group.episodes

                    delegate: Item {
                        id: episodeRow

                        width: ListView.view ? ListView.view.width : parent.width
                        height: episodeRowLayout.implicitHeight

                        property var episode: modelData

                        RowLayout {
                            id: episodeRowLayout
                            width: parent.width
                            spacing: Kirigami.Units.smallSpacing

                            Controls.CheckBox {
                                text: root.episodeLabel(episodeRow.episode)

                                font.pixelSize:
                                plasmoid.configuration.episodeSize

                                Layout.fillWidth: true

                                onClicked: {
                                    root.markDone(episodeRow.episode)
                                }
                            }

                            Controls.ToolButton {
                                icon.name: "media-playback-start"

                                onClicked: {
                                    executable.run(
                                        "xdg-open "
                                        + JSON.stringify(episodeRow.episode.path)
                                    )
                                }
                            }
                        }

                        MouseArea {
                            anchors.fill: parent
                            acceptedButtons: Qt.RightButton
                            onClicked: episodeContextMenu.popup()
                        }

                        Controls.Menu {
                            id: episodeContextMenu

                            Controls.MenuItem {
                                text: i18n("Remove \"%1\"", root.episodeLabel(episodeRow.episode))
                                onTriggered: root.removeEpisode(episodeRow.episode)
                            }
                        }
                    }
                }
            }
        }
    }
}
