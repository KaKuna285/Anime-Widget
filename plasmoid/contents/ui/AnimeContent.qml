import QtQuick
import QtQuick.Controls as Controls
import QtQuick.Layouts
import org.kde.kirigami as Kirigami

// The visual popup content: header, episode list, and every dialog.
// Talks only to the "backend" property (an AnimeBackend instance)
// passed in by whoever hosts this -- never touches Plasma5Support
// or plasmoid.configuration directly, so it works identically
// whether it's placed inside a Plasma widget's fullRepresentation or
// a standalone application window.
Item {
    id: content

    property var backend

    property bool askToGrade: true
    property bool confirmUndo: true
    property real backgroundOpacity: 100
    property int itemSpacing: 6
    property int titleSize: 16
    property int episodeSize: 14
    property string title: "New Episodes"
    property string emptyTitle: "No new episodes"

    property string activeSeriesKey: ""
    property string activeGradeSeriesKey: ""
    property bool awaitingManualSearch: false

    function nextPendingSeries() {
        for (var key in content.backend.pendingMatches) {
            if (content.backend.pendingMatches[key].status === "ready") {
                return key
            }
        }
        return ""
    }

    function maybeShowNextPending() {
        if (seriesMatchDialog.visible) {
            // Only refresh in place if we're specifically waiting on
            // a manual re-search we just triggered -- not on every
            // unrelated periodic poll, which would otherwise keep
            // resetting the user's selection.
            if (!content.awaitingManualSearch) {
                return
            }

            var openEntry = content.backend.pendingMatches[activeSeriesKey]

            if (!openEntry || openEntry.status === "searching") {
                return
            }

            content.awaitingManualSearch = false
            seriesMatchDialog.candidates = openEntry.candidates || []
            seriesMatchDialog.selectedId = -1
            return
        }

        var key = nextPendingSeries()

        if (key === "") {
            return
        }

        activeSeriesKey = key
        seriesMatchDialog.seriesKey = key
        seriesMatchDialog.displayLabel = content.backend.pendingMatches[key].query || key
        seriesMatchDialog.candidates = content.backend.pendingMatches[key].candidates || []
        seriesMatchDialog.open()
    }

    function confirmActiveSeries(malId, title) {
        content.backend.confirmSeries(activeSeriesKey, malId, title)
        activeSeriesKey = ""
    }

    function skipActiveSeries() {
        content.backend.skipSeries(activeSeriesKey)
        activeSeriesKey = ""
    }

    function nextPendingGrade() {
        for (var key in content.backend.pendingGrades) {
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

        if (!content.askToGrade) {
            activeGradeSeriesKey = key
            skipGrade()
            return
        }

        activeGradeSeriesKey = key
        gradeDialog.seriesKey = key
        gradeDialog.seriesTitle = content.backend.pendingGrades[key].title || key
        gradeDialog.open()
    }

    function submitGrade(score) {
        content.backend.gradeSeries(activeGradeSeriesKey, score)
        activeGradeSeriesKey = ""
    }

    function skipGrade() {
        content.backend.skipGradeSeries(activeGradeSeriesKey)
        activeGradeSeriesKey = ""
    }

    function nextBatchWarning() {
        for (var key in content.backend.batchWarnings) {
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
        batchWarningDialog.message = content.backend.batchWarnings[key].message || ""
        batchWarningDialog.open()
    }

    function dismissBatchWarning(key) {
        content.backend.dismissBatchWarning(key)
    }

    function undoConfirmed() {
        content.backend.undoLast()
    }

    Connections {
        target: content.backend
        function onPendingMatchesChanged() {
            content.maybeShowNextPending()
        }
    }

    Connections {
        target: content.backend
        function onPendingGradesChanged() {
            content.maybeShowNextGrade()
        }
    }

    Connections {
        target: content.backend
        function onBatchWarningsChanged() {
            content.maybeShowNextBatchWarning()
        }
    }

    Connections {
        target: content.backend
        function onErrorMessageChanged() {
            if (content.backend.errorMessage !== "") {
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
        property string displayLabel: ""
        property var candidates: []
        property int selectedId: -1

        readonly property bool isSearching: content.backend.pendingMatches[content.activeSeriesKey]
            ? content.backend.pendingMatches[content.activeSeriesKey].status === "searching"
            : false

        onOpened: selectedId = -1

        contentItem: ColumnLayout {
            spacing: Kirigami.Units.smallSpacing

            Controls.Label {
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                text: i18n("Which anime is \"%1\"?", seriesMatchDialog.displayLabel)
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing

                Controls.TextField {
                    id: manualQueryField
                    Layout.fillWidth: true
                    placeholderText: i18n("Or search manually...")
                    text: seriesMatchDialog.displayLabel
                    enabled: !seriesMatchDialog.isSearching

                    Keys.onReturnPressed: manualSearchButton.clicked()
                }

                Controls.Button {
                    id: manualSearchButton
                    text: seriesMatchDialog.isSearching ? i18n("Searching...") : i18n("Search")
                    enabled: !seriesMatchDialog.isSearching && manualQueryField.text.length > 0

                    onClicked: {
                        content.awaitingManualSearch = true
                        content.backend.remapSeries(content.activeSeriesKey, manualQueryField.text)
                    }
                }
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
                    content.skipActiveSeries()
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
                        content.confirmActiveSeries(chosen.id, chosen.title)
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

        onOpened: content.backend.refresh()

        contentItem: Controls.ScrollView {
            clip: true

            ColumnLayout {
                width: manageSeriesDialog.availableWidth
                spacing: Kirigami.Units.smallSpacing

                Repeater {
                    model: content.backend.activeSeriesMapList()

                    delegate: Kirigami.AbstractCard {
                        Layout.fillWidth: true

                        contentItem: ColumnLayout {
                            spacing: Kirigami.Units.smallSpacing

                            Controls.Label {
                                Layout.fillWidth: true
                                wrapMode: Text.WordWrap
                                font.bold: true
                                text: content.backend.seriesKeyLabel(modelData.key)
                            }

                            Controls.Label {
                                Layout.fillWidth: true
                                opacity: 0.7
                                wrapMode: Text.WordWrap
                                text: modelData.entry.skipped
                                      ? i18n("Skipped -- not tracked on MAL")
                                      : modelData.entry.malId
                                        ? i18n("Mapped to \"%1\" (MAL %2)", content.backend.preferredTitle(modelData.entry) || "?", modelData.entry.malId)
                                        : i18n("Not mapped yet")
                            }

                            RowLayout {
                                Layout.fillWidth: true
                                spacing: Kirigami.Units.smallSpacing

                                Controls.TextField {
                                    id: queryField
                                    Layout.fillWidth: true
                                    placeholderText: i18n("Search MAL as...")
                                    text: content.backend.seriesKeyLabel(modelData.key)
                                }

                                Controls.Button {
                                    text: i18n("Search")
                                    onClicked: content.backend.remapSeries(modelData.key, queryField.text)
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
                                        content.backend.confirmSeries(modelData.key, idField.text, "")
                                        idField.text = ""
                                    }
                                }
                            }
                        }
                    }
                }

                Controls.Button {
                    Layout.fillWidth: true
                    visible: content.backend.inactiveSeriesMapList().length > 0
                    text: manageSeriesDialog.showFinished
                          ? i18n("Hide finished series")
                          : i18n("Show %1 finished series", content.backend.inactiveSeriesMapList().length)
                    onClicked: manageSeriesDialog.showFinished = !manageSeriesDialog.showFinished
                }

                Repeater {
                    model: manageSeriesDialog.showFinished ? content.backend.inactiveSeriesMapList() : []

                    delegate: Kirigami.AbstractCard {
                        Layout.fillWidth: true

                        contentItem: ColumnLayout {
                            spacing: Kirigami.Units.smallSpacing

                            Controls.Label {
                                Layout.fillWidth: true
                                wrapMode: Text.WordWrap
                                font.bold: true
                                text: content.backend.seriesKeyLabel(modelData.key)
                            }

                            Controls.Label {
                                Layout.fillWidth: true
                                opacity: 0.7
                                wrapMode: Text.WordWrap
                                text: modelData.entry.skipped
                                      ? i18n("Skipped -- not tracked on MAL")
                                      : modelData.entry.malId
                                        ? i18n("Mapped to \"%1\" (MAL %2)", content.backend.preferredTitle(modelData.entry) || "?", modelData.entry.malId)
                                        : i18n("Not mapped yet")
                            }

                            RowLayout {
                                Layout.fillWidth: true
                                spacing: Kirigami.Units.smallSpacing

                                Controls.TextField {
                                    id: queryFieldFinished
                                    Layout.fillWidth: true
                                    placeholderText: i18n("Search MAL as...")
                                    text: content.backend.seriesKeyLabel(modelData.key)
                                }

                                Controls.Button {
                                    text: i18n("Search")
                                    onClicked: content.backend.remapSeries(modelData.key, queryFieldFinished.text)
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
                                        content.backend.confirmSeries(modelData.key, idFieldFinished.text, "")
                                        idFieldFinished.text = ""
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
                    content.skipGrade()
                    gradeDialog.close()
                }
            }

            Controls.Button {
                text: i18n("Submit")
                Controls.DialogButtonBox.buttonRole: Controls.DialogButtonBox.AcceptRole
                onClicked: {
                    content.submitGrade(scoreSpinBox.value)
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
                    content.dismissBatchWarning(batchWarningDialog.warningKey)
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
                    content.undoConfirmed()
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
                text: i18n("Command \"%1\" failed:", content.backend.errorSource)
            }

            Controls.ScrollView {
                Layout.fillWidth: true
                Layout.preferredHeight: Kirigami.Units.gridUnit * 8

                Controls.TextArea {
                    readOnly: true
                    wrapMode: Text.WordWrap
                    text: content.backend.errorMessage
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
        opacity: content.backgroundOpacity / 100.0
        radius: Kirigami.Units.smallSpacing
    }

    Layout.minimumWidth: Kirigami.Units.gridUnit * 10
    Layout.minimumHeight: Kirigami.Units.gridUnit * 8
    Layout.preferredWidth: Kirigami.Units.gridUnit * 22
    Layout.preferredHeight: Kirigami.Units.gridUnit * 14

    ColumnLayout {
        id: verticalLayout

        anchors.fill: parent
        spacing: content.itemSpacing

        Item {
            Layout.fillWidth: true
            Layout.preferredHeight: Math.max(
                content.titleSize,
                content.episodeSize
            ) + Kirigami.Units.smallSpacing * 2

            Controls.Label {
                anchors.centerIn: parent

                text: content.backend.episodes.length > 0
                      ? content.title
                      : content.emptyTitle

                color: Kirigami.Theme.textColor
                font.bold: true
                font.pixelSize: content.titleSize
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
                    enabled: content.backend.history.length > 0 || Object.keys(content.backend.lastRemoved).length > 0

                    onClicked: {
                        if (content.confirmUndo) {
                            undoConfirmDialog.open()
                        } else {
                            content.backend.undoLast()
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

    component EpisodeList: ColumnLayout {
        spacing: content.itemSpacing

        ListView {
            visible: content.backend.episodes.length > 0

            model: content.backend.groupedEpisodes()

            clip: true

            Layout.fillWidth: true
            Layout.fillHeight: true

            spacing: content.itemSpacing

            delegate: ColumnLayout {
                width: ListView.view.width
                spacing: content.itemSpacing

                property var group: modelData

                Controls.Label {
                    text: group.label
                    font.bold: true
                    font.pixelSize: content.episodeSize
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
                                text: content.backend.episodeLabel(episodeRow.episode)
                                font.pixelSize: content.episodeSize
                                Layout.fillWidth: true

                                onClicked: content.backend.markDone(episodeRow.episode)
                            }

                            Controls.ToolButton {
                                icon.name: "media-playback-start"
                                onClicked: content.backend.openFile(episodeRow.episode.path)
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
                                text: i18n("Show in folder")
                                onTriggered: content.backend.openContainingFolder(episodeRow.episode)
                            }

                            Controls.MenuItem {
                                text: i18n("Remove \"%1\"", content.backend.episodeLabel(episodeRow.episode))
                                onTriggered: content.backend.removeEpisode(episodeRow.episode)
                            }
                        }
                    }
                }
            }
        }
    }
}
