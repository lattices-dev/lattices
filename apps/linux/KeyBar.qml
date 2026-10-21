pragma ComponentBehavior: Bound
import QtQuick

// The keys that work in this view, most important first. Entries that do
// not fit drop off the end whole.
Item {
    id: bar
    property var keys: []
    implicitHeight: 17
    clip: true
    Flow {
        width: parent.width
        spacing: 16
        Repeater {
            model: bar.keys
            Row {
                id: entry
                required property var modelData
                spacing: 6
                KeyCap { text: entry.modelData.cap }
                AppText { text: entry.modelData.label; font.pixelSize: Theme.small; color: Theme.muted; height: 17; verticalAlignment: Text.AlignVCenter }
            }
        }
    }
}
