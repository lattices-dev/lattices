import Foundation

final class TmuxModel: ObservableObject {
    static let shared = TmuxModel()

    @Published private(set) var sessions: [TmuxSession] = []
    @Published private(set) var isAvailable: Bool = TmuxQuery.isAvailable
    private var timer: Timer?
    private let pollWorker = BackgroundPollWorker(label: "lattices.tmux-inventory")
    private let query: () -> [TmuxSession]

    init(query: @escaping () -> [TmuxSession] = TmuxQuery.listSessions) {
        self.query = query
    }

    func start(interval: TimeInterval = 3.0) {
        guard timer == nil else { return }

        if !isAvailable {
            DiagnosticLog.shared.warn("TmuxModel: tmux not found — session features disabled")
            return
        }

        DiagnosticLog.shared.info("TmuxModel: starting (interval=\(interval)s)")
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func poll() {
        // Process launch and tmux's response can take hundreds of milliseconds.
        // Never put either on the input/animation thread, or queue obsolete scans.
        pollWorker.request { [weak self] in
            guard let self else { return }
            let fresh = self.query()
            DispatchQueue.main.async {
                let changed = self.sessionsChanged(old: self.sessions, new: fresh)
                self.sessions = fresh
                if changed {
                    EventBus.shared.post(.tmuxChanged(sessions: fresh))
                }
            }
        }
    }

    func isRunning(_ name: String) -> Bool {
        sessions.contains { $0.name == name }
    }

    private func sessionsChanged(old: [TmuxSession], new: [TmuxSession]) -> Bool {
        guard old.count == new.count else { return true }
        let oldNames = Set(old.map(\.name))
        let newNames = Set(new.map(\.name))
        if oldNames != newNames { return true }
        // Check pane counts changed
        for newSession in new {
            guard let oldSession = old.first(where: { $0.name == newSession.name }) else { return true }
            if oldSession.panes.count != newSession.panes.count { return true }
            if oldSession.attached != newSession.attached { return true }
        }
        return false
    }
}
