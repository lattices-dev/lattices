pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "FlightCanvasModel.mjs" as World

Rectangle {
    id: view
    required property var controller
    required property var display
    required property var windows
    required property int spaceId
    property string query: ""
    property var placementPlan: null
    property bool panHeld: false
    property var camera: ({ zoom: 1, x: 0, y: 0 })
    property bool motionEnabled: true
    property var motionFrom: camera
    property point motionAnchor: Qt.point(0, 0)
    property real motionProgress: 1
    property string motionKind: ""
    readonly property bool motionRunning: cameraMotion.running
    readonly property var visualCamera: motionProgress >= 1 ? camera : World.interpolateCamera(motionFrom, camera, motionProgress, motionAnchor.x, motionAnchor.y)
    property point panLastDelta: Qt.point(0, 0)
    property point panVelocity: Qt.point(0, 0)
    property real panLastTime: 0
    property int panSamples: 0
    property string fitMode: "space"
    property bool initialized: false
    property real previousWidth: 0
    property real previousHeight: 0
    property var previousSheets: []
    readonly property var sheets: World.workspaceSheets(display, windows, query)
    readonly property string displayKey: display ? [display.displayIndex, display.frame.x, display.frame.y, display.frame.w, display.frame.h].join("/") : ""
    readonly property var bounds: World.worldBounds(sheets)
    readonly property real overviewZoom: World.fitCamera(bounds, width, height).zoom
    readonly property real detailZoom: World.fitCamera(World.sheetBounds(sheets[0]), width, height).zoom
    readonly property bool showingOverview: visualCamera.zoom < detailZoom * 0.78
    readonly property int zoomPercent: Math.round(visualCamera.zoom / Math.max(0.00001, detailZoom) * 100)
    signal spaceSelected(int id)
    signal windowSelected(int id, real wid)
    signal windowActivated(int id, real wid)

    color: Theme.ink; radius: 4; clip: true
    border.color: activeFocus ? Theme.cyanLine : Theme.borderLit
    Accessible.name: "Workspace canvas, " + sheets.length + " spaces. Scroll to zoom; drag empty canvas to pan."

    NumberAnimation { id: cameraMotion; target: view; property: "motionProgress"; from: 0; to: 1; duration: 280; easing.type: Easing.OutCubic }
    function setCamera(next, animated, duration, anchorX, anchorY, kind) {
        if (Math.abs(next.zoom - camera.zoom) < 0.00000001 && Math.abs(next.x - camera.x) < 0.0001 && Math.abs(next.y - camera.y) < 0.0001) return
        const origin = visualCamera
        cameraMotion.stop()
        motionFrom = origin
        motionAnchor = Qt.point(anchorX ?? width / 2, anchorY ?? height / 2)
        motionKind = kind || "frame"
        camera = next
        if (motionEnabled && initialized && animated) {
            motionProgress = 0
            cameraMotion.duration = duration || 280
            cameraMotion.restart()
        } else motionProgress = 1
    }
    function interruptMotion() {
        const origin = visualCamera
        cameraMotion.stop(); camera = origin; motionProgress = 1; motionKind = ""
        return origin
    }
    function beginPanMotion() { panLastDelta = Qt.point(0, 0); panVelocity = Qt.point(0, 0); panLastTime = Date.now(); panSamples = 0 }
    function recordPanMotion(x, y) {
        const now = Date.now(), dt = now - panLastTime
        if (dt >= 4) {
            panVelocity = Qt.point(panVelocity.x * 0.65 + (x - panLastDelta.x) / dt * 0.35, panVelocity.y * 0.65 + (y - panLastDelta.y) / dt * 0.35)
            panSamples++
            panLastDelta = Qt.point(x, y); panLastTime = now
        }
    }
    function finishPanMotion() {
        if (!motionEnabled || panSamples < 2 || Date.now() - panLastTime > 80) return
        const dx = Math.max(-140, Math.min(140, panVelocity.x * 75)), dy = Math.max(-140, Math.min(140, panVelocity.y * 75))
        if (Math.abs(dx) + Math.abs(dy) < 10) return
        setCamera({ zoom: camera.zoom, x: camera.x + dx, y: camera.y + dy }, true, 220, width / 2, height / 2, "coast")
    }
    onMotionEnabledChanged: if (!motionEnabled) interruptMotion()
    function fitAll() {
        if (!sheets.length || width <= 0 || height <= 0) return
        setCamera(World.fitCamera(bounds, width, height), true, 320)
        fitMode = "all"; initialized = true; previousWidth = width; previousHeight = height
    }
    function fitSpace(id) {
        const sheet = sheets.find(s => s.id === id) || sheets[0]
        if (!sheet || width <= 0 || height <= 0) return
        setCamera(World.fitCamera(World.sheetBounds(sheet), width, height), true, 320)
        fitMode = "space"; initialized = true; previousWidth = width; previousHeight = height
    }
    function zoomBy(factor, x, y) {
        if (!sheets.length) return
        if (!initialized) fitSpace(spaceId)
        const ax = x ?? width / 2, ay = y ?? height / 2
        if (motionRunning && (motionKind !== "zoom" || Math.abs(ax - motionAnchor.x) > 1 || Math.abs(ay - motionAnchor.y) > 1)) interruptMotion()
        setCamera(World.zoomCamera(camera, factor, ax, ay, overviewZoom * 0.45, detailZoom * 5), true, 150, ax, ay, "zoom")
        fitMode = "free"
    }
    function panBy(x, y) {
        if (motionRunning && motionKind !== "pan") interruptMotion()
        setCamera({ zoom: camera.zoom, x: camera.x + x, y: camera.y + y }, true, 120, width / 2, height / 2, "pan"); fitMode = "free"
    }
    function layoutChanged() {
        if (!initialized || fitMode === "space") fitSpace(spaceId)
        else if (fitMode === "all") fitAll()
        else {
            setCamera(World.resizedCamera(visualCamera, previousWidth, previousHeight, width, height), false)
            previousWidth = width; previousHeight = height
        }
    }
    function reconcileSheets() {
        if (initialized && fitMode === "free" && previousSheets.map(s => s.id).join(",") !== sheets.map(s => s.id).join(",")) setCamera(World.reconcileCamera(visualCamera, previousSheets, sheets, width, spaceId), false)
        previousSheets = sheets.map(s => ({ id: s.id, x: s.x, y: s.y, w: s.w, h: s.h }))
        if (!initialized || fitMode !== "free") Qt.callLater(layoutChanged)
    }
    onWidthChanged: Qt.callLater(layoutChanged)
    onHeightChanged: Qt.callLater(layoutChanged)
    onSheetsChanged: reconcileSheets()
    onDisplayKeyChanged: { initialized = false; fitMode = "space"; Qt.callLater(layoutChanged) }
    onSpaceIdChanged: if (fitMode === "space") Qt.callLater(layoutChanged)
    onActiveFocusChanged: if (!activeFocus) panHeld = false
    Component.onCompleted: Qt.callLater(layoutChanged)

    LatticeGrid { anchors.fill: parent; anchors.margins: 1; ink: Theme.border }
    MouseArea {
        id: background
        anchors.fill: parent
        property point pressPoint: Qt.point(0, 0)
        property var startCamera: null
        property bool moved: false
        cursorShape: pressed || view.panHeld ? Qt.ClosedHandCursor : Qt.OpenHandCursor
        onPressed: mouse => { pressPoint = Qt.point(mouse.x, mouse.y); startCamera = view.interruptMotion(); view.beginPanMotion(); moved = false; view.forceActiveFocus() }
        onPositionChanged: mouse => {
            if (!pressed) return
            const dx = mouse.x - pressPoint.x, dy = mouse.y - pressPoint.y
            if (Math.abs(dx) + Math.abs(dy) > 3) moved = true
            if (moved) { view.setCamera({ zoom: startCamera.zoom, x: startCamera.x + dx, y: startCamera.y + dy }, false); view.recordPanMotion(dx, dy); view.fitMode = "free" }
        }
        onReleased: if (moved) view.finishPanMotion()
    }
    Repeater {
        model: view.sheets
        Item {
            id: sheet
            required property var modelData
            readonly property bool chosen: modelData.id === view.spaceId
            readonly property bool inViewport: x + width > 0 && x < view.width && y + height > 0 && y < view.height
            x: view.visualCamera.x + modelData.x * view.visualCamera.zoom
            y: view.visualCamera.y + modelData.y * view.visualCamera.zoom
            width: modelData.w * view.visualCamera.zoom; height: modelData.h * view.visualCamera.zoom
            visible: inViewport
            Rectangle {
                anchors.fill: parent; radius: 3
                color: Theme.bg; border.color: sheet.chosen ? Theme.cyanLine : Theme.borderLit
                MouseArea {
                    anchors.fill: parent
                    property point pressPoint: Qt.point(0, 0)
                    property var startCamera: null
                    property bool moved: false
                    cursorShape: pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor
                    onPressed: mouse => {
                        const point = mapToItem(view, mouse.x, mouse.y)
                        pressPoint = point; startCamera = view.interruptMotion(); view.beginPanMotion(); moved = false; view.forceActiveFocus()
                    }
                    onPositionChanged: mouse => {
                        if (!pressed) return
                        const point = mapToItem(view, mouse.x, mouse.y)
                        const dx = point.x - pressPoint.x, dy = point.y - pressPoint.y
                        if (Math.abs(dx) + Math.abs(dy) > 3) moved = true
                        if (moved) { view.setCamera({ zoom: startCamera.zoom, x: startCamera.x + dx, y: startCamera.y + dy }, false); view.recordPanMotion(dx, dy); view.fitMode = "free" }
                    }
                    onReleased: if (moved) view.finishPanMotion()
                    onClicked: if (!moved && !view.panHeld) view.spaceSelected(sheet.modelData.id)
                    onDoubleClicked: if (!moved && !view.panHeld) { view.spaceSelected(sheet.modelData.id); view.fitSpace(sheet.modelData.id) }
                }
            }
            RowLayout {
                anchors.left: parent.left; anchors.bottom: parent.top; anchors.bottomMargin: 8
                width: parent.width; spacing: 7
                AppText { text: (sheet.width > 140 ? "SPACE " : "") + String(sheet.modelData.id).padStart(2, "0"); mono: true; font.pixelSize: sheet.width > 180 ? 13 : 11; font.letterSpacing: 0.8; font.weight: Font.DemiBold; color: sheet.chosen ? Theme.cyan : Theme.body }
                Tag { visible: sheet.width > 240 && (sheet.modelData.current || sheet.chosen); text: sheet.modelData.current ? "CURRENT" : "INSPECTING"; tone: sheet.modelData.current ? Theme.green : Theme.amber; dot: sheet.modelData.current }
                Item { Layout.fillWidth: true }
                AppText { visible: sheet.width > 100; text: sheet.modelData.windows.length + (sheet.width > 220 ? sheet.modelData.windows.length === 1 ? " window" : " windows" : ""); mono: true; font.pixelSize: 11; color: Theme.muted }
            }
            Rectangle { visible: sheet.modelData.current; anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top; height: 2; color: Theme.green; z: 5 }
            Repeater {
                model: sheet.modelData.windows
                Rectangle {
                    id: tile
                    required property var modelData
                    readonly property bool chosen: view.controller.selectedWid === modelData.wid && sheet.chosen
                    readonly property bool readable: width > 90 && height > 36
                    x: (modelData.frame.x - view.display.frame.x) * view.visualCamera.zoom
                    y: (modelData.frame.y - view.display.frame.y) * view.visualCamera.zoom
                    width: Math.max(3, modelData.frame.w * view.visualCamera.zoom); height: Math.max(3, modelData.frame.h * view.visualCamera.zoom)
                    z: chosen ? 2 : modelData.isFocused ? 1 : 0
                    color: chosen ? Theme.cyanSoft : Theme.surface
                    border.color: chosen ? Theme.cyan : modelData.isFocused ? Theme.greenLine : Theme.borderLit
                    radius: 3; clip: true
                    Rectangle { visible: tile.modelData.isFocused; x: 1; width: parent.width - 2; height: 2; color: Theme.green }
                    ColumnLayout {
                        visible: tile.readable
                        anchors.fill: parent; anchors.margins: Math.min(12, tile.width / 10); spacing: 5
                        AppText { text: view.controller.appName(tile.modelData.app); font.pixelSize: tile.width > 220 ? 14 : 11; font.weight: Font.Medium; color: tile.chosen ? Theme.text : Theme.body; Layout.fillWidth: true; elide: Text.ElideRight }
                        AppText { visible: tile.height > 65 && tile.width > 120; text: tile.modelData.title; font.pixelSize: 12; color: Theme.muted; Layout.fillWidth: true; wrapMode: Text.WordWrap; maximumLineCount: tile.height > 130 ? 3 : 1; elide: Text.ElideRight }
                        Item { Layout.fillHeight: true }
                        RowLayout {
                            visible: tile.width > 220 && tile.height > 125; Layout.fillWidth: true
                            AppText { text: tile.modelData.isFocused ? "FOCUSED" : tile.modelData.isFloating ? "FLOATING" : "TILED"; mono: true; font.pixelSize: 10; color: tile.modelData.isFocused ? Theme.green : Theme.dim; Layout.fillWidth: true }
                            AppText { text: tile.modelData.frame.w + " × " + tile.modelData.frame.h; mono: true; font.pixelSize: 10; color: Theme.dim }
                        }
                    }
                    MouseArea {
                        anchors.fill: parent
                        onPressed: view.interruptMotion()
                        onClicked: if (!view.panHeld) { view.windowSelected(sheet.modelData.id, tile.modelData.wid); view.forceActiveFocus() }
                        onDoubleClicked: if (!view.panHeld) view.windowActivated(sheet.modelData.id, tile.modelData.wid)
                    }
                    HoverHandler { id: hoverTile }
                    ToolTip.visible: hoverTile.hovered && !view.panHeld && !view.motionRunning && !drag.active
                    ToolTip.delay: 700
                    ToolTip.text: view.controller.appName(modelData.app) + " · " + modelData.title + "\nClick to select · double-click to focus"
                    Brackets { visible: tile.chosen; anchors.fill: parent; anchors.margins: 3; ink: Theme.cyan; arm: Math.min(10, parent.width / 5); weight: 1.5; z: 4 }
                }
            }
            AppText { visible: sheet.modelData.windows.length === 0 && sheet.width > 130; anchors.centerIn: parent; text: view.query ? "No matches" : "Clear space"; font.pixelSize: 13; color: Theme.dim }
            Rectangle {
                visible: sheet.chosen && view.placementPlan !== null
                x: ((view.placementPlan?.frame.x || 0) - (view.display?.frame.x || 0)) * view.visualCamera.zoom
                y: ((view.placementPlan?.frame.y || 0) - (view.display?.frame.y || 0)) * view.visualCamera.zoom
                width: (view.placementPlan?.frame.w || 0) * view.visualCamera.zoom; height: (view.placementPlan?.frame.h || 0) * view.visualCamera.zoom
                z: 6; radius: 3; color: Qt.rgba(Theme.amber.r, Theme.amber.g, Theme.amber.b, 0.12); border.color: Theme.amber; border.width: 1.5
                Tag { visible: parent.width > 130; anchors.centerIn: parent; text: "PREVIEW · NO MOVE"; tone: Theme.amber }
            }
        }
    }
    DragHandler {
        id: drag
        objectName: "canvasPanHandler"
        target: null
        acceptedButtons: view.panHeld ? Qt.LeftButton | Qt.MiddleButton : Qt.MiddleButton
        property var startCamera: null
        onActiveChanged: {
            if (active) { startCamera = view.interruptMotion(); view.beginPanMotion(); view.forceActiveFocus() }
            else if (startCamera) { view.finishPanMotion(); startCamera = null }
        }
        onTranslationChanged: if (active && startCamera) { view.setCamera({ zoom: startCamera.zoom, x: startCamera.x + activeTranslation.x, y: startCamera.y + activeTranslation.y }, false); view.recordPanMotion(activeTranslation.x, activeTranslation.y); view.fitMode = "free" }
    }
    WheelHandler {
        target: null
        acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
        onWheel: event => {
            view.forceActiveFocus()
            const delta = event.pixelDelta.y || event.angleDelta.y
            if ((event.modifiers & Qt.ShiftModifier) || (!delta && (event.pixelDelta.x || event.angleDelta.x))) view.panBy(event.pixelDelta.x || event.angleDelta.x || delta, 0)
            else if (delta) view.zoomBy(Math.exp(delta * (event.pixelDelta.y ? 0.005 : 0.0015)), event.x, event.y)
            event.accepted = true
        }
    }
    PinchHandler {
        id: pinch
        target: null
        property var startCamera: null
        property point origin: Qt.point(0, 0)
        onActiveChanged: if (active) { startCamera = view.interruptMotion(); origin = centroid.position; view.forceActiveFocus() }
        onUpdated: if (active && startCamera) {
            const next = World.zoomCamera(startCamera, activeScale, origin.x, origin.y, view.overviewZoom * 0.45, view.detailZoom * 5)
            view.setCamera({ zoom: next.zoom, x: next.x + activeTranslation.x, y: next.y + activeTranslation.y }, false)
            view.fitMode = "free"
        }
    }
    Rectangle {
        anchors.right: parent.right; anchors.bottom: parent.bottom; anchors.margins: 10
        width: controls.implicitWidth + 10; height: 34; radius: 4
        color: Theme.chassis; border.color: Theme.borderLit; z: 10
        RowLayout {
            id: controls
            anchors.centerIn: parent; spacing: 4
            DeckButton { text: "−"; implicitWidth: 26; quiet: true; onClicked: { view.zoomBy(0.8); view.forceActiveFocus() }
                Accessible.name: "Zoom out" }
            AppText { text: view.zoomPercent + "%"; mono: true; font.pixelSize: 11; color: Theme.body; Layout.preferredWidth: 46; horizontalAlignment: Text.AlignHCenter }
            DeckButton { text: "+"; implicitWidth: 26; quiet: true; onClicked: { view.zoomBy(1.25); view.forceActiveFocus() }
                Accessible.name: "Zoom in" }
            Rectangle { implicitWidth: 1; implicitHeight: 16; color: Theme.borderLit }
            DeckButton { objectName: "canvasFitAll"; text: "All"; quiet: true; onClicked: { view.fitAll(); view.forceActiveFocus() }
                Accessible.name: "Fit all spaces"; ToolTip.visible: hovered; ToolTip.text: "Fit all spaces · 0" }
            DeckButton { objectName: "canvasFitSpace"; text: "Space"; quiet: true; onClicked: { view.fitSpace(view.spaceId); view.forceActiveFocus() }
                Accessible.name: "Zoom into selected space"; ToolTip.visible: hovered; ToolTip.text: "Zoom into selected space · 1" }
        }
    }
}
