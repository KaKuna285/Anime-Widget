import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami

Kirigami.FormLayout {
    id: page

    property alias cfg_refreshInterval: refreshSpin.value
    property alias cfg_confirmUndo: confirmUndoCheck.checked
    property alias cfg_askToGrade: askToGradeCheck.checked

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
}
