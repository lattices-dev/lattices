import QtQuick

Item {
    id: symbol
    property string name: ""
    property color tint: Theme.muted
    implicitWidth: 18
    implicitHeight: 18
    readonly property var paths: ({
        home: '<path d="m3 10 9-7 9 7M5 9v12h5v-7h4v7h5V9"/>',
        overview: '<rect x="3" y="4" width="11" height="7" rx="1.5"/><rect x="3" y="15" width="7" height="6" rx="1.5"/><rect x="14" y="15" width="7" height="6" rx="1.5"/><path d="M18 4v7h3"/>',
        virtual: '<rect x="3" y="4" width="18" height="13" rx="2"/><path d="M8 21h8M12 17v4M7 8h4v5H7zM14 8h3m-3 4h3"/>',
        layers: '<path d="m3 7 9-4 9 4-9 4zM3 12l9 4 9-4M3 17l9 4 9-4"/>',
        activity: '<rect x="3" y="4" width="18" height="16" rx="2"/><path d="M7 8h1m3 0h6M7 12h1m3 0h6M7 16h1m3 0h4"/>',
        settings: '<path d="m10 3-1 3-3 1-3 3 2 2-2 2 3 3 3 1 1 3h4l1-3 3-1 3-3-2-2 2-2-3-3-3-1-1-3z"/><circle cx="12" cy="12" r="3"/>',
        search: '<circle cx="10" cy="10" r="6"/><path d="m15 15 6 6"/>',
        hints: '<circle cx="12" cy="12" r="9"/><path d="M9 9a3 3 0 0 1 6 0c0 2-3 2-3 4m0 4h.01"/>',
        refresh: '<path d="M20 8a8 8 0 1 0 0 9M20 3v5h-5"/>',
        terminal: '<rect x="3" y="4" width="18" height="16" rx="3"/><path d="m7 9 3 3-3 3m6 0h4"/>',
        window: '<rect x="3" y="4" width="18" height="16" rx="2"/><path d="M3 9h18M7 6.5h.1m3 0h.1"/>',
        plus: '<path d="M12 5v14M5 12h14"/>',
        arrow: '<path d="M5 12h14m-5-5 5 5-5 5"/>',
        close: '<path d="m6 6 12 12M6 18 18 6"/>'
    })
    Image {
        anchors.fill: parent
        sourceSize: Qt.size(width * 2, height * 2)
        source: "data:image/svg+xml;utf8," + encodeURIComponent('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="' + symbol.tint + '" stroke-width="' + Theme.stroke + '" stroke-linecap="round" stroke-linejoin="round">' + (symbol.paths[symbol.name] || symbol.paths.window) + '</svg>')
    }
}
