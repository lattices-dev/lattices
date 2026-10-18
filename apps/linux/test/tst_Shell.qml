import QtQuick
import QtQuick.Layouts
import QtTest
import ".." as App

// The shared chassis around the instrument pages, at the default window
// size and at the app's real minimum (740 × 520 including chrome).
Item {
    id: scene
    width: 1160; height: 760
    function fixture() {
        const window = (wid, app, title, x, y, w, h, space) => ({ wid, app, title, frame: { x, y, w, h }, spaceIds: [space], displayIndex: 0, isOnScreen: space === 1, isFocused: wid === 11, isFloating: false, isFullscreen: false })
        const editor = window(11, "kitty", "nvim · src/forecast.rs", 0, 0, 790, 900, 1)
        const docs = window(12, "chromium", "Lattices docs", 810, 0, 790, 440, 1)
        const parked = Object.assign(window(19, "kitty", "cargo watch -x test", 0, 0, 800, 900, -1), { presence: "parked" })
        return {
            windows: [editor, docs, window(13, "kitty", "cargo watch -x test", 810, 460, 790, 440, 1), window(14, "obsidian", "Project notes", 0, 0, 1600, 900, 3)],
            displays: [{ displayIndex: 0, displayId: "DP-1", frame: { x: 0, y: 0, w: 1600, h: 900 }, currentSpaceId: 1, spaces: [{ id: 1, windowCount: 3 }, { id: 3, windowCount: 1 }, { id: 7, windowCount: 0 }] }],
            sessions: [{ name: "lattices-a93fa1", path: "/home/arach/dev/projects/lattices", windowCount: 2, panes: [{}, {}, {}] }],
            layers: [{ id: "build", label: "Build", active: true, entries: [{ windows: [editor, parked] }] }, { id: "docs", label: "Docs", active: false, entries: [{ windows: [docs] }] }],
            stage: { parked: [{ wid: 19, app: "kitty", title: "cargo watch -x test" }] }, virtual: { available: false, running: false },
            describe: { hostname: "archie", methods: ["windows.list", "windows.search", "spaces.list", "tmux.list", "layers.list", "windows.focus", "windows.place", "windows.resolve", "spaces.focus", "layers.activate", "layers.reveal", "sessions.launch"],
                capabilityHealth: { "windows.read": { available: true }, "windows.place": { available: true }, "spaces.read": { available: true }, "sessions.tmux": { available: true } } }
        }
    }
    QtObject {
        id: controller
        property var state: scene.fixture()
        property bool online: true
        property bool busy: false
        property bool compact: false
        property string page: "Mission"
        property string message: ""
        property string query: ""
        property double selectedWid: 11
        property string hostPort: "9399"
        readonly property int sidebarWidth: App.Theme.rail + (compact ? 0 : App.Theme.labels)
        readonly property bool needsHost: page === "Home" || page === "Overview" || page === "Layers" || page === "Mission"
        property var activity: [{ label: "Preview · Place window", detail: "Preview only · no changes", error: false, time: "10:32" }, { label: "List spaces", detail: "", error: false, time: "10:30" }]
        property var hints: ({ groups: [{ id: "operator-console", title: "Operator Console", hints: [{ title: "Complete a command", shortcut: "Tab", detail: "" }, { title: "Recall a command", shortcut: "↑ / ↓", detail: "" }, { title: "Preview an action", command: "lats window place <wid> right --dry-run", detail: "" }] }] })
        property string virtualFrame: ""
        property string virtualError: ""
        property bool virtualControl: false
        property var dialogParent: scene
        property var calls: []
        property int searches: 0
        signal actionFinished(string method, var result)
        signal commandFinished(string id, string method, var result, bool failed, string message)
        function appName(raw) { return ({ kitty: "Terminal", chromium: "Chromium", obsidian: "Obsidian" })[raw] || raw }
        function call(method, params, id) { calls = calls.concat([{ method, params, id: id || "" }]); return true }
        function inspectWindow(entry) { page = "Overview" }
        function newSession() {}
        function showSearch() { searches++ }
        function previewVirtual() {}
    }
    App.ShellChrome {
        id: chrome
        anchors.fill: parent
        controller: controller
        StackLayout {
            Layout.fillWidth: true; Layout.fillHeight: true
            currentIndex: ["Overview", "Mission", "Console"].indexOf(controller.page)
            App.OverviewPage { id: deck; controller: controller }
            App.MissionControlPage { id: mission; controller: controller }
            App.OperatorConsolePage { id: operator; controller: controller }
        }
    }
    TestCase {
        name: "Shell"
        when: windowShown
        function init() {
            scene.width = 1160; scene.height = 760
            controller.state = scene.fixture(); controller.page = "Mission"; controller.online = true; controller.busy = false
            controller.compact = false; controller.message = ""; controller.query = ""; controller.selectedWid = 11; controller.calls = []; controller.searches = 0
            operator.entries = []
            wait(40)
        }
        function test_one_title_follows_the_page() {
            const title = findChild(chrome, "shellTitle")
            compare(title.text, "Mission Control")
            mouseClick(findChild(chrome, "navConsole"))
            compare(controller.page, "Console"); compare(title.text, "Operator Console")
            mouseClick(findChild(chrome, "navOverview"))
            compare(controller.page, "Overview"); compare(title.text, "Flight Deck")
            mouseClick(findChild(chrome, "navSettings"))
            compare(controller.page, "Settings"); compare(title.text, "Settings")
            compare(controller.calls.length, 0, "Navigation never calls the host")
        }
        function test_brand_collapses_the_rail_and_link_state_is_truthful() {
            const content = findChild(chrome, "shellContent")
            const expanded = content.width
            mouseClick(findChild(chrome, "shellBrand"))
            compare(controller.compact, true); wait(30)
            compare(content.width, expanded + App.Theme.labels)
            const link = findChild(chrome, "shellLink")
            compare(link.text, "LIVE")
            controller.busy = true; compare(link.text, "WORKING")
            controller.busy = false; controller.online = false; compare(link.text, "OFFLINE")
            controller.message = "Could not reach the local host."
            verify(findChild(chrome, "shellMessage").visible)
        }
        function test_minimum_window_keeps_the_tested_content_size() {
            scene.width = 740; scene.height = 520; wait(50)
            const content = findChild(chrome, "shellContent")
            verify(content.width >= 560, "Content is " + content.width + " wide at the minimum window")
            verify(content.height >= 420, "Content is " + content.height + " tall at the minimum window")
            const table = findChild(mission, "missionTable")
            verify(table.height >= 104, "Two inventory rows fit at the minimum window")
            grabImage(scene).save("/tmp/lattices-shell-mission-min.png")
            controller.page = "Overview"; wait(50)
            const map = findChild(deck, "deckMap")
            verify(map.width >= 190); verify(map.height >= 100)
            verify(map.mapToItem(scene, 0, map.height).y <= scene.height)
            grabImage(scene).save("/tmp/lattices-shell-flight-deck-min.png")
            controller.page = "Console"; wait(50)
            const input = findChild(operator, "consoleInput")
            verify(input.mapToItem(scene, 0, input.height).y <= scene.height)
            grabImage(scene).save("/tmp/lattices-shell-console-min.png")
        }
        function test_render_default_window() {
            grabImage(scene).save("/tmp/lattices-shell-mission-wide.png")
            controller.page = "Overview"; wait(50)
            grabImage(scene).save("/tmp/lattices-shell-flight-deck-wide.png")
            controller.page = "Console"; wait(50)
            operator.append("lats doctor", "Lattices doctor · archie · linux\n✓ Host connection: Reachable\n✓ Window inventory: windows.read", "ok")
            operator.append("lats window place 12 right --dry-run", "Window 12 · right\nFrame 800, 0 · 800 × 900\nPreview only · no window moved.", "preview")
            operator.append("lats window focus 0xc", "Use an exact decimal window ID.", "error")
            wait(50)
            grabImage(scene).save("/tmp/lattices-shell-console-wide.png")
            controller.compact = true; controller.online = false; controller.page = "Console"; wait(50)
            grabImage(scene).save("/tmp/lattices-shell-console-compact-offline.png")
        }
    }
}
