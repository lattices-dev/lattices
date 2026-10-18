import QtQuick
import QtQuick.Layouts
import QtTest
import ".." as App
import "AppearanceFixtures.mjs" as Fixtures

// Theme.applyAppearance, and the shared chassis under a light palette, a
// tinted dark palette and the most translucent setting.
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
                capabilityHealth: { "windows.read": { available: true }, "windows.place": { available: false, reason: "Fixture" }, "spaces.read": { available: true } } }
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
        property var activity: [{ label: "Preview · Place window", detail: "Preview only · no changes", error: false, time: "10:32" }, { label: "Focus window", detail: "The host could not complete this action.", error: true, time: "10:30" }]
        property var hints: ({ groups: [{ id: "operator-console", title: "Operator Console", hints: [{ title: "Complete a command", shortcut: "Tab", detail: "" }, { title: "Preview an action", command: "lats window place <wid> right --dry-run", detail: "" }] }] })
        property var dialogParent: scene
        signal actionFinished(string method, var result)
        signal commandFinished(string id, string method, var result, bool failed, string message)
        function appName(raw) { return ({ kitty: "Terminal", chromium: "Chromium", obsidian: "Obsidian" })[raw] || raw }
        function call(method, params, id) { return true }
        function inspectWindow(entry) {}
        function newSession() {}
        function showSearch() {}
    }
    // Stands in for a wallpaper behind the translucent chassis.
    Rectangle {
        id: backdrop
        anchors.fill: parent; visible: false
        gradient: Gradient {
            orientation: Gradient.Horizontal
            GradientStop { position: 0; color: "#1d3f66" }
            GradientStop { position: 0.5; color: "#d9a05b" }
            GradientStop { position: 1; color: "#f4f1ea" }
        }
        Rectangle { x: 60; y: 420; width: 300; height: 300; radius: 150; color: "#ffffff" }
        Rectangle { x: 620; y: 90; width: 420; height: 240; color: "#0b0b0b" }
    }
    App.ShellChrome {
        id: chrome
        anchors.fill: parent
        controller: controller
        StackLayout {
            Layout.fillWidth: true; Layout.fillHeight: true
            currentIndex: ["Mission", "Console"].indexOf(controller.page)
            App.MissionControlPage { id: mission; controller: controller }
            App.OperatorConsolePage { id: operator; controller: controller }
        }
    }
    TestCase {
        name: "Appearance"
        when: windowShown
        function init() {
            App.Theme.resetAppearance()
            backdrop.visible = false
            controller.page = "Mission"; controller.online = true; controller.selectedWid = 11
            operator.entries = []
            wait(30)
        }
        function cleanupTestCase() { App.Theme.resetAppearance() }
        function fillConsole() {
            controller.page = "Console"; wait(30)
            operator.append("lats doctor", "Lattices doctor · archie · linux\n✓ Host connection: Reachable", "ok")
            operator.append("lats window place 12 right --dry-run", "Window 12 · right\nPreview only · no window moved.", "preview")
            operator.append("lats window focus 0xc", "Use an exact decimal window ID.", "error")
            operator.append("lats windows", "Waiting for the local host…", "running", "pending-1")
            wait(50)
        }
        function test_defaults_are_neutral_with_one_amber() {
            const neutral = color => Math.abs(color.r - color.g) < 0.02 && Math.abs(color.g - color.b) < 0.02
            for (const name of ["ink", "bg", "chassis", "surface", "hover", "border", "borderLit", "text", "body", "muted", "dim", "live", "liveSoft", "liveLine"])
                verify(neutral(App.Theme[name]), name + " carries no hue")
            verify(neutral(App.Theme.green) && neutral(App.Theme.greenSoft) && neutral(App.Theme.greenLine), "The earlier green names are neutral")
            verify(Qt.colorEqual(App.Theme.cyan, App.Theme.accent) && Qt.colorEqual(App.Theme.amber, App.Theme.caution))
            verify(App.Theme.accent.r > App.Theme.accent.g && App.Theme.accent.g > App.Theme.accent.b, "The accent is a warm amber")
            compare(App.Theme.chassisOpacity, 1); compare(App.Theme.glass.a, 1)
        }
        function test_apply_takes_valid_tokens_and_keeps_the_rest() {
            const text = String(App.Theme.text)
            const applied = App.Theme.applyAppearance({ tokens: { accent: "#3366ff", text: "white", bg: "#12", red: 7, unknown: "#ffffff" }, chassisOpacity: 0.2, mode: "sideways", font: "", mono: "Iosevka" })
            compare(applied, 1)
            verify(Qt.colorEqual(App.Theme.accent, "#3366ff")); verify(Qt.colorEqual(App.Theme.cyan, "#3366ff"), "Compatibility names follow the accent")
            compare(String(App.Theme.text), text, "A malformed color keeps the current one")
            compare(App.Theme.chassisOpacity, 0.88, "Translucency is clamped")
            compare(App.Theme.mode, "dark"); compare(App.Theme.font, "Adwaita Sans"); compare(App.Theme.mono, "Iosevka")
            compare(App.Theme.applyAppearance(null), 0); compare(App.Theme.applyAppearance("dark"), 0); compare(App.Theme.applyAppearance({ tokens: "#ffffff" }), 0)
            App.Theme.applyAppearance({ chassisOpacity: 9 }); compare(App.Theme.chassisOpacity, 1)
            App.Theme.applyAppearance({ chassisOpacity: "glass" }); compare(App.Theme.chassisOpacity, 1, "A non-number keeps the current value")
            App.Theme.resetAppearance()
            verify(Qt.colorEqual(App.Theme.accent, "#e68e0d")); compare(App.Theme.mono, "JetBrains Mono"); compare(App.Theme.source, "default")
        }
        function test_only_the_ground_is_translucent() {
            compare(App.Theme.framed, true, "The chassis supplies the ground")
            compare(App.Theme.pageGround.a, 0, "A framed page does not paint a second ground")
            compare(App.Theme.applyAppearance(Fixtures.glass), App.Theme.tokenNames.length)
            compare(App.Theme.themeName, "matte-black"); compare(App.Theme.source, "omarchy")
            fuzzyCompare(App.Theme.glass.a, 0.88, 0.005)
            verify(App.Theme.well.a < 1)
            for (const name of ["text", "body", "muted", "dim", "accent", "surface", "ink", "border"]) compare(App.Theme[name].a, 1, name + " stays opaque")
            compare(chrome.opacity, 1); compare(mission.opacity, 1)
            backdrop.visible = true; wait(50)
            grabImage(scene).save("/tmp/lattices-appearance-glass-mission.png")
            fillConsole()
            grabImage(scene).save("/tmp/lattices-appearance-glass-console.png")
        }
        function test_light_palette_stays_light_and_readable() {
            compare(App.Theme.applyAppearance(Fixtures.light), App.Theme.tokenNames.length)
            compare(App.Theme.mode, "light")
            verify(App.Theme.bg.hslLightness > 0.9 && App.Theme.text.hslLightness < 0.2)
            verify(App.Theme.red.r > App.Theme.red.g * 2, "Failure stays red when the palette's own red is gray")
            wait(50)
            grabImage(scene).save("/tmp/lattices-appearance-light-mission.png")
            fillConsole()
            grabImage(scene).save("/tmp/lattices-appearance-light-console.png")
        }
        function test_tinted_palette_keeps_its_accent() {
            compare(App.Theme.applyAppearance(Fixtures.tinted), App.Theme.tokenNames.length)
            verify(App.Theme.accent.b > App.Theme.accent.r, "The accent follows the theme")
            verify(App.Theme.caution.r > App.Theme.caution.b, "Caution keeps its own warm tone")
            wait(50)
            grabImage(scene).save("/tmp/lattices-appearance-tinted-mission.png")
            fillConsole()
            grabImage(scene).save("/tmp/lattices-appearance-tinted-console.png")
        }
    }
}
