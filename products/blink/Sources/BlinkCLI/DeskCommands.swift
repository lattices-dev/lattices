import ArgumentParser
import AppKit
import BlinkCore
import Foundation

/// Live panel verbs for agents and scripts. Note content continues to use the
/// file-backed commands; this narrow channel only asks the running app to
/// realize a note on the desktop.
struct DeskCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "desk",
        abstract: "Open and arrange note panels in the running Canvas app.",
        subcommands: [
            DeskOpen.self, DeskMove.self, DeskFocus.self, DeskClose.self, DeskScreens.self,
            DeskSave.self, DeskRestore.self, DeskList.self, DeskShow.self, DeskRemove.self,
        ]
    )
}

struct DeskSave: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "save", abstract: "Save the running panel arrangement.")
    @Argument var name: String
    func run() throws { _ = try BlinkSocketClient.call(method: "desk.save", params: ["name": name]); print(name) }
}

struct DeskRestore: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "restore", abstract: "Restore a saved panel arrangement.")
    @Argument var name: String
    func run() throws { _ = try BlinkSocketClient.call(method: "desk.restore", params: ["name": name]); print(name) }
}

struct DeskList: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "ls", abstract: "List saved desk arrangements.")
    @Flag var json = false
    func run() throws {
        let layouts = try DeskLayoutStore().list()
        if json { try printJSON(layouts) } else { layouts.forEach { print("\($0.name)  \($0.panels.count) panels") } }
    }
}

struct DeskShow: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "show", abstract: "Show a saved desk arrangement.")
    @Argument var name: String
    @Flag var json = false
    func run() throws {
        let layout = try DeskLayoutStore().load(name)
        if json { try printJSON(layout) } else {
            print("\(layout.name)  \(layout.panels.count) panels")
            layout.panels.forEach { print("\($0.id)  display \($0.display)  \(Int($0.frame.width))x\(Int($0.frame.height))") }
        }
    }
}

struct DeskRemove: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "rm", abstract: "Delete a saved desk arrangement.")
    @Argument var name: String
    func run() throws { try DeskLayoutStore().delete(name); print(name) }
}

struct DeskFrameOptions: ParsableArguments {
    @Option(help: "Left edge in points from the display's visible left edge.")
    var x: Double?

    @Option(help: "Top edge in points from the display's visible top edge.")
    var y: Double?

    @Option(help: "Panel width in points (minimum 260).")
    var width: Double?

    @Option(help: "Panel height in points (minimum 120).")
    var height: Double?

    @Option(help: "One-based display number (defaults to the panel's current display).")
    var display: Int?

    var isEmpty: Bool {
        x == nil && y == nil && width == nil && height == nil && display == nil
    }

    func validate() throws {
        if let x, !x.isFinite {
            throw ValidationError("--x must be a finite number")
        }
        if let y, !y.isFinite {
            throw ValidationError("--y must be a finite number")
        }
        if let width, !width.isFinite {
            throw ValidationError("--width must be a finite number")
        }
        if let height, !height.isFinite {
            throw ValidationError("--height must be a finite number")
        }
        if let width, width <= 0 {
            throw ValidationError("--width must be greater than zero")
        }
        if let height, height <= 0 {
            throw ValidationError("--height must be greater than zero")
        }
        if let display, display < 1 {
            throw ValidationError("--display must be one or greater")
        }
        if let display, display > NSScreen.screens.count {
            throw ValidationError(
                "--display \(display) does not exist (\(NSScreen.screens.count) available)"
            )
        }
    }

    func add(to userInfo: inout [AnyHashable: Any]) {
        if let x { userInfo[BlinkDeskCommand.Key.x] = x }
        if let y { userInfo[BlinkDeskCommand.Key.y] = y }
        if let width { userInfo[BlinkDeskCommand.Key.width] = width }
        if let height { userInfo[BlinkDeskCommand.Key.height] = height }
        if let display { userInfo[BlinkDeskCommand.Key.display] = display }
    }
}

struct DeskOpen: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "open",
        abstract: "Open or focus a note, optionally at an exact frame."
    )

    @Argument(help: "The note id.") var id: String
    @OptionGroup var frame: DeskFrameOptions

    mutating func validate() throws { try frame.validate() }

    func run() throws {
        _ = try existingNote(id: id)
        var userInfo = deskUserInfo(.open, id: id)
        frame.add(to: &userInfo)
        try postDeskCommand(userInfo)
        print(id)
    }
}

struct DeskMove: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "move",
        abstract: "Move or resize an open note with a visible lock animation."
    )

    @Argument(help: "The note id.") var id: String
    @OptionGroup var frame: DeskFrameOptions
    @Flag(help: "Apply the frame immediately instead of animating it.") var instant = false

    mutating func validate() throws {
        try frame.validate()
        if frame.isEmpty {
            throw ValidationError(
                "pass at least one of --x, --y, --width, --height, or --display"
            )
        }
    }

    func run() throws {
        _ = try existingNote(id: id)
        var userInfo = deskUserInfo(.move, id: id)
        frame.add(to: &userInfo)
        userInfo[BlinkDeskCommand.Key.animated] = !instant
        try postDeskCommand(userInfo)
        print(id)
    }
}

struct DeskFocus: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "focus",
        abstract: "Raise a note panel, opening it when needed."
    )

    @Argument(help: "The note id.") var id: String

    func run() throws {
        _ = try existingNote(id: id)
        try postDeskCommand(deskUserInfo(.focus, id: id))
        print(id)
    }
}

struct DeskClose: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "close",
        abstract: "Close a note panel without deleting its note."
    )

    @Argument(help: "The note id.") var id: String

    func run() throws {
        _ = try existingNote(id: id)
        try postDeskCommand(deskUserInfo(.close, id: id))
        print(id)
    }
}

struct DeskScreens: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "screens",
        abstract: "List display geometry for responsive desk scripts."
    )

    @Flag(help: "Structured output.") var json = false

    func run() throws {
        let screens = NSScreen.screens.enumerated().map { index, screen in
            DeskScreenJSON(number: index + 1, screen: screen)
        }
        if json {
            try printJSON(screens)
        } else {
            for screen in screens {
                print(
                    "\(screen.number)  \(Int(screen.visible.width))x\(Int(screen.visible.height))"
                        + "  \(screen.name)"
                )
            }
        }
    }
}

private struct DeskScreenJSON: Encodable {
    struct Frame: Encodable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double

        init(_ rect: NSRect) {
            x = rect.origin.x
            y = rect.origin.y
            width = rect.width
            height = rect.height
        }
    }

    let number: Int
    let name: String
    let frame: Frame
    let visible: Frame
    let scale: Double

    init(number: Int, screen: NSScreen) {
        self.number = number
        name = screen.localizedName
        frame = Frame(screen.frame)
        visible = Frame(screen.visibleFrame)
        scale = screen.backingScaleFactor
    }
}

private func deskUserInfo(
    _ verb: BlinkDeskCommand.Verb,
    id: String
) -> [AnyHashable: Any] {
    [
        BlinkDeskCommand.Key.verb: verb.rawValue,
        BlinkDeskCommand.Key.noteID: id,
        BlinkDeskCommand.Key.home: BlinkDeskCommand.canonicalHomePath(),
    ]
}

private func postDeskCommand(_ baseUserInfo: [AnyHashable: Any]) throws {
    let requestID = UUID().uuidString.lowercased()
    var userInfo = baseUserInfo
    userInfo[BlinkDeskCommand.Key.requestID] = requestID

    let waiter = DeskResponseWaiter(requestID: requestID)
    let center = DistributedNotificationCenter.default()
    center.addObserver(
        waiter,
        selector: #selector(DeskResponseWaiter.receive(_:)),
        name: BlinkDeskCommand.responseNotificationName,
        object: nil
    )
    defer { center.removeObserver(waiter) }

    center.post(
        name: BlinkDeskCommand.notificationName,
        object: nil,
        userInfo: userInfo
    )
    guard let response = waiter.wait(timeout: 2) else {
        throw ValidationError(
            "Canvas did not acknowledge the desk command; make sure the app is running with the same CANVAS_HOME or BLINK_HOME"
        )
    }
    guard response.success else {
        throw ValidationError(response.error ?? "Canvas could not apply the desk command")
    }
}

private final class DeskResponseWaiter: NSObject {
    struct Response {
        let success: Bool
        let error: String?
    }

    private let requestID: String
    private let lock = NSLock()
    private var response: Response?

    init(requestID: String) {
        self.requestID = requestID
        super.init()
    }

    @objc func receive(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              userInfo[BlinkDeskCommand.Key.requestID] as? String == requestID,
              let success = (userInfo[BlinkDeskCommand.Key.success] as? NSNumber)?.boolValue
        else { return }

        lock.lock()
        response = Response(
            success: success,
            error: userInfo[BlinkDeskCommand.Key.error] as? String
        )
        lock.unlock()
    }

    func wait(timeout: TimeInterval) -> Response? {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            lock.lock()
            let current = response
            lock.unlock()
            if let current { return current }

            // Distributed notifications may target this thread's run loop.
            // Service it in short slices while still permitting delivery from
            // the notification center's helper thread.
            _ = RunLoop.current.run(
                mode: .default,
                before: min(deadline, Date(timeIntervalSinceNow: 0.05))
            )
        }

        lock.lock()
        defer { lock.unlock() }
        return response
    }
}
