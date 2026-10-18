import DeckKit
import Foundation

enum InteractionMode: String {
    case learning = "learning"
    case auto = "auto"
}

enum MouseGestureHUDStyle: String, CaseIterable, Identifiable {
    case technical
    case sober
    case ink

    var id: String { rawValue }

    var label: String {
        switch self {
        case .technical:
            return "Technical"
        case .sober:
            return "Sober"
        case .ink:
            return "Ink"
        }
    }
}

enum TilePointerHUDStyle: String, CaseIterable, Identifiable {
    case loop
    case matrix

    var id: String { rawValue }

    var label: String {
        switch self {
        case .loop: return "Loop"
        case .matrix: return "Matrix"
        }
    }
}

/// Which feature owns the physical Ctrl+Option hold. Exactly one may claim
/// the gesture — running both renders two pickers and commits two placements.
enum CtrlOptionHoldMode: String, CaseIterable, Identifiable {
    /// The gray radial/matrix aim picker; release tiles the frontmost window.
    case tileHUD
    /// The labeled contextual lens; release places the window under the pointer.
    case spatialLens
    case off

    var id: String { rawValue }

    /// Spatial Lens ships with the bundle tier; the free build offers the rest.
    static var available: [CtrlOptionHoldMode] {
        allCases.filter { $0 != .spatialLens || LatticesTier.isBundle }
    }

    var label: String {
        switch self {
        case .tileHUD: return "Tile HUD"
        case .spatialLens: return "Spatial Lens"
        case .off: return "Off"
        }
    }
}

/// Where the Ctrl+←/→ Space-switch confirmation pill lands on screen.
enum SpaceSwitchBezelPosition: String, CaseIterable, Identifiable {
    /// Docks at the screen edge the desktop is moving toward.
    case travelEdge
    case top
    case center
    case bottom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .travelEdge: return "Travel edge"
        case .top: return "Top"
        case .center: return "Center"
        case .bottom: return "Bottom"
        }
    }
}

class Preferences: ObservableObject {
    static let shared = Preferences()

    private enum CompanionDefaultsKey {
        static let bridgeEnabled = "companion.bridge.enabled"
        static let trackpadEnabled = "companion.trackpad.enabled"
    }

    private static let dismissedCapabilitiesKey = "permissions.dismissed"

    @Published var terminal: Terminal {
        didSet { UserDefaults.standard.set(terminal.rawValue, forKey: "terminal") }
    }

    @Published var scanRoot: String {
        didSet { UserDefaults.standard.set(scanRoot, forKey: "scanRoot") }
    }

    @Published var mode: InteractionMode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "mode") }
    }

    @Published var dragSnapEnabled: Bool {
        didSet { UserDefaults.standard.set(dragSnapEnabled, forKey: "windowSnap.enabled") }
    }

    @Published var companionBridgeEnabled: Bool {
        didSet { UserDefaults.standard.set(companionBridgeEnabled, forKey: CompanionDefaultsKey.bridgeEnabled) }
    }

    @Published var companionTrackpadEnabled: Bool {
        didSet { UserDefaults.standard.set(companionTrackpadEnabled, forKey: CompanionDefaultsKey.trackpadEnabled) }
    }

    @Published var mouseGesturesEnabled: Bool {
        didSet { UserDefaults.standard.set(mouseGesturesEnabled, forKey: "mouseGestures.enabled") }
    }

    @Published var mouseGestureHUDVisualEnabled: Bool {
        didSet { UserDefaults.standard.set(mouseGestureHUDVisualEnabled, forKey: "mouseGestures.hud.visualEnabled") }
    }

    @Published var mouseGestureHUDAudioEnabled: Bool {
        didSet { UserDefaults.standard.set(mouseGestureHUDAudioEnabled, forKey: "mouseGestures.hud.audioEnabled") }
    }

    @Published var mouseGestureHUDStyle: MouseGestureHUDStyle {
        didSet { UserDefaults.standard.set(mouseGestureHUDStyle.rawValue, forKey: "mouseGestures.hud.style") }
    }

    @Published var tilePointerHUDStyle: TilePointerHUDStyle {
        didSet { UserDefaults.standard.set(tilePointerHUDStyle.rawValue, forKey: "tilePointer.hud.style") }
    }
    /// Experiment: tick on aim change + tactile tap when the window lands.
    @Published var tilePointerSoundEffectsEnabled: Bool {
        didSet { UserDefaults.standard.set(tilePointerSoundEffectsEnabled, forKey: "tilePointer.soundEffects.enabled") }
    }

    @Published var cursorMarkerShape: CursorMarkerShape {
        didSet { UserDefaults.standard.set(cursorMarkerShape.rawValue, forKey: "cursorMarker.shape") }
    }

    @Published var cursorMarkerAngleDeg: Int {
        didSet { UserDefaults.standard.set(Self.normalizedCursorMarkerAngle(cursorMarkerAngleDeg), forKey: "cursorMarker.angleDeg") }
    }

    @Published var cursorMarkerSize: CursorMarkerSize {
        didSet { UserDefaults.standard.set(cursorMarkerSize.rawValue, forKey: "cursorMarker.size") }
    }

    @Published var ctrlOptionHoldMode: CtrlOptionHoldMode {
        didSet { UserDefaults.standard.set(ctrlOptionHoldMode.rawValue, forKey: "ctrlOptionHold.mode") }
    }

    /// Spatial Lens owns the Ctrl+Option hold only in lens mode.
    var spatialLensEnabled: Bool { ctrlOptionHoldMode == .spatialLens }

    @Published var keyboardRemapsEnabled: Bool {
        didSet { UserDefaults.standard.set(keyboardRemapsEnabled, forKey: "keyboardRemaps.enabled") }
    }

    /// Intercept Ctrl+←/→ and switch Spaces through the SkyLight path
    /// (instant, no slide animation) with a small branded confirmation.
    @Published var spaceSwitchKeysEnabled: Bool {
        didSet { UserDefaults.standard.set(spaceSwitchKeysEnabled, forKey: "spaceSwitchKeys.enabled") }
    }

    @Published var spaceSwitchBezelPosition: SpaceSwitchBezelPosition {
        didSet { UserDefaults.standard.set(spaceSwitchBezelPosition.rawValue, forKey: "spaceSwitchKeys.bezelPosition") }
    }

    /// Optional pointer streaks alongside the desktop filmstrip.
    @Published var spaceSwitchGlideEnabled: Bool {
        didSet { UserDefaults.standard.set(spaceSwitchGlideEnabled, forKey: "spaceSwitchKeys.glide") }
    }

    /// How long letting go of ⌘⌥ on another layer waits for Return before
    /// staying put (`LayerAim`). 0 switches at once; below 0 waits for a key.
    @Published var layerSwitchConfirmSeconds: Double {
        didSet { UserDefaults.standard.set(layerSwitchConfirmSeconds, forKey: "layers.confirmSeconds") }
    }

    // MARK: - Search & OCR

    @Published var ocrEnabled: Bool {
        didSet { UserDefaults.standard.set(!ocrEnabled, forKey: "ocr.disabled") }
    }

    @Published var ocrQuickInterval: Double {
        didSet { UserDefaults.standard.set(ocrQuickInterval, forKey: "ocr.interval") }
    }

    @Published var ocrDeepInterval: Double {
        didSet { UserDefaults.standard.set(ocrDeepInterval, forKey: "ocr.deepInterval") }
    }

    @Published var ocrQuickLimit: Int {
        didSet { UserDefaults.standard.set(ocrQuickLimit, forKey: "ocr.quickLimit") }
    }

    @Published var ocrDeepLimit: Int {
        didSet { UserDefaults.standard.set(ocrDeepLimit, forKey: "ocr.deepLimit") }
    }

    @Published var ocrDeepBudget: Int {
        didSet { UserDefaults.standard.set(ocrDeepBudget, forKey: "ocr.deepBudget") }
    }

    @Published var ocrAccuracy: String {
        didSet { UserDefaults.standard.set(ocrAccuracy, forKey: "ocr.accuracy") }
    }

    @Published var ocrRetentionDays: Int {
        didSet { UserDefaults.standard.set(ocrRetentionDays, forKey: "ocr.retentionDays") }
    }

    // MARK: - Permissions Assistant

    /// Capabilities the user has explicitly snoozed. Cleared per-capability when
    /// the user re-enters the relevant feature. Persisted as raw values.
    @Published var dismissedCapabilities: Set<String> {
        didSet {
            UserDefaults.standard.set(Array(dismissedCapabilities), forKey: Self.dismissedCapabilitiesKey)
        }
    }

    func dismissCapability(_ rawValue: String) {
        dismissedCapabilities.insert(rawValue)
    }

    func clearDismissal(_ rawValue: String) {
        if dismissedCapabilities.contains(rawValue) {
            dismissedCapabilities.remove(rawValue)
        }
    }

    func isCapabilityDismissed(_ rawValue: String) -> Bool {
        dismissedCapabilities.contains(rawValue)
    }

    init() {
        if let saved = UserDefaults.standard.string(forKey: "terminal"),
           let t = Terminal(rawValue: saved), t.isInstalled {
            self.terminal = t
        } else {
            self.terminal = Terminal.installed.first ?? .terminal
        }

        let savedRoot = UserDefaults.standard.string(forKey: "scanRoot") ?? ""
        if savedRoot.isEmpty {
            // Auto-detect a reasonable default
            let home = NSHomeDirectory()
            let candidates = ["\(home)/dev", "\(home)/Developer", "\(home)/projects", "\(home)/src"]
            self.scanRoot = candidates.first { FileManager.default.fileExists(atPath: $0) } ?? ""
        } else {
            self.scanRoot = savedRoot
        }

        if let saved = UserDefaults.standard.string(forKey: "mode"),
           let m = InteractionMode(rawValue: saved) {
            self.mode = m
        } else {
            self.mode = .learning
        }

        if UserDefaults.standard.object(forKey: "windowSnap.enabled") != nil {
            self.dragSnapEnabled = UserDefaults.standard.bool(forKey: "windowSnap.enabled")
        } else {
            self.dragSnapEnabled = true
        }

        if UserDefaults.standard.object(forKey: CompanionDefaultsKey.bridgeEnabled) != nil {
            self.companionBridgeEnabled = UserDefaults.standard.bool(forKey: CompanionDefaultsKey.bridgeEnabled)
        } else {
            self.companionBridgeEnabled = false
        }

        if UserDefaults.standard.object(forKey: CompanionDefaultsKey.trackpadEnabled) != nil {
            self.companionTrackpadEnabled = UserDefaults.standard.bool(forKey: CompanionDefaultsKey.trackpadEnabled)
        } else {
            self.companionTrackpadEnabled = false
        }

        if UserDefaults.standard.object(forKey: "mouseGestures.enabled") != nil {
            self.mouseGesturesEnabled = UserDefaults.standard.bool(forKey: "mouseGestures.enabled")
        } else {
            self.mouseGesturesEnabled = true
        }

        if UserDefaults.standard.object(forKey: "mouseGestures.hud.visualEnabled") != nil {
            self.mouseGestureHUDVisualEnabled = UserDefaults.standard.bool(forKey: "mouseGestures.hud.visualEnabled")
        } else {
            self.mouseGestureHUDVisualEnabled = true
        }

        if UserDefaults.standard.object(forKey: "mouseGestures.hud.audioEnabled") != nil {
            self.mouseGestureHUDAudioEnabled = UserDefaults.standard.bool(forKey: "mouseGestures.hud.audioEnabled")
        } else {
            self.mouseGestureHUDAudioEnabled = true
        }

        if let savedStyle = UserDefaults.standard.string(forKey: "mouseGestures.hud.style"),
           let style = MouseGestureHUDStyle(rawValue: savedStyle) {
            self.mouseGestureHUDStyle = style
        } else {
            self.mouseGestureHUDStyle = .technical
        }

        if let savedTileStyle = UserDefaults.standard.string(forKey: "tilePointer.hud.style"),
           let style = TilePointerHUDStyle(rawValue: savedTileStyle) {
            self.tilePointerHUDStyle = style
        } else {
            self.tilePointerHUDStyle = .matrix
        }
        if UserDefaults.standard.object(forKey: "tilePointer.soundEffects.enabled") != nil {
            self.tilePointerSoundEffectsEnabled = UserDefaults.standard.bool(forKey: "tilePointer.soundEffects.enabled")
        } else {
            self.tilePointerSoundEffectsEnabled = true
        }

        if let savedShape = UserDefaults.standard.string(forKey: "cursorMarker.shape"),
           let shape = CursorMarkerShape(rawValue: savedShape),
           CursorMarkerShape.settingsOptions.contains(shape) {
            self.cursorMarkerShape = shape
        } else {
            self.cursorMarkerShape = .default
        }

        if UserDefaults.standard.object(forKey: "cursorMarker.angleDeg") != nil {
            self.cursorMarkerAngleDeg = Self.normalizedCursorMarkerAngle(UserDefaults.standard.integer(forKey: "cursorMarker.angleDeg"))
        } else {
            self.cursorMarkerAngleDeg = -8
        }

        if let savedSize = UserDefaults.standard.string(forKey: "cursorMarker.size"),
           let size = CursorMarkerSize(rawValue: savedSize),
           CursorMarkerSize.settingsOptions.contains(size) {
            self.cursorMarkerSize = size
        } else {
            self.cursorMarkerSize = .default
        }

        if UserDefaults.standard.object(forKey: "keyboardRemaps.enabled") != nil {
            self.keyboardRemapsEnabled = UserDefaults.standard.bool(forKey: "keyboardRemaps.enabled")
        } else {
            self.keyboardRemapsEnabled = true
        }

        var holdMode: CtrlOptionHoldMode = .tileHUD
        if let saved = UserDefaults.standard.string(forKey: "ctrlOptionHold.mode"),
           let mode = CtrlOptionHoldMode(rawValue: saved) {
            holdMode = mode
        } else if UserDefaults.standard.object(forKey: "spatialLens.enabled") != nil,
                  UserDefaults.standard.bool(forKey: "spatialLens.enabled") {
            // An explicit Spatial Lens opt-in survives the single-owner migration.
            holdMode = .spatialLens
        }
        // A saved Spatial Lens choice falls back to the Tile HUD in the free build.
        self.ctrlOptionHoldMode = CtrlOptionHoldMode.available.contains(holdMode) ? holdMode : .tileHUD

        if UserDefaults.standard.object(forKey: "spaceSwitchKeys.enabled") != nil {
            self.spaceSwitchKeysEnabled = UserDefaults.standard.bool(forKey: "spaceSwitchKeys.enabled")
        } else {
            self.spaceSwitchKeysEnabled = true
        }

        if let saved = UserDefaults.standard.string(forKey: "spaceSwitchKeys.bezelPosition"),
           let position = SpaceSwitchBezelPosition(rawValue: saved) {
            self.spaceSwitchBezelPosition = position
        } else {
            self.spaceSwitchBezelPosition = .center
        }

        if UserDefaults.standard.object(forKey: "spaceSwitchKeys.glide") != nil {
            self.spaceSwitchGlideEnabled = UserDefaults.standard.bool(forKey: "spaceSwitchKeys.glide")
        } else {
            self.spaceSwitchGlideEnabled = false
        }
        if UserDefaults.standard.object(forKey: "layers.confirmSeconds") != nil {
            self.layerSwitchConfirmSeconds = UserDefaults.standard.double(forKey: "layers.confirmSeconds")
        } else {
            self.layerSwitchConfirmSeconds = 5
        }
        // Search & OCR. Default off until the user explicitly enables it from
        // the Permissions Assistant or Search settings. Honors any explicit
        // ocr.disabled value already saved (true=off, false=on).
        if UserDefaults.standard.object(forKey: "ocr.disabled") != nil {
            self.ocrEnabled = !UserDefaults.standard.bool(forKey: "ocr.disabled")
        } else {
            self.ocrEnabled = false
        }

        let savedInterval = UserDefaults.standard.double(forKey: "ocr.interval")
        self.ocrQuickInterval = savedInterval > 0 ? savedInterval : 60

        let savedDeep = UserDefaults.standard.double(forKey: "ocr.deepInterval")
        self.ocrDeepInterval = savedDeep > 0 ? savedDeep : 7200

        let savedQL = UserDefaults.standard.integer(forKey: "ocr.quickLimit")
        self.ocrQuickLimit = savedQL > 0 ? savedQL : 5

        let savedDL = UserDefaults.standard.integer(forKey: "ocr.deepLimit")
        self.ocrDeepLimit = savedDL > 0 ? savedDL : 15

        let savedBudget = UserDefaults.standard.integer(forKey: "ocr.deepBudget")
        self.ocrDeepBudget = savedBudget > 0 ? savedBudget : 3

        let savedAcc = UserDefaults.standard.string(forKey: "ocr.accuracy") ?? "accurate"
        self.ocrAccuracy = savedAcc

        let savedRetention = UserDefaults.standard.integer(forKey: "ocr.retentionDays")
        self.ocrRetentionDays = savedRetention > 0 ? savedRetention : 7

        let dismissed = UserDefaults.standard.stringArray(forKey: Self.dismissedCapabilitiesKey) ?? []
        self.dismissedCapabilities = Set(dismissed)
    }


    static func normalizedCursorMarkerAngle(_ value: Int) -> Int {
        value <= -12 ? -16 : -8
    }
}
