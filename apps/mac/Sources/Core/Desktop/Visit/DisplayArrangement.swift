import AppKit

/// The only display mutation entry point. A trial owns its rollback independently
/// of the Machines page, so navigation cannot accidentally keep an arrangement.
@MainActor
final class DisplayArrangement: ObservableObject {
    static let shared = DisplayArrangement()
    @Published private(set) var pending = false
    @Published private(set) var error: String?
    private var original: [CGDirectDisplayID: CGPoint] = [:]
    private var timer: Timer?
    /// How far a make-main trial moved everything, so a revert moves the machines back.
    private var shifted: CGVector?
    private let shiftMachines: (Double, Double) -> Void
    private let readScreens: () -> [VisitController.Screen]
    private let configure: ([CGDirectDisplayID: CGPoint]) throws -> Void
    private let schedule: (TimeInterval, @escaping () -> Void) -> Timer

    init(readScreens: @escaping () -> [VisitController.Screen] = { VisitController.screens() },
         shiftMachines: @escaping (Double, Double) -> Void = { VisitTrust.shared.shiftPlacements(dx: $0, dy: $1) },
         configure: @escaping ([CGDirectDisplayID: CGPoint]) throws -> Void = DisplayArrangement.configureDisplays,
         schedule: @escaping (TimeInterval, @escaping () -> Void) -> Timer = { seconds, action in
             Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { _ in action() }
         }) {
        self.shiftMachines = shiftMachines
        self.readScreens = readScreens; self.configure = configure; self.schedule = schedule
    }

    func apply(_ frames: [CGDirectDisplayID: CGRect]) throws {
        guard !pending, !frames.isEmpty else { throw VisitTrust.Failure.bad("An arrangement trial is already pending") }
        let screens = readScreens()
        guard Set(frames.keys) == Set(screens.map(\.displayID)), frames.values.allSatisfy({
            MachineGeometry.Placement($0).valid && abs($0.minX) < Double(Int32.max) && abs($0.minY) < Double(Int32.max)
        }) else { throw VisitTrust.Failure.bad("Displays changed. Revert and try again.") }
        original = Dictionary(uniqueKeysWithValues: screens.map { ($0.displayID, $0.frame.origin) })
        do { try configure(frames.mapValues(\.origin)) }
        catch { original = [:]; throw error }
        pending = true
        timer = schedule(15) { [weak self] in self?.revert() }
    }
    /// Makes display `number` the main one (the menu bar's) by moving the whole
    /// arrangement so it sits at the origin; the displays keep their places
    /// relative to each other. A trial like any other apply.
    func makeMain(_ number: Int) throws {
        guard !pending else { throw VisitTrust.Failure.bad("An arrangement trial is already pending") }
        let screens = readScreens()
        guard let target = screens.first(where: { $0.number == number }) else { throw VisitTrust.Failure.bad("No display \(number)") }
        guard !target.main else { return }
        let dx = target.frame.minX, dy = target.frame.minY
        try apply(Dictionary(uniqueKeysWithValues: screens.map { ($0.displayID, $0.frame.offsetBy(dx: -dx, dy: -dy)) }))
        shiftMachines(-dx, -dy)
        shifted = CGVector(dx: -dx, dy: -dy)
    }
    func keep() { timer?.invalidate(); timer = nil; original = [:]; shifted = nil; pending = false; error = nil }
    func revert() {
        timer?.invalidate(); timer = nil
        do {
            if !original.isEmpty { try configure(original) }
            if let shifted { shiftMachines(-shifted.dx, -shifted.dy) }
            original = [:]; shifted = nil; pending = false; error = nil
        }
        catch { self.error = "Could not restore displays: \(error)" }
    }
    nonisolated private static func configureDisplays(_ origins: [CGDirectDisplayID: CGPoint]) throws {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { throw VisitTrust.Failure.bad("Could not begin display configuration") }
        for (id, point) in origins {
            guard CGConfigureDisplayOrigin(config, id, Int32(point.x.rounded()), Int32(point.y.rounded())) == .success else {
                CGCancelDisplayConfiguration(config); throw VisitTrust.Failure.bad("Could not move display \(id)")
            }
        }
        guard CGCompleteDisplayConfiguration(config, .permanently) == .success else {
            throw VisitTrust.Failure.bad("Could not apply display configuration")
        }
    }
}
