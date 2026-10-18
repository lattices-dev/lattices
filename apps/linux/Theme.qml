pragma Singleton
import QtQuick

// One operator workstation in black, gray and white, with a single warm
// accent. The values below are the built-in neutral and amber; the desktop
// palette replaces them through applyAppearance (see appearance.ts, which
// derives every color token and keeps these defaults honest in its tests).
// Chrome dimensions still follow apps/mac/Sources/UI/Theme.swift.
QtObject {
    id: theme

    // Ground, from deepest well to raised control.
    property color ink: "#0b0b0b"
    property color bg: "#0f0f0f"
    property color chassis: "#121212"
    property color surface: "#1d1d1d"
    property color hover: "#282828"
    // Hairlines: a rule, a control outline, a hovered outline.
    property color border: "#252525"
    property color borderLit: "#393939"
    property color borderHot: "#505050"
    property color grid: "#292929"

    // Type, from primary reading to tertiary annotation.
    property color text: "#f1f1f1"
    property color body: "#c2c2c2"
    property color muted: "#9a9a9a"
    property color dim: "#797979"

    // Accent: the operator's own selection, keyboard focus and primary action.
    property color accent: "#e68e0d"
    property color accentSoft: "#2f220f"
    property color accentLine: "#7f510e"
    property color accentHover: "#e9a33c"
    property color accentInk: "#201402"
    property color selection: "#583a0e"
    // Live: desktop truth (current, focused, connected, succeeded). Neutral,
    // so it is always paired with a dot, a rule or a word.
    property color live: "#f1f1f1"
    property color liveSoft: "#282828"
    property color liveLine: "#626262"
    // Caution: looking without touching (preview, inspected, parked).
    property color caution: "#ddbb88"
    property color cautionSoft: "#2a251f"
    property color cautionLine: "#6c5c45"
    // Red: the request failed.
    property color red: "#ef6c70"
    property color redSoft: "#311d1e"
    property color redText: "#f2a6a8"

    // Earlier hue names, kept for the views that still use them.
    readonly property color green: live
    readonly property color greenSoft: liveSoft
    readonly property color greenLine: liveLine
    readonly property color cyan: accent
    readonly property color cyanSoft: accentSoft
    readonly property color cyanLine: accentLine
    readonly property color amber: caution
    readonly property color amberSoft: cautionSoft
    readonly property color amberLine: cautionLine

    // Material. Only the window ground is translucent; type and controls stay
    // opaque. Opaque until the appearance says otherwise.
    property real chassisOpacity: 1
    readonly property color glass: Qt.rgba(chassis.r, chassis.g, chassis.b, chassisOpacity)
    // The page well over the glass: a little deeper and a little more solid.
    readonly property color well: Qt.rgba(bg.r, bg.g, bg.b, chassisOpacity < 1 ? 0.55 : 1)
    // True while a ShellChrome supplies the ground, so a page does not paint
    // a second, opaque one over it.
    property bool framed: false
    readonly property color pageGround: framed ? "transparent" : bg
    // Translucent raises for a band or a chosen row on the glass, and the top
    // edge light.
    readonly property color film: Qt.rgba(text.r, text.g, text.b, 0.035)
    readonly property color filmLit: Qt.rgba(text.r, text.g, text.b, 0.07)
    readonly property color sheen: Qt.rgba(1, 1, 1, mode === "light" ? 0.6 : 0.07)

    property string mode: "dark"
    property string source: "default"
    property string themeName: ""

    property string font: "Adwaita Sans"
    property string mono: "JetBrains Mono"
    // Type scale. Captions are tracked capitals in the mono face.
    readonly property int caption: 10
    readonly property int small: 11
    readonly property int base: 12
    readonly property int lead: 13
    readonly property int title: 16
    readonly property real tracking: 1.3
    readonly property real stroke: 1.35

    readonly property int rail: 48
    readonly property int labels: 120
    readonly property int header: 44
    readonly property int footer: 24
    readonly property int gutter: 16

    readonly property var tokenNames: ["ink", "bg", "chassis", "surface", "hover", "border", "borderLit", "borderHot", "grid", "text", "body", "muted", "dim", "accent", "accentSoft", "accentLine", "accentHover", "accentInk", "selection", "live", "liveSoft", "liveLine", "caution", "cautionSoft", "cautionLine", "red", "redSoft", "redText"]
    property var defaults: null
    Component.onCompleted: defaults = capture()
    function capture() {
        const kept = { chassisOpacity: chassisOpacity, mode: mode, font: font, mono: mono, tokens: {} }
        for (const name of tokenNames) kept.tokens[name] = String(theme[name])
        return kept
    }
    function family(value, fallback) { return typeof value === "string" && value.trim() !== "" && value.length <= 64 ? value : fallback }

    // Accepts the `appearance` object from the app bridge. Anything missing
    // or malformed keeps its current value, so a partial message cannot leave
    // the app unreadable. Returns the number of color tokens applied.
    function applyAppearance(appearance) {
        if (!appearance || typeof appearance !== "object") return 0
        let applied = 0
        const tokens = appearance.tokens && typeof appearance.tokens === "object" ? appearance.tokens : {}
        for (const name of tokenNames) {
            const value = tokens[name]
            if (typeof value !== "string" || !/^#[0-9a-fA-F]{6}$/.test(value)) continue
            theme[name] = value
            applied++
        }
        const opacity = Number(appearance.chassisOpacity)
        if (appearance.chassisOpacity !== undefined && appearance.chassisOpacity !== null && isFinite(opacity)) chassisOpacity = Math.max(0.88, Math.min(1, opacity))
        if (appearance.mode === "light" || appearance.mode === "dark") mode = appearance.mode
        font = family(appearance.font, font)
        mono = family(appearance.mono, mono)
        source = appearance.source === "omarchy" ? "omarchy" : "default"
        themeName = typeof appearance.theme === "string" ? appearance.theme.slice(0, 64) : ""
        return applied
    }
    function resetAppearance() {
        applyAppearance(defaults)
        source = "default"; themeName = ""
    }
}
