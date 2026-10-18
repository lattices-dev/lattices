import QtQuick
import Quickshell
import Quickshell.Wayland

// A non-focusing shell surface stays above apps without a compositor rule.
WlrLayershell {
    id: panel
    required property var session
    signal controlsRequested()
    property real panelWidth: 520
    property real rightInset: 24
    property real bottomInset: 72
    readonly property real previewRatio: session.space.width && session.space.height ? session.space.width / session.space.height : 1.6
    visible: session.shown
    screen: Quickshell.screens[0]
    anchors.right: true
    anchors.bottom: true
    margins.right: Math.round(Math.max(8, Math.min(rightInset, (screen?.width || 1920) - implicitWidth - 8)))
    margins.bottom: Math.round(Math.max(8, Math.min(bottomInset, (screen?.height || 1080) - implicitHeight - 8)))
    implicitWidth: Math.round(Math.min(panelWidth, (screen?.width || 1920) - 16, ((screen?.height || 1080) - 91) * previewRatio))
    implicitHeight: Math.round(implicitWidth / previewRatio) + 75
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    aboveWindows: true
    focusable: false
    namespace: "lattices-agent-viewer"

    function moveBy(dx, dy) {
        rightInset = Math.max(8, Math.min((screen?.width || 1920) - width - 8, margins.right - dx))
        bottomInset = Math.max(8, Math.min((screen?.height || 1080) - height - 8, margins.bottom - dy))
    }
    function resizeBy(dx, dy) {
        const maximum = Math.min((screen?.width || 1920) - 16, ((screen?.height || 1080) - 91) * previewRatio)
        const delta = Math.abs(dx) >= Math.abs(dy * previewRatio) ? dx : dy * previewRatio
        const next = Math.max(Math.min(340, maximum), Math.min(maximum, width + delta))
        rightInset = Math.max(8, margins.right - (next - width))
        bottomInset = Math.max(8, margins.bottom - (next - width) / previewRatio)
        panelWidth = next
    }
    VirtualViewer {
        anchors.fill: parent
        session: panel.session
        onHideRequested: panel.session.setVisibility("hide")
        onControlsRequested: panel.controlsRequested()
        onMoveRequested: (dx, dy) => panel.moveBy(dx, dy)
        onResizeRequested: (dx, dy) => panel.resizeBy(dx, dy)
    }
}
