import QtQuick

// A state word in its signal tone. A dot means the state is live right now.
Rectangle {
    id: tag
    property string text: ""
    property color tone: Theme.muted
    property bool dot: false
    implicitWidth: label.implicitWidth + (dot ? 21 : 12)
    implicitHeight: 17
    radius: 2
    color: Qt.rgba(tone.r, tone.g, tone.b, 0.08)
    border.color: Qt.rgba(tone.r, tone.g, tone.b, 0.38)
    Rectangle { visible: tag.dot; x: 6; anchors.verticalCenter: parent.verticalCenter; width: 5; height: 5; radius: 3; color: tag.tone }
    AppText { id: label; x: tag.dot ? 15 : 6; anchors.verticalCenter: parent.verticalCenter; text: tag.text; mono: true; font.pixelSize: Theme.caption; font.letterSpacing: 0.9; font.weight: Font.Medium; color: tag.tone }
}
