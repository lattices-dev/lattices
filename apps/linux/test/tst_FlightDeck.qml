import QtQuick
import QtTest
import ".." as App

Item {
    id: scene
    width: 1440; height: 900
    function fixture() {
        const window = (wid, app, title, x, y, w, h, space) => ({ wid, app, title, frame: { x, y, w, h }, spaceIds: [space], displayIndex: 0, isOnScreen: space === 1, isFocused: wid === 11, isFloating: false, isFullscreen: false })
        return {
            windows: [window(11, "kitty", "nvim · src/forecast.rs", 0, 0, 790, 900, 1), window(12, "chromium", "Lattices docs", 810, 0, 790, 440, 1), window(13, "kitty", "cargo watch -x test", 810, 460, 790, 440, 1), window(14, "obsidian", "Project notes", 0, 0, 1600, 900, 3)],
            displays: [{ displayIndex: 0, displayId: "DP-1", frame: { x: 0, y: 0, w: 1600, h: 900 }, currentSpaceId: 1, spaces: [{ id: 1, windowCount: 3 }, { id: 3, windowCount: 1 }, { id: 7, windowCount: 0 }] }],
            layers: [{ id: "build", label: "Build", active: true }, { id: "docs", label: "Docs", active: false }],
            stage: { parked: [] }, virtual: { available: false, running: false },
            describe: { hostname: "archie", methods: ["windows.focus", "windows.place", "windows.resolve", "spaces.focus", "layers.activate", "layers.reveal"], capabilityHealth: { "windows.place": { available: true } } }
        }
    }
    QtObject {
        id: controller
        property var state: scene.fixture()
        property bool online: true
        property bool busy: false
        property string page: "Overview"
        property string query: ""
        property double selectedWid: -1
        property string virtualFrame: ""
        property string virtualError: ""
        property bool virtualControl: false
        property var dialogParent: scene
        property var calls: []
        signal actionFinished(string method, var result)
        function appName(raw) { return ({ kitty: "Terminal", chromium: "Chromium", obsidian: "Obsidian" })[raw] || raw }
        function call(method, params) { calls = calls.concat([{ method, params }]) }
        function previewVirtual() {}
    }
    App.OverviewPage { id: deck; anchors.fill: parent; controller: controller }
    TestCase {
        id: tests
        name: "FlightDeck"
        when: windowShown
        function init() {
            findChild(deck, "deckMap").motionEnabled = false
            scene.width = 1440; scene.height = 900
            controller.query = ""; controller.calls = []; controller.selectedWid = 11
            controller.online = true; controller.busy = false; controller.state = scene.fixture()
            deck.displayIndex = -1; deck.inspectedSpace = -1; deck.virtualView = false; deck.previewPlacement = false; deck.placementPlan = null; deck.commandError = ""
            deck.statusNote = ""; deck.targetAction = null
            deck.focusMap()
            findChild(deck, "deckMap").fitSpace(1)
            wait(40)
        }
        function test_canvas_motion_is_anchored_and_drag_interrupts_without_a_jump() {
            const map = findChild(deck, "deckMap")
            map.motionEnabled = true
            const start = map.visualCamera
            const px = map.width / 2, py = map.height / 2
            map.zoomBy(2, px, py)
            verify(map.motionRunning)
            wait(40)
            const during = map.visualCamera
            verify(during.zoom > start.zoom && during.zoom < map.camera.zoom)
            verify(Math.abs((px - during.x) / during.zoom - (px - start.x) / start.zoom) < 0.001)
            verify(Math.abs((py - during.y) / during.zoom - (py - start.y) / start.zoom) < 0.001)
            keyPress(Qt.Key_Space)
            mousePress(map, 8, 8, Qt.LeftButton)
            wait(10)
            verify(!map.motionRunning, "Pressing to drag must interrupt camera motion")
            compare(map.camera.zoom, map.visualCamera.zoom)
            const grabbed = map.visualCamera
            mouseMove(map, 30, 20, 10)
            wait(10)
            mouseMove(map, 80, 38, 10)
            wait(10)
            verify(Math.abs(map.visualCamera.x - grabbed.x - 72) < 1)
            verify(Math.abs(map.visualCamera.y - grabbed.y - 30) < 1)
            mouseRelease(map, 80, 38, Qt.LeftButton)
            keyRelease(Qt.Key_Space)
            compare(controller.calls.length, 0)
            map.fitAll()
            verify(map.motionRunning)
            tryVerify(() => !map.motionRunning, 600)
            compare(map.visualCamera.zoom, map.camera.zoom)
            verify(map.visualCamera.x >= 27)
        }
        function test_canvas_fit_zoom_pan_and_read_only_navigation() {
            const map = findChild(deck, "deckMap")
            const detail = map.camera.zoom
            keyClick(Qt.Key_0)
            verify(map.camera.zoom < detail)
            compare(map.fitMode, "all")
            compare(map.sheets.length, 3)
            grabImage(scene).save("/tmp/lattices-canvas-all-wide.png")
            const before = map.camera
            mouseWheel(map, map.width / 2, map.height / 2, 0, 120, Qt.NoButton, Qt.NoModifier)
            verify(map.camera.zoom > before.zoom)
            compare(map.fitMode, "free")
            const zoomed = map.camera
            mouseDrag(map, 8, 8, 70, 30, Qt.LeftButton, Qt.NoModifier, 5)
            verify(map.camera.x > zoomed.x + 40)
            compare(controller.calls.length, 0, "Camera motion must not mutate desktop state")
            const other = map.sheets.find(sheet => sheet.id === 3)
            mouseClick(map, map.camera.x + (other.x + other.w / 2) * map.camera.zoom, map.camera.y + (other.y + other.h / 2) * map.camera.zoom)
            compare(deck.spaceId, 3); compare(deck.selected.wid, 14)
            compare(controller.calls.length, 0)
            keyClick(Qt.Key_1)
            compare(map.fitMode, "space")
            compare(controller.calls.length, 0)
            keyClick(Qt.Key_Return)
            compare(controller.calls[0].method, "windows.focus")
            compare(controller.calls[0].params.wid, 14)
            keyClick(Qt.Key_Escape)
            compare(deck.spaceId, 1); compare(map.fitMode, "space")
            scene.width = 560; scene.height = 420; wait(50)
            map.fitAll(); wait(30)
            verify(map.camera.x >= 27)
            verify(map.camera.x + map.bounds.w * map.camera.zoom <= map.width - 27)
            grabImage(scene).save("/tmp/lattices-canvas-all-narrow.png")
        }
        function test_canvas_wheel_interrupts_framing_at_the_visible_pointer_position() {
            const map = findChild(deck, "deckMap")
            map.motionEnabled = true
            map.fitAll(); wait(55)
            verify(map.motionRunning)
            const shown = map.visualCamera, px = 150, py = 170
            mouseWheel(map, px, py, 0, 120, Qt.NoButton, Qt.NoModifier)
            verify(Math.abs((px - map.camera.x) / map.camera.zoom - (px - shown.x) / shown.zoom) < 0.001)
            verify(Math.abs((py - map.camera.y) / map.camera.zoom - (py - shown.y) / shown.zoom) < 0.001)
            compare(map.motionKind, "zoom")
            compare(controller.calls.length, 0)
        }
        function test_canvas_preserves_free_camera_when_live_inventory_updates() {
            const map = findChild(deck, "deckMap")
            map.zoomBy(0.5); map.panBy(120, -50)
            const camera = map.camera
            controller.state = scene.fixture(); wait(40)
            compare(map.camera.zoom, camera.zoom); compare(map.camera.x, camera.x); compare(map.camera.y, camera.y)
            compare(controller.calls.length, 0)
        }
        function test_canvas_wheel_over_window_tiles_and_horizontal_pan() {
            const map = findChild(deck, "deckMap")
            const sheet = map.sheets[0]
            const x = map.camera.x + (sheet.x + 150) * map.camera.zoom
            const y = map.camera.y + (sheet.y + 150) * map.camera.zoom
            const before = map.camera
            mouseWheel(map, x, y, 0, 120, Qt.NoButton, Qt.NoModifier)
            verify(map.camera.zoom > before.zoom, "Scrolling over a window tile must zoom")
            const zoomed = map.camera
            mouseWheel(map, x, y, 120, 0, Qt.NoButton, Qt.NoModifier)
            verify(map.camera.x !== zoomed.x, "Horizontal scrolling must pan")
            compare(map.camera.zoom, zoomed.zoom)
            compare(controller.calls.length, 0)
        }
        function test_canvas_keeps_space_anchored_when_other_spaces_are_created_or_removed() {
            const map = findChild(deck, "deckMap")
            deck.inspectSpace(3); wait(30)
            map.zoomBy(0.8); map.panBy(30, 0)
            const before = map.camera.x + map.sheets.find(s => s.id === 3).x * map.camera.zoom
            const inserted = scene.fixture(); inserted.displays[0].spaces.push({ id: 2, windowCount: 0 })
            controller.state = inserted; wait(40)
            verify(Math.abs(map.camera.x + map.sheets.find(s => s.id === 3).x * map.camera.zoom - before) < 0.001)
            const removed = scene.fixture(); removed.displays[0].currentSpaceId = 3; removed.displays[0].spaces = [{ id: 3, windowCount: 1 }, { id: 7, windowCount: 0 }]
            controller.state = removed; wait(40)
            verify(Math.abs(map.camera.x + map.sheets.find(s => s.id === 3).x * map.camera.zoom - before) < 0.001)
            compare(controller.calls.length, 0)
        }
        function test_canvas_space_drag_pans_over_window_tiles_without_focus() {
            const map = findChild(deck, "deckMap")
            const sheet = map.sheets[0]
            const x = map.camera.x + (sheet.x + 150) * map.camera.zoom
            const y = map.camera.y + (sheet.y + 150) * map.camera.zoom
            const before = map.camera
            keyPress(Qt.Key_Space)
            verify(map.panHeld)
            mouseDrag(map, x, y, 90, 40, Qt.LeftButton, Qt.NoModifier, 5)
            keyRelease(Qt.Key_Space)
            verify(!map.panHeld)
            verify(map.camera.x > before.x + 40)
            compare(controller.calls.length, 0)
        }
        function test_canvas_pinch_changes_camera_without_a_desktop_action() {
            const map = findChild(deck, "deckMap")
            const before = map.camera.zoom
            const touch = touchEvent(map)
            touch.press(0, map, 150, 80).press(1, map, 250, 80).commit(); wait(20)
            touch.move(0, map, 130, 80).move(1, map, 270, 80).commit(); wait(20)
            touch.move(0, map, 100, 80).move(1, map, 300, 80).commit(); wait(20)
            touch.release(0, map, 100, 80).release(1, map, 300, 80).commit(); wait(20)
            verify(map.camera.zoom > before)
            compare(controller.calls.length, 0)
        }
        function test_keyboard_selection_does_not_focus_until_enter() {
            keyClick(Qt.Key_Right)
            compare(controller.selectedWid, 12)
            compare(controller.calls.length, 0)
            keyClick(Qt.Key_Down)
            compare(controller.selectedWid, 13)
            keyClick(Qt.Key_Return)
            compare(controller.calls.length, 1)
            compare(controller.calls[0].method, "windows.focus")
            compare(controller.calls[0].params.wid, 13)
        }
        function test_space_inspection_is_read_only() {
            keyClick(Qt.Key_BracketRight)
            compare(deck.spaceId, 3); compare(deck.inspecting, true)
            compare(controller.calls.length, 0)
            compare(deck.selected.wid, 14)
            keyClick(Qt.Key_BracketRight)
            compare(deck.spaceId, 7); compare(deck.windows.length, 0)
            keyClick(Qt.Key_Escape)
            compare(deck.spaceId, 1); compare(controller.calls.length, 0)
        }
        function test_search_editing_keeps_navigation_keys() {
            deck.focusSearch()
            const field = findChild(deck, "deckSearch")
            verify(field.activeFocus)
            controller.query = "nvim"
            keyClick(Qt.Key_Left)
            compare(controller.selectedWid, 11)
            compare(controller.calls.length, 0)
            keyClick(Qt.Key_Escape)
            compare(controller.query, "")
            verify(deck.activeFocus)
        }
        function test_commands_use_the_same_window_api() {
            controller.query = "lats window place 12 right --dry-run"
            deck.runEntry()
            compare(controller.calls.length, 1)
            compare(controller.calls[0].method, "windows.place")
            compare(controller.calls[0].params.wid, 12)
            compare(controller.calls[0].params.dryRun, true)
            compare(controller.selectedWid, 12)
            controller.actionFinished("windows.place", { status: "planned", target: { wid: 12 }, frame: { x: 800, y: 0, w: 800, h: 900 } })
            verify(deck.placementPlan !== null)
            compare(deck.selectedCommand, "lats window place 12 right --dry-run")
            controller.query = "lats window focus 0xc"
            deck.runEntry()
            compare(controller.calls.length, 1)
            verify(deck.commandError.length > 0)
        }
        function test_preview_receipt_and_closed_window() {
            deck.previewPlacement = true
            deck.placeTarget("right")
            compare(controller.calls[0].params.dryRun, true)
            controller.actionFinished("windows.place", { status: "planned", target: { wid: 11 }, frame: { x: 800, y: 0, w: 800, h: 900 } })
            verify(deck.placementPlan !== null)
            const next = scene.fixture(); next.windows = next.windows.filter(w => w.wid !== 11)
            controller.state = next
            wait(40)
            verify(deck.placementPlan === null)
            compare(controller.selectedWid, 12)
            deck.focusTarget()
            compare(controller.calls[1].params.wid, 12)
        }
        function test_offline_and_unsupported_actions_are_disabled() {
            controller.online = false
            deck.focusTarget(); deck.placeTarget("left")
            compare(controller.calls.length, 0)
            controller.online = true
            const next = scene.fixture(); next.describe.methods = ["windows.focus"]
            controller.state = next
            controller.query = "> space next"
            deck.runEntry()
            compare(controller.calls.length, 0)
            verify(deck.commandError.length > 0)
        }
        function test_receipts_follow_the_target_display_and_explain_dry_runs() {
            controller.actionFinished("spaces.focus", { status: "planned", target: "e+1", displayIndex: 1 })
            compare(deck.displayIndex, -1)
            verify(deck.statusNote.includes("no space changed"))
            controller.actionFinished("spaces.focus", { status: "ok", target: "e+1", displayIndex: 1 })
            compare(deck.displayIndex, 1)
            controller.actionFinished("windows.resolve", { window: { wid: 11 } })
            verify(deck.statusNote.includes("11 resolved"))
            controller.selectedWid = 12
            controller.actionFinished("windows.place", { status: "planned", target: { wid: 11 }, frame: { x: 0, y: 0, w: 800, h: 900 } })
            verify(deck.placementPlan === null)
        }
        function test_search_at_minimum_size() {
            scene.width = 560; scene.height = 420
            deck.focusSearch(); controller.query = "kitty"
            wait(50)
            const map = findChild(deck, "deckMap")
            verify(map.mapToItem(scene, 0, map.height).y < scene.height, "Search must leave the map inside the viewport")
            grabImage(scene).save("/tmp/lattices-flight-deck-search-narrow.png")
        }
        function test_render_at_wide_and_minimum_sizes() {
            const map = findChild(deck, "deckMap")
            verify(map.width > 800); verify(map.height > 400)
            grabImage(scene).save("/tmp/lattices-flight-deck-wide.png")
            scene.width = 560; scene.height = 420
            wait(50)
            verify(map.width >= 190); verify(map.height >= 100)
            verify(map.mapToItem(scene, 0, map.height).y <= scene.height)
            grabImage(scene).save("/tmp/lattices-flight-deck-narrow.png")
        }
        function test_render_preview_and_inspected_space() {
            deck.previewPlacement = true
            deck.placeTarget("right")
            controller.actionFinished("windows.place", { status: "planned", target: { wid: 11 }, frame: { x: 800, y: 0, w: 800, h: 900 } })
            wait(50)
            verify(deck.placementPlan !== null); compare(controller.calls[0].params.dryRun, true)
            grabImage(scene).save("/tmp/lattices-flight-deck-preview-wide.png")
            deck.previewPlacement = false
            keyClick(Qt.Key_BracketRight)
            wait(50)
            compare(deck.inspecting, true); compare(controller.calls.length, 1)
            grabImage(scene).save("/tmp/lattices-flight-deck-inspect-wide.png")
            scene.width = 560; scene.height = 420
            wait(50)
            const map = findChild(deck, "deckMap")
            verify(map.mapToItem(scene, 0, map.height).y <= scene.height)
            grabImage(scene).save("/tmp/lattices-flight-deck-inspect-narrow.png")
        }
    }
}
