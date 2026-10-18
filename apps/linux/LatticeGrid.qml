import QtQuick

// Dot lattice for instrument wells.
Image {
    id: grid
    property int pitch: 24
    property color ink: Theme.grid
    fillMode: Image.Tile
    horizontalAlignment: Image.AlignLeft
    verticalAlignment: Image.AlignTop
    sourceSize: Qt.size(pitch, pitch)
    source: "data:image/svg+xml;utf8," + encodeURIComponent('<svg xmlns="http://www.w3.org/2000/svg" width="' + pitch + '" height="' + pitch + '"><rect width="1" height="1" fill="' + grid.ink + '"/></svg>')
}
