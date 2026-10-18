import QtQuick

// Viewing has its own lifetime. Nothing here starts, stops or drives a desktop.
QtObject {
    id: session
    property bool shown: false
    property bool embeddedVisible: false
    property bool online: false
    property var space: ({ running: false })
    property string frame: ""
    property string error: ""
    property bool fresh: false
    property double lastFrameAt: 0
    property int framesReceived: 0
    readonly property bool running: !!space.running
    readonly property bool watching: online && running && (shown || embeddedVisible)
    signal captureRequested()

    function setVisibility(action) {
        if (!["show", "hide", "toggle"].includes(action)) return false
        shown = action === "toggle" ? !shown : action === "show"
        return true
    }
    function acceptFrame(image) {
        if (!watching) return
        frame = "data:image/png;base64," + image
        error = ""
        fresh = true
        lastFrameAt = Date.now()
        framesReceived++
    }
    function acceptError(message) { if (watching) { error = message; fresh = false } }
    onWatchingChanged: fresh = false
    onRunningChanged: if (!running) { frame = ""; error = ""; fresh = false }
    property Timer captureTimer: Timer {
        interval: 250
        repeat: true
        triggeredOnStart: true
        running: session.watching
        onTriggered: session.captureRequested()
    }
    property Timer freshnessTimer: Timer {
        interval: 1000; repeat: true; running: session.watching
        onTriggered: if (session.fresh && Date.now() - session.lastFrameAt > 3000) session.fresh = false
    }
}
