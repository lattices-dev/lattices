pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

ScrollView {
    id: hints
    required property var controller
    property string selectedGroup: ""
    property string query: ""
    readonly property var pack: controller.hints
    readonly property var groups: (pack.groups || []).filter(group => selectedGroup === "" || group.id === selectedGroup).map(group => ({
        id: group.id, title: group.title, scope: group.scope,
        hints: group.hints.filter(hint => [hint.title, hint.shortcut || "", hint.command || "", hint.detail].join(" ").toLowerCase().includes(query.toLowerCase().trim()))
    })).filter(group => group.hints.length)
    contentWidth: availableWidth
    clip: true

    ColumnLayout {
        width: hints.availableWidth
        spacing: 20
        ColumnLayout {
            Layout.fillWidth: true; Layout.margins: 20; Layout.bottomMargin: 0
            spacing: 12
            AppText { text: hints.pack.title || "Lattices on Linux"; font.pixelSize: 20; font.weight: Font.DemiBold }
            AppText { text: "A few useful moves, close at hand."; color: Theme.muted; font.pixelSize: 13 }
            AppText { text: hints.pack.note || "Loading hints…"; color: Theme.dim; Layout.fillWidth: true; wrapMode: Text.WordWrap; lineHeight: 1.3 }
            InputField {
                Layout.fillWidth: true
                placeholderText: "Find a shortcut, command or action…"
                onTextChanged: hints.query = text
                Accessible.name: "Search hints"
            }
            Flow {
                Layout.fillWidth: true; spacing: 6
                ActionButton { text: "All"; selected: hints.selectedGroup === ""; onClicked: hints.selectedGroup = "" }
                Repeater {
                    model: hints.pack.groups || []
                    ActionButton {
                        required property var modelData
                        text: modelData.title
                        selected: hints.selectedGroup === modelData.id
                        onClicked: hints.selectedGroup = modelData.id
                    }
                }
            }
        }
        Repeater {
            model: hints.groups
            ColumnLayout {
                id: group
                required property var modelData
                Layout.fillWidth: true; Layout.leftMargin: 20; Layout.rightMargin: 20
                spacing: 10
                AppText { text: group.modelData.title; font.pixelSize: 14; font.weight: Font.DemiBold }
                AppText { text: group.modelData.scope; color: Theme.dim; font.pixelSize: 11; Layout.fillWidth: true; wrapMode: Text.WordWrap }
                Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: Theme.border }
                Repeater {
                    model: group.modelData.hints
                    RowLayout {
                        id: hintRow
                        required property var modelData
                        Layout.fillWidth: true; Layout.topMargin: 4; Layout.bottomMargin: 4
                        spacing: 18
                        Rectangle {
                            Layout.preferredWidth: Math.min(250, (hints.availableWidth - 40) * 0.43)
                            Layout.alignment: Qt.AlignTop
                            implicitHeight: key.implicitHeight + 18
                            radius: 6; color: Theme.surface; border.color: Theme.borderLit
                            AppText {
                                id: key
                                anchors.fill: parent; anchors.margins: 9
                                text: hintRow.modelData.shortcut || hintRow.modelData.command
                                mono: true; font.pixelSize: 11; color: Theme.green
                                wrapMode: Text.WrapAnywhere
                            }
                        }
                        ColumnLayout {
                            Layout.fillWidth: true; Layout.alignment: Qt.AlignTop
                            spacing: 5
                            AppText { text: hintRow.modelData.title; font.weight: Font.DemiBold; Layout.fillWidth: true; wrapMode: Text.WordWrap }
                            AppText { text: hintRow.modelData.detail; color: Theme.muted; Layout.fillWidth: true; wrapMode: Text.WordWrap; lineHeight: 1.25 }
                        }
                    }
                }
            }
        }
        AppText { visible: (hints.pack.groups || []).length > 0 && hints.groups.length === 0; text: "No matching hints. Try another word or choose All."; color: Theme.muted; Layout.margins: 20; Layout.fillWidth: true; wrapMode: Text.WordWrap }
        AppText { text: "Terminal: lats hints · Open this page: lats hints --open"; mono: true; color: Theme.dim; font.pixelSize: 10; Layout.margins: 20; Layout.fillWidth: true; wrapMode: Text.WordWrap }
    }
}
