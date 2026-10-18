import QtQuick

// Where a placement puts the window on its display.
Rectangle {
    id: glyph
    property string placement: "left"
    property color ink: Theme.body
    readonly property var region: ({ left: [2, 2, 5, 7], right: [9, 2, 5, 7], center: [4, 3, 8, 5], maximize: [2, 2, 12, 7] })[placement] || [2, 2, 12, 7]
    implicitWidth: 16
    implicitHeight: 11
    radius: 1
    color: "transparent"
    border.color: Qt.rgba(ink.r, ink.g, ink.b, 0.55)
    Rectangle { x: glyph.region[0]; y: glyph.region[1]; width: glyph.region[2]; height: glyph.region[3]; color: glyph.ink }
}
