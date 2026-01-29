import QtQuick
import org.kde.kwin 3.0 as KWin
import org.kde.plasma.plasma5support as Plasma5Support

KWin.TabBoxSwitcher {
    id: tabBox

    Item {
        width: 1
        height: 1
    }

    Plasma5Support.DataSource {
        id: executable
        engine: "executable"
        connectedSources: []

        function exec(cmd) {
            executable.connectSource(cmd);
        }

        onNewData: function(source, data) {
            executable.disconnectSource(source);
        }
    }

    onVisibleChanged: {
        if (visible) {
            executable.exec("/home/loris/source/fasttab/zig-out/bin/fasttab show");
        } else {
            executable.exec("/home/loris/source/fasttab/zig-out/bin/fasttab hide");
        }
    }

    onCurrentIndexChanged: {
        if (visible) {
            executable.exec("/home/loris/source/fasttab/zig-out/bin/fasttab index " + currentIndex);
        }
    }
}
