pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// The shared chassis: navigation rail, one title strip and one status line
// around whichever page is on screen. Pages do not repeat the title. The
// chassis is the one translucent sheet; the page sits in a deeper well.
Rectangle {
    id: chrome
    required property var controller
    default property alias content: slot.data
    readonly property var titles: ({ Overview: "Flight Deck", Mission: "Mission Control", Console: "Operator Console" })
    readonly property var shortcuts: ({ Home: "Ctrl 1", Overview: "Ctrl 2", Layers: "Ctrl 3", Activity: "Ctrl 4", Hints: "F1", Mission: "Ctrl 6", Console: "Ctrl 7" })
    readonly property string hostname: controller.state.describe?.hostname || ""
    readonly property int spaceCount: controller.state.displays.reduce((n, d) => n + d.spaces.length, 0)
    function plural(count, noun) { return count + " " + noun + (count === 1 ? "" : "s") }
    color: Theme.glass
    Component.onCompleted: Theme.framed = true
    Component.onDestruction: Theme.framed = false

    RowLayout {
        anchors.fill: parent; spacing: 0
        ColumnLayout {
            Layout.preferredWidth: chrome.controller.sidebarWidth
            Layout.minimumWidth: chrome.controller.sidebarWidth
            Layout.maximumWidth: chrome.controller.sidebarWidth
            Layout.fillHeight: true; spacing: 0
            Button {
                id: brand; objectName: "shellBrand"
                Layout.fillWidth: true; implicitHeight: Theme.header; padding: 0
                Accessible.name: chrome.controller.compact ? "Expand sidebar" : "Collapse sidebar"
                onClicked: chrome.controller.compact = !chrome.controller.compact
                background: Rectangle { color: brand.hovered ? Theme.film : "transparent"; border.width: brand.visualFocus ? 1 : 0; border.color: Theme.accent }
                contentItem: RowLayout {
                    spacing: 0
                    Item { Layout.preferredWidth: Theme.rail; Layout.fillHeight: true; BrandMark { anchors.centerIn: parent } }
                    AppText { visible: !chrome.controller.compact; text: "Lattices"; font.pixelSize: 14; font.weight: Font.Medium; font.letterSpacing: 0.2; Layout.fillWidth: true }
                }
                ToolTip.visible: hovered; ToolTip.delay: 700; ToolTip.text: chrome.controller.compact ? "Expand sidebar" : "Collapse sidebar"
            }
            Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: Theme.border }
            DeckLabel { opacity: chrome.controller.compact ? 0 : 1; text: "WORKSPACE"; color: Theme.dim; Layout.leftMargin: 16; Layout.topMargin: 16; Layout.bottomMargin: 6 }
            NavRow { objectName: "navHome"; Layout.fillWidth: true; text: "Home"; glyph: "home"; shortcut: chrome.shortcuts.Home; compact: chrome.controller.compact; selected: chrome.controller.page === text; onClicked: chrome.controller.page = text }
            NavRow { objectName: "navOverview"; Layout.fillWidth: true; text: "Flight Deck"; glyph: "overview"; shortcut: chrome.shortcuts.Overview; compact: chrome.controller.compact; selected: chrome.controller.page === "Overview"; onClicked: chrome.controller.page = "Overview" }
            NavRow { objectName: "navMission"; Layout.fillWidth: true; text: "Mission Control"; glyph: "window"; shortcut: chrome.shortcuts.Mission; compact: chrome.controller.compact; selected: chrome.controller.page === "Mission"; onClicked: chrome.controller.page = "Mission" }
            NavRow { objectName: "navConsole"; Layout.fillWidth: true; text: "Operator Console"; glyph: "terminal"; shortcut: chrome.shortcuts.Console; compact: chrome.controller.compact; selected: chrome.controller.page === "Console"; onClicked: chrome.controller.page = "Console" }
            NavRow { objectName: "navLayers"; Layout.fillWidth: true; text: "Layers"; glyph: "layers"; shortcut: chrome.shortcuts.Layers; compact: chrome.controller.compact; selected: chrome.controller.page === text; onClicked: chrome.controller.page = text }
            DeckLabel { opacity: chrome.controller.compact ? 0 : 1; text: "SYSTEM"; color: Theme.dim; Layout.leftMargin: 16; Layout.topMargin: 22; Layout.bottomMargin: 6 }
            NavRow { objectName: "navActivity"; Layout.fillWidth: true; text: "Activity"; glyph: "activity"; shortcut: chrome.shortcuts.Activity; compact: chrome.controller.compact; selected: chrome.controller.page === text; onClicked: chrome.controller.page = text }
            NavRow { objectName: "navHints"; Layout.fillWidth: true; text: "Hints"; glyph: "hints"; shortcut: chrome.shortcuts.Hints; compact: chrome.controller.compact; selected: chrome.controller.page === text; onClicked: chrome.controller.page = text }
            Item { Layout.fillHeight: true }
            NavRow {
                objectName: "navAgentView"; Layout.fillWidth: true
                text: chrome.controller.virtualViewerVisible ? "Hide agent view" : "Agent view"
                glyph: "virtual"; compact: chrome.controller.compact
                selected: !!chrome.controller.virtualViewerVisible
                onClicked: chrome.controller.showVirtualViewer("toggle")
            }
            Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: Theme.border }
            Button {
                id: daemon; objectName: "shellDaemon"
                Layout.fillWidth: true; Layout.topMargin: 4; implicitHeight: 30; padding: 0
                onClicked: chrome.controller.page = "Settings"
                Accessible.name: "Local host " + (chrome.controller.online ? "connected" : "offline")
                background: Rectangle {
                    anchors.fill: parent; anchors.leftMargin: 6; anchors.rightMargin: 6; anchors.topMargin: 1; anchors.bottomMargin: 1
                    radius: 3; color: daemon.hovered ? Theme.film : "transparent"; border.width: daemon.visualFocus ? 1 : 0; border.color: Theme.accent
                }
                contentItem: RowLayout {
                    spacing: 0
                    Item {
                        Layout.preferredWidth: Theme.rail; Layout.fillHeight: true
                        // Solid when the host answers, a hollow ring when it does not.
                        Rectangle { anchors.centerIn: parent; width: 7; height: 7; radius: 4; color: chrome.controller.online ? Theme.live : "transparent"; border.width: chrome.controller.online ? 0 : 1; border.color: Theme.caution }
                    }
                    AppText { visible: !chrome.controller.compact; text: "Daemon"; font.pixelSize: Theme.base; color: Theme.body }
                    AppText { visible: !chrome.controller.compact; text: ":" + chrome.controller.hostPort; mono: true; font.pixelSize: 10; color: Theme.dim; Layout.leftMargin: 6; Layout.fillWidth: true }
                }
                ToolTip.visible: hovered; ToolTip.text: chrome.controller.online ? "Local host connected" : "Local host offline"
            }
            NavRow { objectName: "navSettings"; Layout.fillWidth: true; Layout.bottomMargin: 4; text: "Settings"; glyph: "settings"; compact: chrome.controller.compact; selected: chrome.controller.page === text; onClicked: chrome.controller.page = text }
        }
        Rectangle { Layout.fillHeight: true; implicitWidth: 1; color: Theme.border }
        Item {
            Layout.fillWidth: true; Layout.fillHeight: true
            ColumnLayout {
                anchors.fill: parent; spacing: 0
                RowLayout {
                    Layout.fillWidth: true; Layout.preferredHeight: Theme.header; Layout.leftMargin: Theme.gutter; Layout.rightMargin: 10; spacing: 8
                    AppText { objectName: "shellTitle"; text: chrome.titles[chrome.controller.page] || chrome.controller.page; font.pixelSize: Theme.title; font.weight: Font.Medium; font.letterSpacing: -0.1; Layout.minimumWidth: implicitWidth }
                    KeyCap { visible: !!chrome.shortcuts[chrome.controller.page] && chrome.width >= 900; text: chrome.shortcuts[chrome.controller.page] || ""; ink: Theme.dim; line: Theme.border; Layout.leftMargin: 2 }
                    Item { Layout.fillWidth: true }
                    AppText { visible: chrome.hostname !== "" && chrome.width >= 900; text: chrome.hostname; mono: true; font.pixelSize: Theme.small; color: Theme.muted }
                    Tag {
                        objectName: "shellLink"
                        text: chrome.controller.busy ? "WORKING" : chrome.controller.online ? "LIVE" : "OFFLINE"
                        tone: chrome.controller.busy ? Theme.accent : chrome.controller.online ? Theme.live : Theme.caution
                        dot: chrome.controller.online && !chrome.controller.busy
                        Layout.rightMargin: 4
                    }
                    ActionButton { visible: chrome.controller.page === "Home"; text: "New session"; glyph: "plus"; accent: true; enabled: chrome.controller.online && !chrome.controller.busy; onClicked: chrome.controller.newSession() }
                    ActionButton { text: chrome.controller.busy ? "Working…" : "Refresh"; glyph: "refresh"; quiet: true; enabled: !chrome.controller.busy; onClicked: chrome.controller.call("refresh") }
                    ActionButton { text: "Search"; glyph: "search"; shortcut: "Ctrl K"; quiet: true; enabled: chrome.controller.online; onClicked: chrome.controller.showSearch() }
                }
                Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: Theme.border }
                Rectangle {
                    Layout.fillWidth: true; Layout.fillHeight: true
                    color: Theme.well
                    ColumnLayout { id: slot; objectName: "shellContent"; anchors.fill: parent; spacing: 0 }
                }
                Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: Theme.border }
                RowLayout {
                    Layout.fillWidth: true; Layout.preferredHeight: Theme.footer; Layout.leftMargin: Theme.gutter; Layout.rightMargin: Theme.gutter; spacing: 16
                    AppText { text: chrome.plural(chrome.controller.state.sessions.length, "session") + " running"; mono: true; font.pixelSize: Theme.caption; color: Theme.muted }
                    AppText { visible: chrome.controller.message === ""; text: chrome.plural(chrome.controller.state.windows.length, "window") + " · " + chrome.plural(chrome.controller.state.displays.length, "display") + " · " + chrome.plural(chrome.spaceCount, "space"); mono: true; font.pixelSize: Theme.caption; color: Theme.dim }
                    AppText { objectName: "shellMessage"; visible: chrome.controller.message !== ""; text: chrome.controller.message; mono: true; font.pixelSize: Theme.caption; color: chrome.controller.online ? Theme.red : Theme.muted; Layout.fillWidth: true; elide: Text.ElideRight }
                    Item { Layout.fillWidth: true }
                    DeckLabel { text: chrome.controller.online ? "LOCAL" : "OFFLINE"; color: Theme.dim }
                }
            }
        }
    }
    // Edge light along the top of the sheet.
    Rectangle { width: parent.width; height: 1; color: Theme.sheen }
}
