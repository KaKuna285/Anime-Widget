import QtQuick
import QtQuick.Controls as Controls
import org.kde.plasma.plasmoid
import org.kde.plasma.core as PlasmaCore
import org.kde.kirigami as Kirigami

PlasmoidItem {
    id: root
    Plasmoid.backgroundHints: PlasmaCore.Types.NoBackground

    AnimeBackend {
        id: animeBackend
        refreshInterval: plasmoid.configuration.refreshInterval
        preferEnglishTitle: plasmoid.configuration.preferEnglishTitle
    }

    compactRepresentation: Controls.Label {
        text: plasmoid.configuration.showEpisodeCount &&
        animeBackend.episodes.length > 0
        ? animeBackend.episodes.length
        : ""

        color: Kirigami.Theme.textColor
        font.pixelSize: Kirigami.Units.gridUnit * 1.2
    }

    fullRepresentation: AnimeContent {
        backend: animeBackend
        askToGrade: plasmoid.configuration.askToGrade
        confirmUndo: plasmoid.configuration.confirmUndo
        backgroundOpacity: plasmoid.configuration.backgroundOpacity
        itemSpacing: plasmoid.configuration.itemSpacing
        titleSize: plasmoid.configuration.titleSize
        episodeSize: plasmoid.configuration.episodeSize
        title: plasmoid.configuration.title
        emptyTitle: plasmoid.configuration.emptyTitle
    }
}
