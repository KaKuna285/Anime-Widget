import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.plasma.plasma5support as Plasma5Support

Kirigami.FormLayout {
    id: page

    property alias cfg_refreshInterval: refreshSpin.value
    property alias cfg_confirmUndo: confirmUndoCheck.checked
    property alias cfg_askToGrade: askToGradeCheck.checked

    property string scriptPath: "$HOME/.local/bin/anime-downloaded.sh"

    Plasma5Support.DataSource {
        id: executable
        engine: "executable"
        connectedSources: []

        onNewData: function(source, data) {
            disconnectSource(source)

            if (source === scriptPath + " get-config") {
                animeRootField.text = (data["stdout"] || "").trim()
            }

            if (source.indexOf("set-config") !== -1) {
                animeRootStatus.text = (data["stdout"] || "").trim()
            }
        }

        function run(command) {
            connectSource(command)
        }
    }

    Component.onCompleted: {
        executable.run(scriptPath + " get-config")
    }

    QQC2.SpinBox {
        id: refreshSpin
        Kirigami.FormData.label: i18n("Fallback refresh interval:")
        from: 1
        to: 60
        stepSize: 1

        textFromValue: function(value, locale) {
            return value + " s"
        }

        valueFromText: function(text, locale) {
            return parseInt(text)
        }
    }

    QQC2.Label {
        Kirigami.FormData.label: ""
        Layout.fillWidth: true
        wrapMode: Text.WordWrap
        opacity: 0.7
        text: i18n("The widget normally updates instantly when files change. This interval is only used as a fallback if that's unavailable.")
    }

    QQC2.CheckBox {
        id: confirmUndoCheck
        text: i18n("Ask for confirmation before undoing")
    }

    QQC2.CheckBox {
        id: askToGradeCheck
        text: i18n("Ask me to rate a show when I finish it")
    }

    Kirigami.Separator {
        Kirigami.FormData.isSection: true
    }

    RowLayout {
        Kirigami.FormData.label: i18n("Anime root folder:")
        spacing: Kirigami.Units.smallSpacing

        QQC2.TextField {
            id: animeRootField
            Layout.preferredWidth: Kirigami.Units.gridUnit * 16
            placeholderText: i18n("e.g. /home/you/Anime")
        }

        QQC2.Button {
            text: i18n("Save")
            onClicked: executable.run(
                scriptPath + " set-config " + JSON.stringify(animeRootField.text)
            )
        }
    }

    QQC2.Label {
        Kirigami.FormData.label: ""
        Layout.fillWidth: true
        wrapMode: Text.WordWrap
        opacity: 0.7
        text: i18n("Downloads outside this folder (and its subfolders) are ignored -- helps avoid false matches from other TV shows sharing the same qBittorrent hook. Leave empty to track everything.")
    }

    QQC2.Label {
        id: animeRootStatus
        Kirigami.FormData.label: ""
        Layout.fillWidth: true
        wrapMode: Text.WordWrap
        opacity: 0.7
    }
}
