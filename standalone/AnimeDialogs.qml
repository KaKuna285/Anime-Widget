import QtQuick
import QtQuick.Controls as Controls
import QtQuick.Layouts
import org.kde.kirigami as Kirigami

// Non-visual trigger logic plus every popup dialog (match picker,
// manage series, grading, batch warnings, undo confirmation,
// errors). Shared between hosts (the widget's AnimeContent, and the
// standalone app's AnimeAppView) so dialog behavior only needs to
// be written -- and tested -- once.
Item {
    id: dialogs

    property var backend
    property bool askToGrade: true
    property bool confirmUndo: true

    property string activeSeriesKey: ""
    property string activeGradeSeriesKey: ""
    property bool awaitingManualSearch: false

    function requestUndo() {
        if (dialogs.confirmUndo) {
            undoConfirmDialog.open()
        } else {
            dialogs.backend.undoLast()
        }
    }

    function openManageSeries() {
        manageSeriesDialog.open()
    }

    function nextPendingSeries() {
        for (var key in dialogs.backend.pendingMatches) {
            if (dialogs.backend.pendingMatches[key].status === "ready") {
                return key
            }
        }
        return ""
    }

    function maybeShowNextPending() {
        if (seriesMatchDialog.visible) {
            // If the entry we're showing got resolved elsewhere --
            // confirmed or skipped in another running instance, e.g.
            // the widget vs. the standalone app -- it will have
            // disappeared from pendingMatches entirely. Close our
            // now-stale dialog instead of leaving it stuck open.
            if (dialogs.activeSeriesKey !== "" && !(dialogs.activeSeriesKey in dialogs.backend.pendingMatches)) {
                seriesMatchDialog.close()
                dialogs.activeSeriesKey = ""
                dialogs.awaitingManualSearch = false
                return
            }

            if (!dialogs.awaitingManualSearch) {
                return
            }

            var openEntry = dialogs.backend.pendingMatches[activeSeriesKey]

            if (!openEntry || openEntry.status === "searching") {
                return
            }

            dialogs.awaitingManualSearch = false
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
        seriesMatchDialog.displayLabel = dialogs.backend.pendingMatches[key].query || key
        seriesMatchDialog.candidates = dialogs.backend.pendingMatches[key].candidates || []
        seriesMatchDialog.open()
    }

    function confirmActiveSeries(malId, title) {
        dialogs.backend.confirmSeries(activeSeriesKey, malId, title)
        activeSeriesKey = ""
    }

    function skipActiveSeries() {
        dialogs.backend.skipSeries(activeSeriesKey)
        activeSeriesKey = ""
    }

    function nextPendingGrade() {
        for (var key in dialogs.backend.pendingGrades) {
            return key
        }
        return ""
    }

    function maybeShowNextGrade() {
        if (gradeDialog.visible) {
            if (dialogs.activeGradeSeriesKey !== "" && !(dialogs.activeGradeSeriesKey in dialogs.backend.pendingGrades)) {
                gradeDialog.close()
                dialogs.activeGradeSeriesKey = ""
            }

            return
        }

        var key = nextPendingGrade()

        if (key === "") {
            return
        }

        if (!dialogs.askToGrade) {
            activeGradeSeriesKey = key
            skipGrade()
            return
        }

        activeGradeSeriesKey = key
        gradeDialog.seriesKey = key
        gradeDialog.seriesTitle = dialogs.backend.pendingGrades[key].title || key
        gradeDialog.open()
    }

    function submitGrade(score) {
        dialogs.backend.gradeSeries(activeGradeSeriesKey, score)
        activeGradeSeriesKey = ""
    }

    function skipGrade() {
        dialogs.backend.skipGradeSeries(activeGradeSeriesKey)
        activeGradeSeriesKey = ""
    }

    function nextBatchWarning() {
        for (var key in dialogs.backend.batchWarnings) {
            return key
        }
        return ""
    }

    function maybeShowNextBatchWarning() {
        if (batchWarningDialog.visible) {
            if (batchWarningDialog.warningKey !== "" && !(batchWarningDialog.warningKey in dialogs.backend.batchWarnings)) {
                batchWarningDialog.close()
            }

            return
        }

        var key = nextBatchWarning()

        if (key === "") {
            return
        }

        batchWarningDialog.warningKey = key
        batchWarningDialog.message = dialogs.backend.batchWarnings[key].message || ""
        batchWarningDialog.open()
    }

    function dismissBatchWarning(key) {
        dialogs.backend.dismissBatchWarning(key)
    }

    Connections {
        target: dialogs.backend
        function onPendingMatchesChanged() {
            dialogs.maybeShowNextPending()
        }
    }

    Connections {
        target: dialogs.backend
        function onPendingGradesChanged() {
            dialogs.maybeShowNextGrade()
        }
    }

    Connections {
        target: dialogs.backend
        function onBatchWarningsChanged() {
            dialogs.maybeShowNextBatchWarning()
        }
    }

    Connections {
        target: dialogs.backend
        function onErrorMessageChanged() {
            if (dialogs.backend.errorMessage !== "") {
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

        readonly property bool isSearching: dialogs.backend.pendingMatches[dialogs.activeSeriesKey]
        ? dialogs.backend.pendingMatches[dialogs.activeSeriesKey].status === "searching"
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
                        dialogs.awaitingManualSearch = true
                        dialogs.backend.remapSeries(dialogs.activeSeriesKey, manualQueryField.text)
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
                    dialogs.skipActiveSeries()
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
                        dialogs.confirmActiveSeries(chosen.id, chosen.title)
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

        onOpened: dialogs.backend.refresh()

        contentItem: Controls.ScrollView {
            clip: true

            ColumnLayout {
                width: manageSeriesDialog.availableWidth
                spacing: Kirigami.Units.smallSpacing

                Repeater {
                    model: dialogs.backend.activeSeriesMapList()

                    delegate: Kirigami.AbstractCard {
                        Layout.fillWidth: true

                        contentItem: ColumnLayout {
                            spacing: Kirigami.Units.smallSpacing

                            Controls.Label {
                                Layout.fillWidth: true
                                wrapMode: Text.WordWrap
                                font.bold: true
                                text: dialogs.backend.seriesKeyLabel(modelData.key)
                            }

                            Controls.Label {
                                Layout.fillWidth: true
                                opacity: 0.7
                                wrapMode: Text.WordWrap
                                text: modelData.entry.skipped
                                ? i18n("Skipped -- not tracked on MAL")
                                : modelData.entry.malId
                                ? i18n("Mapped to \"%1\" (MAL %2)", dialogs.backend.preferredTitle(modelData.entry) || "?", modelData.entry.malId)
                                : i18n("Not mapped yet")
                            }

                            RowLayout {
                                Layout.fillWidth: true
                                spacing: Kirigami.Units.smallSpacing

                                Controls.TextField {
                                    id: queryField
                                    Layout.fillWidth: true
                                    placeholderText: i18n("Search MAL as...")
                                    text: dialogs.backend.seriesKeyLabel(modelData.key)
                                }

                                Controls.Button {
                                    text: i18n("Search")
                                    onClicked: dialogs.backend.remapSeries(modelData.key, queryField.text)
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
                                        dialogs.backend.confirmSeries(modelData.key, idField.text, "")
                                        idField.text = ""
                                    }
                                }
                            }
                        }
                    }
                }

                Controls.Button {
                    Layout.fillWidth: true
                    visible: dialogs.backend.inactiveSeriesMapList().length > 0
                    text: manageSeriesDialog.showFinished
                    ? i18n("Hide finished series")
                    : i18n("Show %1 finished series", dialogs.backend.inactiveSeriesMapList().length)
                    onClicked: manageSeriesDialog.showFinished = !manageSeriesDialog.showFinished
                }

                Repeater {
                    model: manageSeriesDialog.showFinished ? dialogs.backend.inactiveSeriesMapList() : []

                    delegate: Kirigami.AbstractCard {
                        Layout.fillWidth: true

                        contentItem: ColumnLayout {
                            spacing: Kirigami.Units.smallSpacing

                            Controls.Label {
                                Layout.fillWidth: true
                                wrapMode: Text.WordWrap
                                font.bold: true
                                text: dialogs.backend.seriesKeyLabel(modelData.key)
                            }

                            Controls.Label {
                                Layout.fillWidth: true
                                opacity: 0.7
                                wrapMode: Text.WordWrap
                                text: modelData.entry.skipped
                                ? i18n("Skipped -- not tracked on MAL")
                                : modelData.entry.malId
                                ? i18n("Mapped to \"%1\" (MAL %2)", dialogs.backend.preferredTitle(modelData.entry) || "?", modelData.entry.malId)
                                : i18n("Not mapped yet")
                            }

                            RowLayout {
                                Layout.fillWidth: true
                                spacing: Kirigami.Units.smallSpacing

                                Controls.TextField {
                                    id: queryFieldFinished
                                    Layout.fillWidth: true
                                    placeholderText: i18n("Search MAL as...")
                                    text: dialogs.backend.seriesKeyLabel(modelData.key)
                                }

                                Controls.Button {
                                    text: i18n("Search")
                                    onClicked: dialogs.backend.remapSeries(modelData.key, queryFieldFinished.text)
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
                                        dialogs.backend.confirmSeries(modelData.key, idFieldFinished.text, "")
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
                    dialogs.skipGrade()
                    gradeDialog.close()
                }
            }

            Controls.Button {
                text: i18n("Submit")
                Controls.DialogButtonBox.buttonRole: Controls.DialogButtonBox.AcceptRole
                onClicked: {
                    dialogs.submitGrade(scoreSpinBox.value)
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
                    dialogs.dismissBatchWarning(batchWarningDialog.warningKey)
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
                    dialogs.backend.undoLast()
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
                text: i18n("Command \"%1\" failed:", dialogs.backend.errorSource)
            }

            Controls.ScrollView {
                Layout.fillWidth: true
                Layout.preferredHeight: Kirigami.Units.gridUnit * 8

                Controls.TextArea {
                    readOnly: true
                    wrapMode: Text.WordWrap
                    text: dialogs.backend.errorMessage
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
}
