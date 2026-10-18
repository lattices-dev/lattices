import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland
import "GestureModel.js" as Model

Item {
    id: root
    Component.onCompleted: console.info("Lattices pen trail v0.2.0 loaded")
    property var gesture: null
    property real trailOpacity: 0
    readonly property var targetScreen: Quickshell.screens.find(function(s) { return root.gesture && s.name === root.gesture.monitor; }) || Quickshell.screens[0]

    function accept(data) {
        var next = data.indexOf("lattices-gesture-result|") === 0 ? Model.applyResult(gesture, data) : Model.apply(gesture, data);
        if (!next) return false;
        fade.stop();
        gesture = next;
        trailOpacity = 1;
        stale.restart();
        if (["commit", "cancel", "success", "failure", "noop"].includes(next.phase)) fade.restart();
        return true;
    }

    Connections {
        target: Hyprland
        function onRawEvent(event) {
            if (event && event.name === "custom") root.accept(String(event.data));
        }
    }
    Timer { id: stale; interval: 12000; onTriggered: { root.trailOpacity = 0; root.gesture = null; } }
    SequentialAnimation {
        id: fade
        PauseAnimation { duration: !root.gesture ? 420 : root.gesture.phase === "cancel" ? 80 : ["failure", "noop"].includes(root.gesture.phase) ? 2200 : 600 }
        NumberAnimation { target: root; property: "trailOpacity"; to: 0; duration: 180 }
    }

    // Empty input region and no keyboard focus keep the surface decorative.
    PanelWindow {
        screen: root.targetScreen
        visible: root.gesture !== null && root.trailOpacity > 0
        anchors { left: true; right: true; top: true; bottom: true }
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore
        focusable: false
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
        WlrLayershell.namespace: "lattices-gesture-trail"
        mask: Region {}
        PenTrail { anchors.fill: parent; gesture: root.gesture; opacity: root.trailOpacity }
    }
}
