import QtQuick 2.15
import org.kde.kwin 2.0 as KWin

// For Plasma 5: import org.kde.plasma.core 2.0 as PlasmaCore
// For Plasma 6: import org.kde.plasma.plasma5support as Plasma5Support
// We try Plasma 5 first, users on Plasma 6 may need to adjust
import org.kde.plasma.core 2.0 as PlasmaCore

KWin.Switcher {
    id: tabBox

    // Invisible placeholder - FastTab daemon handles all rendering
    Item {
        width: 1
        height: 1
    }

    // Command execution via Plasma's executable data source
    // In Plasma 5: PlasmaCore.DataSource
    // In Plasma 6: use Plasma5Support.DataSource (import org.kde.plasma.plasma5support)
    PlasmaCore.DataSource {
        id: executable
        engine: "executable"
        connectedSources: []

        function exec(cmd) {
            connectedSources.push(cmd);
        }

        onNewData: function(source, data) {
            var idx = connectedSources.indexOf(source);
            if (idx !== -1) {
                connectedSources.splice(idx, 1);
            }
        }
    }

    // Use a Repeater to iterate model and collect window IDs
    // The delegate has access to 'windowId' role from tabBox.model
    Repeater {
        id: idRepeater
        model: tabBox.model
        delegate: Item {
            property var wId: windowId
        }
    }

    function collectWindowIds() {
        var ids = [];
        for (var i = 0; i < idRepeater.count; i++) {
            var item = idRepeater.itemAt(i);
            if (item && item.wId) {
                ids.push(item.wId);
            }
        }
        return ids;
    }

    // Track visibility changes for show/hide commands
    onVisibleChanged: {
        if (visible) {
            // Delay slightly to ensure model is populated
            showTimer.start();
        } else {
            executable.exec("fasttab hide");
        }
    }

    Timer {
        id: showTimer
        interval: 5
        repeat: false
        onTriggered: {
            var ids = tabBox.collectWindowIds();
            if (ids.length > 0) {
                executable.exec("fasttab show " + ids.join(","));
            }
        }
    }

    // Send index updates as user navigates
    onCurrentIndexChanged: {
        if (visible) {
            executable.exec("fasttab index " + currentIndex);
        }
    }
}
