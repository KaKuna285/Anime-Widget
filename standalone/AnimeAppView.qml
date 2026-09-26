import QtQuick
import QtQuick.Controls as Controls
import QtQuick.Layouts
import org.kde.kirigami as Kirigami

ColumnLayout {
    id: view

    property var backend
    property bool askToGrade: true
    property bool confirmUndo: true
    property int itemSpacing: 8
    property int titleSize: 18
    property int episodeSize: 14
    property string title: "New Episodes"
    property string emptyTitle: "No new episodes"

    signal settingsRequested()

    spacing: 0

    AnimeDialogs {
        id: dialogs
        backend: view.backend
        askToGrade: view.askToGrade
        confirmUndo: view.confirmUndo
    }

    Kirigami.AbstractApplicationHeader {
        Layout.fillWidth: true

        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: Kirigami.Units.largeSpacing
            anchors.rightMargin: Kirigami.Units.smallSpacing
            spacing: Kirigami.Units.smallSpacing

            Controls.Label {
                Layout.fillWidth: true
                font.bold: true
                font.pixelSize: view.titleSize
                text: view.backend.episodes.length > 0 ? view.title : view.emptyTitle
            }

            Controls.Button {
                icon.name: "view-list-details"
                text: i18n("Manage Series")
                display: Controls.Button.TextBesideIcon
                flat: true
                onClicked: dialogs.openManageSeries()
            }

            Controls.Button {
                icon.name: "edit-undo"
                text: i18n("Undo")
                display: Controls.Button.TextBesideIcon
                flat: true
                enabled: view.backend.history.length > 0 || Object.keys(view.backend.lastRemoved).length > 0
                onClicked: dialogs.requestUndo()
            }

            Controls.Button {
                icon.name: "configure"
                text: i18n("Settings")
                display: Controls.Button.TextBesideIcon
                flat: true
                onClicked: view.settingsRequested()
            }
        }
    }

    Controls.ScrollView {
        Layout.fillWidth: true
        Layout.fillHeight: true
        clip: true

        Kirigami.CardsListView {
            id: seriesListView
            model: view.backend.groupedEpisodes()
            spacing: Kirigami.Units.largeSpacing

            delegate: Kirigami.AbstractCard {
                width: seriesListView.width

                property var group: modelData

                contentItem: ColumnLayout {
                    spacing: view.itemSpacing

                    Controls.Label {
                        Layout.fillWidth: true
                        text: group.label
                        font.bold: true
                        font.pixelSize: view.titleSize
                        wrapMode: Text.WordWrap
                    }

                    Kirigami.Separator {
                        Layout.fillWidth: true
                    }

                    Repeater {
                        model: group.episodes

                        delegate: Item {
                            id: episodeRow

                            Layout.fillWidth: true
                            implicitHeight: episodeRowLayout.implicitHeight

                            property var episode: modelData

                            RowLayout {
                                id: episodeRowLayout
                                width: parent.width
                                spacing: Kirigami.Units.smallSpacing

                                Controls.CheckBox {
                                    text: view.backend.episodeLabel(episodeRow.episode)
                                    font.pixelSize: view.episodeSize
                                    Layout.fillWidth: true

                                    onClicked: view.backend.markDone(episodeRow.episode)
                                }

                                Controls.ToolButton {
                                    icon.name: "media-playback-start"
                                    onClicked: view.backend.openFile(episodeRow.episode.path)
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
                                    onTriggered: view.backend.openContainingFolder(episodeRow.episode)
                                }

                                Controls.MenuItem {
                                    text: i18n("Remove \"%1\"", view.backend.episodeLabel(episodeRow.episode))
                                    onTriggered: view.backend.removeEpisode(episodeRow.episode)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
