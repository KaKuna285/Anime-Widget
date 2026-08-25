import QtQuick
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami

Kirigami.FormLayout {
    id: page

    property alias cfg_titleSize: titleSizeSpin.value
    property alias cfg_episodeSize: episodeSizeSpin.value
    property alias cfg_itemSpacing: spacingSpin.value
    property alias cfg_backgroundOpacity: backgroundOpacitySpin.value

    QQC2.SpinBox {
        id: titleSizeSpin
        Kirigami.FormData.label: i18n("Title font size:")
        from: 8
        to: 32
    }

    QQC2.SpinBox {
        id: episodeSizeSpin
        Kirigami.FormData.label: i18n("List font size:")
        from: 8
        to: 28
    }

    QQC2.SpinBox {
        id: spacingSpin
        Kirigami.FormData.label: i18n("Episode spacing:")
        from: 0
        to: 30
    }

    QQC2.SpinBox {
        id: backgroundOpacitySpin
        Kirigami.FormData.label: i18n("Background opacity:")
        from: 0
        to: 100
        stepSize: 1

        textFromValue: function(value, locale) {
            return value + "%"
        }

        valueFromText: function(text, locale) {
            return parseInt(text)
        }
    }
}
