import QtQuick
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami

Kirigami.FormLayout {
    id: page

    property alias cfg_title: titleField.text
    property alias cfg_emptyTitle: emptyTitleField.text
    property alias cfg_showEpisodeCount: episodeCountCheck.checked
    property alias cfg_refreshInterval: refreshSpin.value
    property alias cfg_titleSize: titleSizeSpin.value
    property alias cfg_episodeSize: episodeSizeSpin.value
    property alias cfg_itemSpacing: spacingSpin.value
    property alias cfg_maxEpisodes: maxEpisodesSpin.value
    property alias cfg_backgroundOpacity: backgroundOpacitySpin.value

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
        text: i18n("Show episode count")
    }

    QQC2.SpinBox {
        id: refreshSpin
        Kirigami.FormData.label: i18n("Refresh interval:")
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
        id: maxEpisodesSpin
        Kirigami.FormData.label: i18n("Maximum episodes:")
        from: 1
        to: 100
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
