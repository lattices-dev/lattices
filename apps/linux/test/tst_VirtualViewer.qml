import QtQuick
import QtTest
import ".." as App

Item {
    id: scene
    width: 520; height: 400
    property int captures: 0
    property int hides: 0
    property int controls: 0
    App.VirtualPreviewSession { id: session; onCaptureRequested: scene.captures++ }
    App.VirtualViewer {
        id: viewer; anchors.fill: parent; session: session
        onHideRequested: { scene.hides++; session.setVisibility("hide") }
        onControlsRequested: scene.controls++
    }
    TestCase {
        name: "VirtualViewer"
        when: windowShown
        readonly property string pixel: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR4nGP4DwQACfsD/fteaysAAAAASUVORK5CYII="
        function init() {
            session.shown = false; session.embeddedVisible = false; session.online = true
            session.space = ({ running: true, width: 1280, height: 800 })
            session.frame = ""; session.error = ""; session.fresh = false
            scene.captures = 0; scene.hides = 0; scene.controls = 0
        }
        function test_show_hide_preserves_running_work_and_stops_capture() {
            wait(280); compare(scene.captures, 0)
            verify(session.setVisibility("show")); tryVerify(() => scene.captures > 0)
            verify(session.watching); session.acceptFrame(pixel); verify(session.fresh)
            mouseClick(findChild(viewer, "viewerHide"))
            compare(scene.hides, 1); verify(!session.shown); verify(!session.watching)
            verify(session.space.running, "Hiding never stops the task")
            const captured = scene.captures; wait(320); compare(scene.captures, captured)
            verify(session.setVisibility("show")); verify(!session.fresh)
            session.acceptFrame(pixel); verify(session.fresh)
        }
        function test_embedded_and_floating_views_share_one_feed() {
            session.embeddedVisible = true; tryVerify(() => scene.captures > 0)
            session.shown = true; session.acceptFrame(pixel)
            session.shown = false; verify(session.watching); verify(session.fresh)
            session.embeddedVisible = false; verify(!session.watching)
            const captured = scene.captures; wait(320); compare(scene.captures, captured)
            session.acceptFrame(pixel); verify(!session.fresh, "A late hidden frame cannot claim LIVE")
        }
        function test_offline_and_stopped_states_never_claim_live() {
            session.shown = true; session.acceptFrame(pixel)
            compare(findChild(viewer, "viewerStatus").text, "LIVE")
            session.acceptError("Connection interrupted")
            compare(findChild(viewer, "viewerStatus").text, "INTERRUPTED")
            session.online = false; compare(findChild(viewer, "viewerStatus").text, "HOST OFFLINE")
            session.online = true; session.space = ({ running: false })
            compare(findChild(viewer, "viewerStatus").text, "STOPPED"); compare(session.frame, "")
            session.acceptFrame(pixel); verify(!session.fresh)
            verify(session.shown, "The viewer can remain open without owning the session")
        }
        function test_controls_are_an_explicit_separate_action() {
            mouseClick(findChild(viewer, "viewerControls")); compare(scene.controls, 1)
            compare(scene.hides, 0); verify(session.space.running)
            verify(!session.setVisibility("stop")); verify(!session.setVisibility("constructor"))
        }
        function test_a_stalled_feed_stops_claiming_live() {
            session.shown = true; session.acceptFrame(pixel)
            session.lastFrameAt = Date.now() - 4000
            tryCompare(session, "fresh", false, 1600)
            compare(findChild(viewer, "viewerStatus").text, "WAITING")
            session.acceptFrame(pixel); compare(findChild(viewer, "viewerStatus").text, "LIVE")
        }
    }
}
