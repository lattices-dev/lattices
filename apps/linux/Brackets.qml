pragma ComponentBehavior: Bound
import QtQuick

// Four L-shaped corner marks, after the Lattices L.
Item {
    id: marks
    property color ink: Theme.dim
    property real arm: 9
    property real weight: 1
    Repeater {
        model: 4
        Item {
            id: corner
            required property int index
            readonly property bool east: index % 2 === 1
            readonly property bool south: index >= 2
            x: east ? marks.width - marks.arm : 0
            y: south ? marks.height - marks.arm : 0
            width: marks.arm; height: marks.arm
            Rectangle { width: marks.arm; height: marks.weight; y: corner.south ? marks.arm - marks.weight : 0; color: marks.ink }
            Rectangle { width: marks.weight; height: marks.arm; x: corner.east ? marks.arm - marks.weight : 0; color: marks.ink }
        }
    }
}
