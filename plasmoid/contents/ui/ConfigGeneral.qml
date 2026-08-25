import QtQuick
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami

Kirigami.FormLayout {
    id: page

    property alias cfg_title: titleField.text
    property alias cfg_emptyTitle: emptyTitleField.text
    property alias cfg_showEpisodeCount: episodeCountCheck.checked

    QQC2.TextField {
        id: titleField
        Kirigami.FormData.label: i18n("Title:")
        placeholderText: i18n("New Episodes")
    }

    QQC2.TextField {
        id: emptyTitleField
        Kirigami.FormData.label: i18n("Title when empty:")
        placeholderText: i18n("No new episodes")
    }

    QQC2.CheckBox {
        id: episodeCountCheck
        text: i18n("Show episode count on compact icon")
    }
}
