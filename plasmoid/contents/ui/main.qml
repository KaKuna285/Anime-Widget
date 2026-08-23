import QtQuick
import QtQuick.Controls as Controls
import QtQuick.Layouts
import QtCore
import org.kde.plasma.plasmoid
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.plasma5support as Plasma5Support
import org.kde.kirigami as Kirigami

PlasmoidItem {
    id: root
    Plasmoid.backgroundHints: PlasmaCore.Types.NoBackground
    property var episodes: []
    property string scriptPath: "$HOME/.local/bin/anime-downloaded.sh"

    property var history: []

    function groupedEpisodes() {
	    var groups = {}
	
	    for (var i = 0; i < root.episodes.length; i++) {
	        var episode = root.episodes[i]
	        var series = episode.series
	
	        if (!groups[series]) {
	            groups[series] = []
	        }
	
	        groups[series].push(episode)
	    }
	
	    var result = []
	
	    for (var series in groups) {
	        groups[series].sort(function(a, b) {
	            if (a.season !== b.season) {
	                return a.season - b.season
            }

            return a.episode - b.episode
	        })

        result.push({
            series: series,
	            episodes: groups[series]
	        })
	    }

	    result.sort(function(a, b) {
	        return a.series.localeCompare(b.series)
	    })
		    return result
	}
		
    Plasma5Support.DataSource {
        id: executable
        engine: "executable"
        connectedSources: []

       onNewData: function(source, data) {
	    disconnectSource(source)

	    if (source === scriptPath + " list") {
	        var output = data["stdout"] || ""

	        try {
	            root.episodes = JSON.parse(output)
	        } catch (error) {
	            console.log("Failed to parse anime JSON:", error)
	            root.episodes = []
	        }
	    }

	    if (source === scriptPath + " history") {
	        var historyOutput = data["stdout"] || ""

	        try {
	             root.history = JSON.parse(historyOutput)
	         } catch (error) {
	             console.log("Failed to parse anime history JSON:", error)
	             root.history = []
	         }
	    }
	}

        function run(command) {
            connectSource(command)
        }
    }

    function refresh() {
        executable.run(
 	   scriptPath + " list"
	)
	executable.run(
	    scriptPath + " history"
	)
    }

    function markDone(episode) {
   	 executable.run(
   	     scriptPath + " done " +
   	     JSON.stringify(episode.series) + " " +
   	     episode.season + " " +
   	     episode.episode
   	 )

    refreshTimer.restart()

    }

    function undoLast() {
	executable.run(
	    scriptPath + " undo"
	)
	
	refreshTimer.restart()
    }

    Timer {
        id: refreshTimer

        interval: plasmoid.configuration.refreshInterval * 1000
        repeat: true
        running: true

        onTriggered: root.refresh()
    }

    Component.onCompleted: {
        root.refresh()
    }

    compactRepresentation: Controls.Label {
        text: plasmoid.configuration.showEpisodeCount &&
              root.episodes.length > 0
              ? root.episodes.length
              : ""

        color: Kirigami.Theme.textColor
        font.pixelSize: Kirigami.Units.gridUnit * 1.2
    }

    fullRepresentation: Item {
        Rectangle {
            anchors.fill: parent
            color: Kirigami.Theme.backgroundColor
            opacity: plasmoid.configuration.backgroundOpacity / 100.0
            radius: Kirigami.Units.smallSpacing
        }

        Layout.minimumWidth: Kirigami.Units.gridUnit * 10
        Layout.minimumHeight: Kirigami.Units.gridUnit * 8
        Layout.preferredWidth: Kirigami.Units.gridUnit * 22
        Layout.preferredHeight: Kirigami.Units.gridUnit * 14

        ColumnLayout {
            id: verticalLayout

            anchors.fill: parent
            spacing: plasmoid.configuration.itemSpacing

            Item {
 		   Layout.fillWidth: true
 		   Layout.preferredHeight: Math.max(
		        plasmoid.configuration.titleSize,
		        plasmoid.configuration.episodeSize
		    ) + Kirigami.Units.smallSpacing * 2

 		   Controls.Label {
 		       anchors.centerIn: parent

 		       text: root.episodes.length > 0
      		        ? plasmoid.configuration.title
      		        : plasmoid.configuration.emptyTitle

     		   color: Kirigami.Theme.textColor
     		   font.bold: true
     		   font.pixelSize: plasmoid.configuration.titleSize
   		 }

  		  Controls.ToolButton {
     		   anchors.right: parent.right
     		   anchors.verticalCenter: parent.verticalCenter

    		   icon.name: "edit-undo"

	           enabled: root.history.length > 0

	           onClicked: root.undoLast()

      	           Controls.ToolTip.visible: hovered
  	           Controls.ToolTip.text: "Undo last checked-off episode"
   	          }
	}

            EpisodeList {
                Layout.fillWidth: true
                Layout.fillHeight: true
            }
        }
    }

    component EpisodeList: ColumnLayout {
        spacing: plasmoid.configuration.itemSpacing

        ListView {
            visible: root.episodes.length > 0

            model: root.groupedEpisodes()

            clip: true

            Layout.fillWidth: true
            Layout.fillHeight: true

            spacing: plasmoid.configuration.itemSpacing

            delegate: ColumnLayout {
                width: ListView.view.width
                spacing: plasmoid.configuration.itemSpacing

                property var group: modelData

                Controls.Label {
                    text: group.series

                    font.bold: true
                    font.pixelSize: plasmoid.configuration.episodeSize
                    color: Kirigami.Theme.textColor

                    Layout.fillWidth: true
                }

                Repeater {
                    model: group.episodes

                    delegate: RowLayout {
                        width: ListView.view.width
                        spacing: Kirigami.Units.smallSpacing

                        property var episode: modelData

                        Controls.CheckBox {
                            text: "S"
                                  + ("0" + episode.season).slice(-2)
                                  + "E"
                                  + ("0" + episode.episode).slice(-2)

                            font.pixelSize:
                                plasmoid.configuration.episodeSize

                            Layout.fillWidth: true

                            onClicked: {
                                root.markDone(episode)
                            }
                        }

                        Controls.ToolButton {
                            icon.name: "media-playback-start"

                            onClicked: {
                                executable.run(
                                    "xdg-open "
                                    + JSON.stringify(episode.path)
                                )
                            }
                        }
                    }
                }
            }
        }
    }
}
