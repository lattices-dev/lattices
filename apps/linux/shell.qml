pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io

ShellRoot {
    id: root
    property var state: ({ windows: [], displays: [], sessions: [], clients: [], pending: [], layers: [], stage: { parked: [] }, layersSupported: false, describe: {} })
    readonly property var dialogParent: window.contentItem
    property bool online: false
    property bool busy: false
    property bool compact: false
    property string page: ["Home", "Overview", "Layers", "Activity", "Settings", "Hints", "Mission", "Console"].includes(Quickshell.env("LATTICES_LINUX_PAGE")) ? Quickshell.env("LATTICES_LINUX_PAGE") : "Home"
    property var hints: ({ groups: [] })
    property string message: "Connecting to the local host…"
    property string query: ""
    property double selectedWid: -1
    property var selectedWindow: state.windows.find(w => w.wid === selectedWid) || null
    property alias virtualFrame: virtualPreview.frame
    property alias virtualError: virtualPreview.error
    property alias virtualViewerVisible: virtualPreview.shown
    property bool virtualControl: false
    property var activity: []
    property string pendingMethod: ""
    property string pendingLabel: ""
    property string pendingRequestId: ""
    property int requestSequence: 0
    signal actionFinished(string method, var result)
    signal commandFinished(string id, string method, var result, bool failed, string message)
    readonly property bool needsHost: page === "Home" || page === "Overview" || page === "Layers" || page === "Mission"
    readonly property int sidebarWidth: Theme.rail + (compact ? 0 : Theme.labels)
    readonly property string hostPort: Quickshell.env("LATTICES_LINUX_PORT") || "9399"

    function appName(raw) {
        const entry = DesktopEntries.heuristicLookup(raw)
        return entry ? entry.name : raw
    }
    function log(label, detail, error) {
        activity = [{ label: label, detail: detail || "", error: !!error, time: new Date().toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" }) }].concat(activity).slice(0, 50)
    }
    function finish(error, detail, result) {
        if (pendingRequestId) commandFinished(pendingRequestId, pendingMethod, result ?? null, !!error, detail || "")
        if (pendingLabel) log(pendingLabel, detail, error)
        pendingMethod = ""
        pendingLabel = ""
        pendingRequestId = ""
        busy = false
    }
    function call(method, params, requestId) {
        if (!backend.running || busy || (!online && method !== "refresh" && method !== "host.start" && method !== "app.doctor")) return false
        const labels = { "computer.virtual.start": "Start virtual space", "computer.virtual.stop": "Stop virtual space", "computer.virtual.launch": "Open virtual app", "computer.click": "Click in virtual space", "computer.scroll": "Scroll virtual space", "computer.pressKey": "Press virtual key", "computer.typeText": "Type in virtual space", "layers.create": "Create layer", "layers.assign": "Add windows to layer", "layers.unassign": "Remove windows from layer", "layers.rename": "Rename layer", "layers.delete": "Delete layer", "layers.layout": "Set layer layout", "layers.activate": "Switch layer", "layers.reveal": "Show all windows", "refresh": "Refresh local host", "host.start": "Start local host", "windows.focus": "Focus window", "windows.place": "Place window", "sessions.launch": "Start session", "clients.approve": "Approve device", "bridge.pairing.approve": "Approve device", "clients.deny": "Deny pairing", "bridge.pairing.deny": "Deny pairing", "clients.revoke": "Revoke device", "bridge.devices.revoke": "Revoke device" }
        pendingMethod = method
        pendingRequestId = requestId || "app-" + Date.now() + "-" + (++requestSequence)
        pendingLabel = labels[method] || "Local action"
        if (method === "spaces.focus") pendingLabel = "Switch space"
        if (method === "windows.resolve") pendingLabel = "Preview focus"
        if (["app.doctor", "windows.list", "windows.search", "spaces.list", "tmux.list", "layers.list"].includes(method)) pendingLabel = ({ "app.doctor": "Read host health", "windows.list": "List windows", "windows.search": "Search windows", "spaces.list": "List spaces", "tmux.list": "List sessions", "layers.list": "List layers" })[method]
        if (params?.dryRun) pendingLabel = "Preview · " + pendingLabel
        if (method.startsWith("computer.")) virtualError = ""
        if (params && params.placement) pendingLabel += " · " + params.placement
        busy = true
        message = ""
        backend.write(JSON.stringify({ method: method, params: params || {}, requestId: pendingRequestId }) + "\n")
        return true
    }
    function decide(request, approve) {
        call(request.kind === "daemon" ? (approve ? "clients.approve" : "clients.deny") : (approve ? "bridge.pairing.approve" : "bridge.pairing.deny"),
            request.kind === "daemon" ? { clientID: request.deviceID } : { deviceID: request.deviceID })
    }
    function previewVirtual() { if (backend.running && online) backend.write(JSON.stringify({ method: "virtual.preview" }) + "\n") }
    function showVirtualViewer(action) { return virtualPreview.setVisibility(action === "on" ? "show" : action === "off" ? "hide" : action || "show") }
    function openVirtualControls() {
        overview.virtualView = true
        root.openPage("Overview")
    }
    function newLayer() { page = "Layers"; Qt.callLater(() => layersPage.create()) }
    function newSession() { if (online && !busy) sessionDialog.open() }
    function showSearch() {
        if (page === "Console") { Qt.callLater(() => consolePage.focusInput()); return }
        if (page === "Mission") { Qt.callLater(() => missionPage.focusSearch()); return }
        page = "Overview"
        Qt.callLater(() => overview.focusSearch())
    }
    function inspectWindow(entry) { page = "Overview"; Qt.callLater(() => overview.selectWindow(entry)) }
    function openPage(nextPage) {
        if (!["Home", "Overview", "Layers", "Activity", "Settings", "Hints", "Mission", "Console"].includes(nextPage)) return
        root.page = nextPage
        window.visible = true
        if (root.online) root.call("windows.focus", { app: "org.quickshell", title: "Lattices" })
    }

    Process {
        id: backend
        command: [Quickshell.env("LATTICES_LINUX_BUN") || "bun", Quickshell.shellDir + "/backend.ts"]
        running: true
        stdinEnabled: true
        stdout: SplitParser {
            onRead: data => {
                try {
                    const update = JSON.parse(data)
                    if (update.type === "appearance") {
                        Theme.applyAppearance(update.appearance)
                    } else if (update.type === "hints") {
                        root.hints = update.pack
                    } else if (update.type === "virtual.frame") {
                        if (!root.state.virtual?.running) return
                        virtualPreview.acceptFrame(update.image)
                    } else if (update.type === "virtual.error") {
                        if (!root.state.virtual?.running) return
                        virtualPreview.acceptError(update.message)
                    } else if (update.type === "state") {
                        root.state = update
                        if (!update.virtual?.running) { root.virtualFrame = ""; root.virtualControl = false }
                        if (!root.online || root.pendingMethod === "refresh") root.message = ""
                        root.online = true
                        if (root.pendingMethod === "refresh") root.finish(false, "")
                    } else if (update.type === "offline") {
                        if (root.online && !root.pendingLabel) root.log("Local host disconnected", update.message, true)
                        root.online = false
                        if (root.pendingMethod !== "app.doctor") root.finish(true, update.message)
                        root.message = update.message
                    } else if (update.type === "error") {
                        if (!root.pendingRequestId || update.requestId !== root.pendingRequestId) return
                        root.finish(true, update.message)
                        root.message = update.message
                    } else if (update.type === "done") {
                        if (!root.pendingRequestId || update.requestId !== root.pendingRequestId) return
                        if (update.result === false || update.result?.ok === false) {
                            root.finish(true, "The host could not complete this action.", update.result)
                            root.message = "The host could not complete this action."
                            return
                        }
                        root.actionFinished(root.pendingMethod, update.result)
                        if (root.pendingMethod === "layers.create" && update.result) { layersPage.selectedId = update.result.id; root.page = "Layers" }
                        const held = update.result?.held || []
                        root.finish(false, held.length ? "A written rule still holds " + held.length + " windows" : update.result?.status === "planned" ? "Preview only · no changes" : "", update.result)
                        if (held.length) root.message = "A written rule still holds this window. Edit the rule in workspace.json to remove it."
                    }
                } catch (e) { root.message = "Could not read the host response."; root.finish(true, root.message) }
            }
        }
        stderr: SplitParser { onRead: data => console.warn(data) }
        onRunningChanged: if (!running) { root.online = false; root.finish(true, "App connection stopped"); root.message = "The app connection stopped. Reopen Lattices to reconnect." }
    }

    IpcHandler {
        target: "lattices"
        // Keep show for older callers; recent Quickshell CLI versions reserve it.
        function show(page: string): void { root.openPage(page) }
        function showPage(page: string): void { root.openPage(page) }
        function viewer(action: string): bool { return root.showVirtualViewer(action) }
        function runCommand(command: string): bool {
            if (root.busy) return false
            root.page = "Console"
            window.visible = true
            consolePage.prepare(command)
            consolePage.submit()
            return true
        }
        function canvas(mode: string): bool {
            if (!["all", "space", "current"].includes(mode)) return false
            root.page = "Overview"
            overview.virtualView = false
            Qt.callLater(() => {
                if (mode === "all") overview.workspaceCanvas.fitAll()
                else if (mode === "current") overview.inspectSpace(overview.display?.currentSpaceId || -1)
                else overview.workspaceCanvas.fitSpace(overview.spaceId)
            })
            return true
        }
        function state(): string { return JSON.stringify({ page: root.page, online: root.online, hintGroups: root.hints.groups.length,
            appearance: { source: Theme.source, theme: Theme.themeName, mode: Theme.mode, accent: String(Theme.accent), opacity: Theme.chassisOpacity },
            flightDeck: { space: overview.spaceId, inspecting: overview.inspecting, windows: overview.windows.length, selectedWid: overview.selected?.wid ?? null, command: overview.selectedCommand,
                canvas: { mode: overview.workspaceCanvas.fitMode, spaces: overview.workspaceCanvas.sheets.length, zoomPercent: overview.workspaceCanvas.zoomPercent } },
            mission: { windows: missionPage.windows.length, spaces: missionPage.spaces.length, selectedWid: missionPage.selected?.wid ?? null },
            viewer: { visible: virtualPreview.shown, watching: virtualPreview.watching, fresh: virtualPreview.fresh, framesReceived: virtualPreview.framesReceived, width: virtualViewer.width, height: virtualViewer.height },
            console: { entries: consolePage.entries.length, running: consolePage.entries.filter(entry => entry.status === "running").length,
                lastStatus: consolePage.entries.length ? consolePage.entries[consolePage.entries.length - 1].status : null } }) }
        function quit(): void { Qt.quit() }
    }

    VirtualPreviewSession {
        id: virtualPreview
        online: root.online
        space: root.state.virtual || ({ running: false })
        embeddedVisible: window.visible && root.page === "Overview" && overview.virtualView
        shown: Quickshell.env("LATTICES_LINUX_VIEWER") === "show"
        onCaptureRequested: root.previewVirtual()
    }
    VirtualViewerWindow { id: virtualViewer; session: virtualPreview; onControlsRequested: root.openVirtualControls() }

    FloatingWindow {
        id: window
        title: "Lattices"
        visible: Quickshell.env("LATTICES_LINUX_VIEWER") !== "show"
        implicitWidth: 1160
        implicitHeight: 760
        minimumSize: Qt.size(740, 520)
        color: "transparent"
        onClosed: if (!virtualPreview.shown) Qt.quit()

        Shortcut { sequence: "Ctrl+K"; onActivated: root.showSearch() }
        Shortcut { sequence: "Ctrl+1"; onActivated: root.page = "Home" }
        Shortcut { sequence: "Ctrl+2"; onActivated: root.page = "Overview" }
        Shortcut { sequence: "Ctrl+3"; onActivated: root.page = "Layers" }

        Shortcut { sequence: "Ctrl+4"; onActivated: root.page = "Activity" }
        Shortcut { sequence: "Ctrl+5"; onActivated: root.page = "Hints" }
        Shortcut { sequence: "F1"; onActivated: root.page = "Hints" }
        Shortcut { sequence: "Ctrl+6"; onActivated: root.page = "Mission" }
        Shortcut { sequence: "Ctrl+7"; onActivated: root.page = "Console" }

        ShellChrome {
            id: appContent
            anchors.fill: parent
            controller: root
            ColumnLayout {
                visible: !root.online && root.needsHost; Layout.fillWidth: true; Layout.fillHeight: true; spacing: 10
                Item { Layout.fillHeight: true }
                Symbol { name: "terminal"; tint: Theme.dim; Layout.alignment: Qt.AlignHCenter; Layout.preferredWidth: 28; Layout.preferredHeight: 28 }
                DeckLabel { text: "HOST OFFLINE"; color: Theme.amber; Layout.alignment: Qt.AlignHCenter; Layout.topMargin: 4 }
                AppText { text: "Local host is offline"; font.pixelSize: 17; font.weight: Font.DemiBold; Layout.alignment: Qt.AlignHCenter }
                AppText { text: "Start the local host, then reconnect."; color: Theme.muted; Layout.alignment: Qt.AlignHCenter }
                ActionButton { text: "Start Host"; accent: true; enabled: !root.busy; Layout.alignment: Qt.AlignHCenter; Layout.topMargin: 6; onClicked: root.call("host.start") }
                Item { Layout.fillHeight: true }
            }
            StackLayout {
                visible: root.online || !root.needsHost; Layout.fillWidth: true; Layout.fillHeight: true
                currentIndex: ["Home", "Overview", "Layers", "Activity", "Settings", "Hints", "Mission", "Console"].indexOf(root.page)
                HomePage { controller: root }
                OverviewPage { id: overview; controller: root }
                LayersPage { id: layersPage; controller: root }
                ActivityPage { controller: root }
                SettingsPage { controller: root }
                HintsPage { controller: root }
                MissionControlPage { id: missionPage; controller: root }
                OperatorConsolePage { id: consolePage; controller: root }
            }
        }
    }

    Dialog {
        id: sessionDialog
        parent: window.contentItem
        anchors.centerIn: parent
        width: 410; modal: true; padding: 20
        onOpened: { projectPath.forceActiveFocus(); projectPath.selectAll() }
        background: Rectangle { color: Theme.surface; radius: 6; border.color: Theme.borderLit }
        contentItem: ColumnLayout {
            spacing: 16
            AppText { text: "New session"; font.pixelSize: 15; font.weight: Font.DemiBold }
            AppText { text: "Project directory"; color: Theme.muted }
            InputField { id: projectPath; Layout.fillWidth: true; placeholderText: "~/dev/my-project"; onAccepted: if (text.trim() && root.online && !root.busy) { sessionDialog.close(); root.call("sessions.launch", { path: text.trim() }) } }
            RowLayout {
                Item { Layout.fillWidth: true }
                ActionButton { text: "Cancel"; onClicked: sessionDialog.close() }
                ActionButton { text: "Start session"; accent: true; enabled: projectPath.text.trim() !== "" && root.online && !root.busy; onClicked: { sessionDialog.close(); root.call("sessions.launch", { path: projectPath.text.trim() }) } }
            }
        }
    }
}
