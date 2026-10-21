import QtQuick
import QtTest
import ".." as App

Item {
    id: scene
    width: 1440; height: 900
    function fixture() {
        const window = (wid, app, title, space) => ({ wid, app, title, frame: { x: 0, y: 0, w: 800, h: 900 }, spaceIds: [space], displayIndex: 0, isOnScreen: space === 1, isFocused: wid === 11, isFloating: false, isFullscreen: false })
        const editor = window(11, "kitty", "nvim · src/forecast.rs", 1)
        const docs = window(12, "chromium", "Lattices docs", 1)
        const parked = Object.assign(window(19, "kitty", "cargo watch -x test", -1), { presence: "parked" })
        return {
            windows: [editor, docs, window(14, "obsidian", "Project notes", 3)],
            displays: [{ displayIndex: 0, displayId: "DP-1", frame: { x: 0, y: 0, w: 1600, h: 900 }, currentSpaceId: 1, spaces: [{ id: 1, windowCount: 2 }, { id: 3, windowCount: 1 }, { id: 7, windowCount: 0 }] }],
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
        property string page: "Mission"
        property string query: ""
        property double selectedWid: 11
        property var activity: [{ label: "Preview · Place window", detail: "Preview only · no changes", error: false, time: "10:32" }, { label: "List spaces", detail: "", error: false, time: "10:30" }]
        property var hints: ({ groups: [{ id: "operator-console", title: "Operator Console", hints: [{ title: "Complete a command", shortcut: "Tab", detail: "Complete Lattices commands" }, { title: "Recall a command", shortcut: "↑ / ↓", detail: "Step through history" }, { title: "Clear the transcript", shortcut: "Ctrl L", detail: "Keep pending commands" }] }] })
        property string virtualFrame: ""
        property string virtualError: ""
        property bool virtualControl: false
        property var dialogParent: scene
        property var calls: []
        property int inspectedWid: -1
        property int newSessions: 0
        signal actionFinished(string method, var result)
        signal commandFinished(string id, string method, var result, bool failed, string message)
        function appName(raw) { return ({ kitty: "Terminal", chromium: "Chromium", obsidian: "Obsidian" })[raw] || raw }
        function call(method, params, id) { calls = calls.concat([{ method, params, id: id || "" }]); return true }
        function inspectWindow(entry) { inspectedWid = entry.wid; page = "Overview" }
        function newSession() { newSessions++ }
        function previewVirtual() {}
    }
    App.OverviewPage { id: deck; anchors.fill: parent; controller: controller; visible: controller.page === "Overview" }
    App.MissionControlPage { id: mission; anchors.fill: parent; controller: controller; visible: controller.page === "Mission" }
    App.OperatorConsolePage { id: operator; anchors.fill: parent; controller: controller; visible: controller.page === "Console" }
    TestCase {
        name: "DesktopViews"
        when: windowShown
        function init() {
            scene.width = 1440; scene.height = 900
            controller.page = "Mission"; controller.online = true; controller.busy = false; controller.query = ""; controller.state = scene.fixture(); controller.selectedWid = 11; controller.calls = []; controller.inspectedWid = -1
            mission.spaceFilter = -1
            operator.entries = []; operator.history = []; operator.historyIndex = -1; operator.serial = 0
            mission.focusTable()
            wait(40)
        }
        function test_mission_filter_and_parked_window_cannot_mutate_focus() {
            compare(mission.inventory.length, 4)
            mission.spaceFilter = 3
            wait(30)
            compare(mission.windows.length, 1); compare(controller.selectedWid, 14)
            compare(controller.calls.length, 0)
            controller.state = scene.fixture()
            wait(40)
            compare(controller.selectedWid, 14, "Hidden Flight Deck must not steal Mission's selection")
            mission.spaceFilter = -1
            wait(30)
            controller.selectedWid = 19
            mission.focusTarget()
            compare(controller.calls.length, 0)
            verify(!mission.canFocus)
        }
        function test_mission_navigation_and_explicit_space_switch() {
            keyClick(Qt.Key_Down)
            verify(controller.selectedWid !== 11)
            compare(controller.calls.length, 0)
            mission.spaceFilter = 3; wait(30)
            mouseClick(findChild(mission, "missionGoSpace"))
            compare(controller.calls[0].method, "spaces.focus")
            compare(controller.calls[0].params.workspace, 3)
            mission.inspectTarget()
            compare(controller.inspectedWid, 14)
        }
        function test_console_correlates_results_and_retains_pending_when_cleared() {
            controller.page = "Console"; wait(30)
            operator.prepare("lats windows"); operator.submit()
            compare(controller.calls.length, 1)
            const call = controller.calls[0]
            verify(call.id !== "")
            controller.commandFinished("other-command", call.method, [], false, "")
            compare(operator.entries[0].status, "running")
            operator.clearTranscript()
            compare(operator.entries.length, 1)
            controller.commandFinished(call.id, call.method, controller.state.windows, false, "")
            compare(operator.entries[0].status, "ok")
            verify(operator.entries[0].output.includes("nvim"))
            controller.commandFinished(call.id, call.method, [], false, "")
            verify(operator.entries[0].output.includes("nvim"), "Duplicate completion must not overwrite a finished entry")
        }
        function test_console_read_commands_from_keyboard_and_copied_spaces() {
            controller.page = "Console"; wait(30)
            operator.prepare("lats windows"); keyClick(Qt.Key_Return)
            compare(controller.calls[0].method, "windows.list")
            operator.prepare("lats\u200bwindows"); keyClick(Qt.Key_Return)
            compare(controller.calls[1].method, "windows.list")
            operator.prepare("lats\u00a0spaces"); keyClick(Qt.Key_Return)
            compare(controller.calls[2].method, "spaces.list")
        }
        function test_console_completion_history_and_draft() {
            controller.page = "Console"; wait(30)
            operator.prepare("lats doc"); keyClick(Qt.Key_Tab)
            compare(findChild(operator, "consoleInput").text, "lats doctor")
            operator.prepare("help"); keyClick(Qt.Key_Return)
            compare(operator.entries.length, 1); compare(operator.entries[0].status, "ok")
            operator.prepare("draft command"); keyClick(Qt.Key_Up)
            compare(findChild(operator, "consoleInput").text, "help")
            keyClick(Qt.Key_Down)
            compare(findChild(operator, "consoleInput").text, "draft command")
        }
        function test_console_json_receipt_and_local_status() {
            controller.page = "Console"; wait(30)
            operator.prepare("lats space next --dry-run --json"); operator.submit()
            compare(controller.calls[0].params.workspace, "e+1")
            compare(controller.calls[0].params.dryRun, true)
            const receipt = { status: "planned", target: "e+1", currentSpaceId: 1 }
            controller.commandFinished(controller.calls[0].id, "spaces.focus", receipt, false, "")
            compare(operator.entries[0].status, "preview")
            compare(JSON.parse(operator.entries[0].output).target, "e+1")
            operator.prepare("lats app status --json"); operator.submit()
            compare(JSON.parse(operator.entries[1].output).online, true)
        }
        function test_console_offline_read_diagnosis_and_exact_preview() {
            controller.page = "Console"; controller.online = false; wait(30)
            operator.prepare("lats windows"); operator.submit()
            compare(controller.calls.length, 0); compare(operator.entries[0].status, "error")
            operator.prepare("lats doctor"); operator.submit()
            compare(controller.calls[0].method, "app.doctor")
            controller.commandFinished(controller.calls[0].id, "app.doctor", { report: { ok: false, checks: [{ state: "fail", name: "Host connection", detail: "Offline" }] } }, false, "")
            compare(operator.entries[1].status, "error")
            verify(operator.entries[1].output.includes("Host connection"))
            controller.online = true
            operator.prepare("lats window place 12 right --dry-run"); operator.submit()
            compare(controller.calls[1].params.wid, 12); compare(controller.calls[1].params.dryRun, true)
            controller.commandFinished(controller.calls[1].id, "windows.place", { status: "planned", target: { wid: 12 }, placement: "right", frame: { x: 800, y: 0, w: 800, h: 900 } }, false, "")
            compare(operator.entries[2].status, "preview")
            verify(operator.entries[2].output.includes("no window moved"))
        }
        function test_render_wide_and_narrow() {
            grabImage(scene).save("/tmp/lattices-mission-wide.png")
            scene.width = 560; scene.height = 420; wait(50)
            const table = findChild(mission, "missionTable")
            verify(table.height >= 104, "Two inventory rows fit at the minimum content size")
            verify(table.mapToItem(scene, 0, table.height).y <= scene.height)
            grabImage(scene).save("/tmp/lattices-mission-narrow.png")
            scene.width = 1440; scene.height = 900; controller.page = "Console"; wait(30)
            operator.append("lats doctor", "Lattices doctor · archie · linux\n✓ Host connection: Reachable\n✓ Window inventory: windows.read\n✓ Window placement: windows.place\n✓ Spaces: spaces.read\n✓ Terminal sessions: sessions.tmux", "ok")
            operator.append("lats spaces", "DP-1\n  ● 1 · 2 windows\n  ○ 3 · 1 windows\n  ○ 7 · 0 windows", "ok")
            operator.append("lats window place 12 right --dry-run", "Window 12 · right\nFrame 800, 0 · 800 × 900\nPreview only · no window moved.", "preview")
            wait(50)
            grabImage(scene).save("/tmp/lattices-console-wide.png")
            scene.width = 560; scene.height = 420; wait(50)
            const input = findChild(operator, "consoleInput")
            verify(input.mapToItem(scene, 0, input.height).y <= scene.height)
            verify(findChild(operator, "consoleTranscript").height > 180)
            grabImage(scene).save("/tmp/lattices-console-narrow.png")
        }
    }
}
