pragma ComponentBehavior: Bound
import QtQuick

// The Lattices L on a neutral tile. No hue of its own: it takes the theme's
// grays and its primary type color.
Rectangle {
    id: mark
    implicitWidth: 24
    implicitHeight: 24
    radius: width * 0.28
    border.color: Theme.borderHot
    gradient: Gradient {
        GradientStop { position: 0; color: Theme.hover }
        GradientStop { position: 1; color: Theme.surface }
    }
    // Same 3×3 L and avatar proportions as the Mac's LatticesMarkAvatar.
    Item {
        id: glyph
        width: mark.width * 0.55
        height: width
        anchors.centerIn: parent
        readonly property real pad: Math.max(1, width * 0.1)
        readonly property real gap: Math.max(0.6, width * 0.06)
        readonly property real cell: (width - 2 * pad - 2 * gap) / 3
        Repeater {
            model: [true, false, false, true, false, false, true, true, true]
            Rectangle {
                required property int index
                required property bool modelData
                x: glyph.pad + (index % 3) * (glyph.cell + glyph.gap)
                y: glyph.pad + Math.floor(index / 3) * (glyph.cell + glyph.gap)
                width: glyph.cell
                height: glyph.cell
                radius: Math.max(0.6, width * 0.18)
                color: Theme.text
                opacity: modelData ? 1 : 0.12
            }
        }
    }
}
