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

    title: i18n("Anime-Widget")
    width: Kirigami.Units.gridUnit * 26
    height: Kirigami.Units.gridUnit * 32

    property string prefsScriptPath: "$HOME/.local/bin/anime-gui-prefs.sh"
    property bool prefsLoaded: false

    // Settings -- flat properties on window so AnimeContent below can
    // bind to them directly, and the settings dialog just edits
    // these same properties in place rather than needing a separate
    // apply/copy step.
    property string appTitle: "New Episodes"
    property string emptyTitle: "No new episodes"
    property int titleSize: 16
    property int episodeSize: 14
    property int itemSpacing: 6
    property int refreshInterval: 3
    property bool confirmUndo: true
    property bool askToGrade: true
    property bool preferEnglishTitle: false

    function savePrefs() {
        var prefs = {
            title: window.appTitle,
            emptyTitle: window.emptyTitle,
            titleSize: window.titleSize,
            episodeSize: window.episodeSize,
            itemSpacing: window.itemSpacing,
            refreshInterval: window.refreshInterval,
            confirmUndo: window.confirmUndo,
            askToGrade: window.askToGrade,
            preferEnglishTitle: window.preferEnglishTitle,
        }

        prefsExecutable.run(
            prefsScriptPath + " standalone-prefs.json set " +
            JSON.stringify(JSON.stringify(prefs))
        )
    }

    Plasma5Support.DataSource {
        id: prefsExecutable
        engine: "executable"
        connectedSources: []

        onNewData: function(source, data) {
            disconnectSource(source)

            if (source.indexOf("get-config") !== -1) {
                animeRootField.text = (data["stdout"] || "").trim()
                return
            }

            if (source.indexOf("set-config") !== -1) {
                animeRootStatus.text = (data["stdout"] || "").trim()
                return
            }

            if (source.indexOf("standalone-prefs.json get") !== -1) {
                window.prefsLoaded = true

                var exitCode = data["exit code"]
                var stdout = data["stdout"] || ""

                if (exitCode === 0) {
                    try {
                        var prefs = JSON.parse(stdout)

                        if (prefs.title !== undefined) window.appTitle = prefs.title
                            if (prefs.emptyTitle !== undefined) window.emptyTitle = prefs.emptyTitle
                                if (prefs.titleSize !== undefined) window.titleSize = prefs.titleSize
                                    if (prefs.episodeSize !== undefined) window.episodeSize = prefs.episodeSize
                                        if (prefs.itemSpacing !== undefined) window.itemSpacing = prefs.itemSpacing
                                            if (prefs.backgroundOpacity !== undefined) window.backgroundOpacity = prefs.backgroundOpacity
                                                if (prefs.refreshInterval !== undefined) window.refreshInterval = prefs.refreshInterval
                                                    if (prefs.confirmUndo !== undefined) window.confirmUndo = prefs.confirmUndo
                                                        if (prefs.askToGrade !== undefined) window.askToGrade = prefs.askToGrade
                                                            if (prefs.preferEnglishTitle !== undefined) window.preferEnglishTitle = prefs.preferEnglishTitle
                    } catch (e) {
                        // No saved prefs yet, or corrupted -- defaults already set above.
                    }
                }
            }
        }

        function run(command) {
            connectSource(command)
        }
    }

    property string scriptPath: "$HOME/.local/bin/anime-downloaded.sh"

    function setAnimeRoot(path) {
        prefsExecutable.run(
            scriptPath + " set-config " + JSON.stringify(path)
        )
    }

    Component.onCompleted: {
        prefsExecutable.run(prefsScriptPath + " standalone-prefs.json get")
        prefsExecutable.run(scriptPath + " get-config")
    }

    AnimeBackend {
        id: animeBackend
        refreshInterval: window.refreshInterval
        preferEnglishTitle: window.preferEnglishTitle
    }

    Controls.Dialog {
        id: settingsDialog

        modal: true
        parent: Controls.Overlay.overlay
        x: Math.round((parent.width - width) / 2)
        y: Math.round((parent.height - height) / 2)
        width: Math.min(parent.width - Kirigami.Units.gridUnit * 2, Kirigami.Units.gridUnit * 26)
        title: i18n("Settings")

        property string tab: "general"

        contentItem: ColumnLayout {
            spacing: Kirigami.Units.largeSpacing

            RowLayout {
                Layout.fillWidth: true
                spacing: 0

                Controls.Button {
                    Layout.fillWidth: true
                    text: i18n("General")
                    checkable: true
                    checked: settingsDialog.tab === "general"
                    onClicked: settingsDialog.tab = "general"
                }

                Controls.Button {
                    Layout.fillWidth: true
                    text: i18n("Appearance")
                    checkable: true
                    checked: settingsDialog.tab === "appearance"
                    onClicked: settingsDialog.tab = "appearance"
                }

                Controls.Button {
                    Layout.fillWidth: true
                    text: i18n("Behavior")
                    checkable: true
                    checked: settingsDialog.tab === "behavior"
                    onClicked: settingsDialog.tab = "behavior"
                }
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing
                visible: settingsDialog.tab === "general"

                Controls.Label { text: i18n("Title:") }
                Controls.TextField {
                    Layout.fillWidth: true
                    text: window.appTitle
                    onEditingFinished: {
                        window.appTitle = text
                        window.savePrefs()
                    }
                }

                Controls.Label { text: i18n("Title when empty:") }
                Controls.TextField {
                    Layout.fillWidth: true
                    text: window.emptyTitle
                    onEditingFinished: {
                        window.emptyTitle = text
                        window.savePrefs()
                    }
                }
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing
                visible: settingsDialog.tab === "appearance"

                Controls.Label { text: i18n("Title font size:") }
                Controls.SpinBox {
                    from: 8
                    to: 32
                    value: window.titleSize
                    onValueModified: {
                        window.titleSize = value
                        window.savePrefs()
                    }
                }

                Controls.Label { text: i18n("List font size:") }
                Controls.SpinBox {
                    from: 8
                    to: 28
                    value: window.episodeSize
                    onValueModified: {
                        window.episodeSize = value
                        window.savePrefs()
                    }
                }

                Controls.Label { text: i18n("Episode spacing:") }
                Controls.SpinBox {
                    from: 0
                    to: 30
                    value: window.itemSpacing
                    onValueModified: {
                        window.itemSpacing = value
                        window.savePrefs()
                    }
                }
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing
                visible: settingsDialog.tab === "behavior"

                Controls.Label { text: i18n("Fallback refresh interval (seconds):") }
                Controls.SpinBox {
                    from: 1
                    to: 60
                    value: window.refreshInterval
                    onValueModified: {
                        window.refreshInterval = value
                        window.savePrefs()
                    }
                }

                Controls.CheckBox {
                    text: i18n("Ask for confirmation before undoing")
                    checked: window.confirmUndo
                    onToggled: {
                        window.confirmUndo = checked
                        window.savePrefs()
                    }
                }

                Controls.CheckBox {
                    text: i18n("Ask me to rate a show when I finish it")
                    checked: window.askToGrade
                    onToggled: {
                        window.askToGrade = checked
                        window.savePrefs()
                    }
                }

                Controls.CheckBox {
                    text: i18n("Prefer English titles over Japanese/romaji")
                    checked: window.preferEnglishTitle
                    onToggled: {
                        window.preferEnglishTitle = checked
                        window.savePrefs()
                    }
                }

                Kirigami.Separator {
                    Layout.fillWidth: true
                }

                Controls.Label {
                    text: i18n("Anime root folder:")
                    font.bold: true
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Kirigami.Units.smallSpacing

                    Controls.TextField {
                        id: animeRootField
                        Layout.fillWidth: true
                        placeholderText: i18n("e.g. /home/you/Anime")
                    }

                    Controls.Button {
                        text: i18n("Save")
                        onClicked: window.setAnimeRoot(animeRootField.text)
                    }
                }

                Controls.Label {
                    Layout.fillWidth: true
                    wrapMode: Text.WordWrap
                    opacity: 0.7
                    text: i18n("Downloads outside this folder (and its subfolders) are ignored -- helps avoid false matches from other TV shows sharing the same qBittorrent hook. Leave empty to track everything.")
                }

                Controls.Label {
                    id: animeRootStatus
                    Layout.fillWidth: true
                    wrapMode: Text.WordWrap
                    opacity: 0.7
                }
            }
        }

        footer: Controls.DialogButtonBox {
            Controls.Button {
                text: i18n("Close")
                Controls.DialogButtonBox.buttonRole: Controls.DialogButtonBox.AcceptRole
                onClicked: settingsDialog.close()
            }
        }
    }

    pageStack.initialPage: Kirigami.Page {
        padding: 0

        AnimeAppView {
            anchors.fill: parent
            backend: animeBackend
            askToGrade: window.askToGrade
            confirmUndo: window.confirmUndo
            itemSpacing: window.itemSpacing
            titleSize: window.titleSize
            episodeSize: window.episodeSize
            title: window.appTitle
            emptyTitle: window.emptyTitle

            onSettingsRequested: settingsDialog.open()
        }
    }
}
