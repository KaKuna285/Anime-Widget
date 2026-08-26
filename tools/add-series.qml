import QtQuick
import QtQuick.Controls as Controls
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.plasma.plasma5support as Plasma5Support

Kirigami.ApplicationWindow {
    id: window

    function i18n(str) {
        var result = str

        for (var i = 1; i < arguments.length; i++) {
            result = result.replace("%" + i, arguments[i])
        }

        return result
    }

    title: i18n("Add Anime Series")
    width: Kirigami.Units.gridUnit * 32
    height: Kirigami.Units.gridUnit * 28

    property string scriptPath: "$HOME/.local/bin/anime-downloaded.sh"
    property string rssHelperPath: "$HOME/.local/bin/anime-rss-helper.py"

    property var candidates: []
    property int selectedId: -1
    property string selectedTitle: ""
    property var feeds: []
    property bool searching: false
    property bool creating: false
    property bool checking: false
    property string statusMessage: ""

    property bool matchChecked: false
    property bool matchFound: false
    property int matchCount: 0
    property string matchExampleTitle: ""

    function baseName(path) {
        var trimmed = path.replace(/\/+$/, "")
        var lastSlash = trimmed.lastIndexOf("/")
        return lastSlash >= 0 ? trimmed.substring(lastSlash + 1) : trimmed
    }

    function invalidateMatchCheck() {
        window.matchChecked = false
        window.matchFound = false
        window.matchCount = 0
        window.matchExampleTitle = ""
    }

    function proceedWithCreate() {
        window.creating = true
        window.statusMessage = ""

        var seriesKey = window.baseName(savePathField.text)

        executable.run(
            window.scriptPath + " confirm-series " +
            JSON.stringify(seriesKey) + " " +
            window.selectedId + " " +
            JSON.stringify(window.selectedTitle)
        )
    }

    Plasma5Support.DataSource {
        id: executable
        engine: "executable"
        connectedSources: []

        onNewData: function(source, data) {
            disconnectSource(source)

            var exitCode = data["exit code"]
            var stdout = data["stdout"] || ""
            var stderr = data["stderr"] || ""

            if (source.indexOf("search-only") !== -1) {
                window.searching = false

                if (exitCode !== 0) {
                    window.statusMessage = i18n("Search failed: %1", stderr || stdout)
                    window.candidates = []
                    return
                }

                try {
                    window.candidates = JSON.parse(stdout)
                    window.statusMessage = window.candidates.length > 0
                    ? i18n("Found %1 result(s).", window.candidates.length)
                    : i18n("No results found -- try a different search term.")
                } catch (e) {
                    window.statusMessage = i18n("Failed to parse search results.")
                    window.candidates = []
                }

                return
            }

            if (source.indexOf("list-feeds") !== -1) {
                if (exitCode !== 0) {
                    window.statusMessage = i18n("Could not load RSS feeds: %1", stderr || stdout)
                    return
                }

                try {
                    window.feeds = JSON.parse(stdout)
                } catch (e) {
                    window.statusMessage = i18n("Failed to parse feed list.")
                }

                return
            }

            if (source.indexOf("check-matches") !== -1) {
                window.checking = false

                if (exitCode !== 0) {
                    window.statusMessage = i18n("Could not check for matches: %1", stderr || stdout)
                    window.invalidateMatchCheck()
                    return
                }

                try {
                    var result = JSON.parse(stdout)

                    window.matchChecked = true
                    window.matchFound = result.totalMatches > 0
                    window.matchCount = result.totalMatches
                    window.matchExampleTitle = result.titles[0] || ""

                    window.statusMessage = window.matchFound
                    ? i18n(
                        "Found %1 matching article(s), e.g. \"%2\"",
                           window.matchCount,
                           window.matchExampleTitle
                    )
                    : i18n(
                        "No current match for this feed -- this can be normal if the series hasn't aired yet."
                    )
                } catch (e) {
                    window.invalidateMatchCheck()
                    window.statusMessage = i18n("Failed to parse match results.")
                }

                return
            }

            if (source.indexOf("confirm-series") !== -1) {
                if (exitCode !== 0) {
                    window.creating = false
                    window.statusMessage = i18n("Failed to save MAL mapping: %1", stderr || stdout)
                    return
                }

                executable.run(
                    rssHelperPath + " create-rule " +
                    JSON.stringify(seriesNameField.text) + " " +
                    JSON.stringify(feedCombo.currentValue) + " " +
                    JSON.stringify(savePathField.text)
                )

                return
            }

            if (source.indexOf("create-rule") !== -1) {
                window.creating = false

                if (exitCode !== 0) {
                    window.statusMessage = i18n("Failed to create RSS rule: %1", stderr || stdout)
                    return
                }

                window.statusMessage = i18n("Done! Series mapped and RSS rule created.")
            }
        }

        function run(command) {
            connectSource(command)
        }
    }

    Component.onCompleted: {
        executable.run(rssHelperPath + " list-feeds")
    }

    Controls.Dialog {
        id: noMatchConfirmDialog

        modal: true
        parent: Controls.Overlay.overlay
        x: Math.round((parent.width - width) / 2)
        y: Math.round((parent.height - height) / 2)
        width: Math.min(parent.width - Kirigami.Units.gridUnit * 2, Kirigami.Units.gridUnit * 22)
        title: i18n("No matching article found")

        contentItem: Controls.Label {
            wrapMode: Text.WordWrap
            text: i18n(
                "No article in \"%1\" currently matches \"%2\". This can be normal if the series hasn't aired yet. Create the rule anyway?",
                feedCombo.currentName,
                window.selectedTitle
            )
        }

        footer: Controls.DialogButtonBox {
            Controls.Button {
                text: i18n("Cancel")
                Controls.DialogButtonBox.buttonRole: Controls.DialogButtonBox.RejectRole
                onClicked: noMatchConfirmDialog.close()
            }

            Controls.Button {
                text: i18n("Create Anyway")
                Controls.DialogButtonBox.buttonRole: Controls.DialogButtonBox.AcceptRole
                onClicked: {
                    noMatchConfirmDialog.close()
                    window.proceedWithCreate()
                }
            }
        }
    }

    pageStack.initialPage: Kirigami.ScrollablePage {
        title: i18n("Add a new series")

        ColumnLayout {
            width: parent.width
            spacing: Kirigami.Units.largeSpacing

            RowLayout {
                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing

                Controls.TextField {
                    id: seriesNameField
                    Layout.fillWidth: true
                    placeholderText: i18n("Series name...")

                    onTextChanged: {
                        savePathField.text = "$HOME/Downloads/anime/" + seriesNameField.text
                        window.invalidateMatchCheck()
                    }
                }

                Controls.Button {
                    text: window.searching ? i18n("Searching...") : i18n("Search MAL")
                    enabled: !window.searching && seriesNameField.text.length > 0

                    onClicked: {
                        window.searching = true
                        window.statusMessage = ""
                        window.selectedId = -1
                        window.invalidateMatchCheck()

                        executable.run(
                            window.scriptPath + " search-only " +
                            JSON.stringify(seriesNameField.text)
                        )
                    }
                }
            }

            Controls.Label {
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                visible: window.statusMessage !== ""
                text: window.statusMessage
            }

            ListView {
                Layout.fillWidth: true
                Layout.preferredHeight: Kirigami.Units.gridUnit * 12
                clip: true
                model: window.candidates
                spacing: Kirigami.Units.smallSpacing

                delegate: Controls.ItemDelegate {
                    width: ListView.view.width
                    highlighted: window.selectedId === modelData.id

                    onClicked: {
                        window.selectedId = modelData.id
                        window.selectedTitle = modelData.title
                        window.invalidateMatchCheck()
                    }

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

            Kirigami.Separator {
                Layout.fillWidth: true
            }

            Controls.Label {
                text: i18n("RSS feed:")
                font.bold: true
            }

            Controls.ComboBox {
                id: feedCombo
                Layout.fillWidth: true
                model: window.feeds
                textRole: "name"
                valueRole: "url"

                property string currentName: window.feeds.length > 0 && currentIndex >= 0
                ? window.feeds[currentIndex].name
                : ""

                onCurrentIndexChanged: window.invalidateMatchCheck()
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing

                Controls.Button {
                    Layout.fillWidth: true
                    text: window.checking
                    ? i18n("Checking...")
                    : window.matchChecked
                    ? (window.matchFound ? i18n("\u2713 Match found") : i18n("\u2717 No match -- recheck"))
                    : i18n("Check for matching article")

                    enabled: !window.checking
                    && window.selectedId !== -1
                    && feedCombo.currentName !== ""

                    onClicked: {
                        window.checking = true
                        window.statusMessage = ""

                        executable.run(
                            rssHelperPath + " check-matches " +
                            JSON.stringify(window.selectedTitle) + " " +
                            JSON.stringify(feedCombo.currentName)
                        )
                    }
                }
            }

            Controls.Label {
                text: i18n("Save to:")
                font.bold: true
            }

            Controls.TextField {
                id: savePathField
                Layout.fillWidth: true
            }

            Controls.Button {
                Layout.alignment: Qt.AlignRight
                text: window.creating ? i18n("Creating...") : i18n("Create")
                enabled: !window.creating
                && window.selectedId !== -1
                && window.feeds.length > 0
                && savePathField.text.length > 0
                && window.matchChecked

                onClicked: {
                    if (window.matchFound) {
                        window.proceedWithCreate()
                    } else {
                        noMatchConfirmDialog.open()
                    }
                }
            }
        }
    }
}
