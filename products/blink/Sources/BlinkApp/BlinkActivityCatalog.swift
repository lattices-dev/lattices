import Foundation

/// Stable identifiers shared by the command palette, Guide, and contextual
/// hints. Raw values are persistence-safe: UI copy may change without changing
/// the identity of an activity.
enum BlinkActivityID: String, CaseIterable, Identifiable {
    case newNote = "note.new"
    case commandPalette = "app.command-palette"
    case toggleBlink = "visibility.blink"
    case showGrid = "arrange.grid"
    case openSettings = "app.settings"
    case openGuide = "app.guide"
    case quitBlink = "app.quit"

    case searchNotes = "popover.search"
    case openSelectedNote = "popover.open-selected-note"
    case createFromCapture = "popover.create-from-capture"
    case dictateCapture = "popover.dictate"

    case readSelection = "reader.read-selection"
    case toggleReadEdit = "note.toggle-read-edit"
    case toggleFocus = "note.toggle-focus"
    case saveNote = "note.save"
    case quietNote = "note.quiet"
    case editReadingNote = "note.edit-from-reader"
    case standardEditing = "editor.standard-editing"
    case openNoteLink = "note.open-link"

    case movePanel = "panel.move"
    case resizePanel = "panel.resize"
    case flingPanel = "panel.fling"
    case shakeToShade = "panel.shake-to-shade"
    case doubleClickToShade = "panel.double-click-to-shade"
    case openNoteMenu = "panel.context-menu"
    case placeOnGrid = "grid.place"
    case cancelGrid = "grid.cancel"

    case chooseNoteStyle = "note.choose-style"
    case hideNote = "note.hide"
    case closeNote = "note.close"
    case copyNoteID = "note.copy-id"
    case copyNoteMarkdown = "note.copy-markdown"
    case copyNoteFilePath = "note.copy-file-path"
    case openNoteFile = "note.open-file"
    case revealNoteInFinder = "note.reveal-in-finder"
    case revealNotesFolder = "files.reveal-notes-folder"
    case openConfigFile = "files.open-config"

    var id: String { rawValue }
}

/// Capability grouping used by command search and reference metadata. The
/// order of `allCases` is the intended presentation order.
enum BlinkActivityGroup: String, CaseIterable, Identifiable {
    case capture = "Capture"
    case findAndOpen = "Find & Open"
    case arrange = "Arrange"
    case readAndWrite = "Read & Write"
    case focusAndVisibility = "Focus & Visibility"
    case styleAndFiles = "Style & Files"

    var id: String { rawValue }
    var displayTitle: String { rawValue }
}

/// Where an activity's trigger is active. `global` means a registered system-
/// wide Carbon hotkey; `application` means Blink must be frontmost.
enum BlinkActivityScope: String, CaseIterable, Identifiable {
    case global = "Global"
    case application = "Blink"
    case popover = "Popover"
    case panel = "Panel"
    case grid = "Grid"
    case editor = "Editor"

    var id: String { rawValue }
    var displayTitle: String { self == .application ? "Canvas" : rawValue }
}

/// One discoverable Blink capability. Resolvers intentionally remain closures:
/// shortcuts and context can change while the Guide or palette is still open.
@MainActor
struct BlinkActivity: Identifiable {
    typealias ShortcutResolver = @MainActor () -> String?
    typealias Availability = @MainActor () -> Bool
    typealias Action = @MainActor () -> Void

    let id: BlinkActivityID
    let title: String
    let description: String
    let symbolName: String
    let group: BlinkActivityGroup
    let scope: BlinkActivityScope
    let keywords: [String]

    private let shortcutResolver: ShortcutResolver
    private let availability: Availability
    private let execution: Action?

    init(
        id: BlinkActivityID,
        title: String,
        description: String,
        symbolName: String,
        group: BlinkActivityGroup,
        scope: BlinkActivityScope,
        keywords: [String] = [],
        shortcut: @escaping ShortcutResolver = { nil },
        availability: @escaping Availability = { true },
        execution: Action? = nil
    ) {
        self.id = id
        self.title = title
        self.description = description
        self.symbolName = symbolName
        self.group = group
        self.scope = scope
        self.keywords = keywords
        shortcutResolver = shortcut
        self.availability = availability
        self.execution = execution
    }

    /// Resolved on every read. Configurable bindings therefore hot-apply to
    /// Settings, Guide, palette rows, and contextual key hints together.
    var shortcutDisplay: String? { shortcutResolver() }

    /// Dynamic context check (for example, whether a current note exists).
    var isAvailable: Bool { availability() }

    /// Help-only gestures have no execution closure and are excluded from the
    /// command palette without needing a second metadata model.
    var isExecutable: Bool { execution != nil }

    /// Execute only when the activity is still available at invocation time.
    func perform() {
        guard isAvailable else { return }
        execution?()
    }

    /// Multi-token, case-insensitive matching over user-facing and synonym
    /// metadata. Every token must match, so "copy path" behaves predictably.
    func matches(_ query: String) -> Bool {
        let tokens = query.lowercased().split(whereSeparator: \Character.isWhitespace)
        guard !tokens.isEmpty else { return true }
        let haystack = ([title, description, group.displayTitle, scope.displayTitle] + keywords)
            .joined(separator: " ")
            .lowercased()
        return tokens.allSatisfy { haystack.contains($0) }
    }
}

/// The single metadata source for Blink's Guide, command palette, shortcut
/// reference, and contextual hints. It knows no AppDelegate or panel-manager
/// details; integration supplies those capabilities as closures.
@MainActor
struct BlinkActivityCatalog {
    typealias Action = BlinkActivity.Action
    typealias Predicate = BlinkActivity.Availability

    struct Handlers {
        var newNote: Action?
        var toggleBlink: Action?
        var showGrid: Action?
        var openSettings: Action?
        var openGuide: Action?
        var revealNotesFolder: Action?
        var openConfigFile: Action?

        var toggleCurrentNoteMode: Action?
        var toggleCurrentNoteFocus: Action?
        var chooseCurrentNoteStyle: Action?
        var hideCurrentNote: Action?
        var closeCurrentNote: Action?
        var copyCurrentNoteID: Action?
        var copyCurrentNoteMarkdown: Action?
        var copyCurrentNoteFilePath: Action?
        var openCurrentNoteFile: Action?
        var revealCurrentNoteInFinder: Action?

        /// Evaluated immediately before rendering or executing a panel action.
        var currentNoteAvailable: Predicate

        init(
            newNote: Action? = nil,
            toggleBlink: Action? = nil,
            showGrid: Action? = nil,
            openSettings: Action? = nil,
            openGuide: Action? = nil,
            revealNotesFolder: Action? = nil,
            openConfigFile: Action? = nil,
            toggleCurrentNoteMode: Action? = nil,
            toggleCurrentNoteFocus: Action? = nil,
            chooseCurrentNoteStyle: Action? = nil,
            hideCurrentNote: Action? = nil,
            closeCurrentNote: Action? = nil,
            copyCurrentNoteID: Action? = nil,
            copyCurrentNoteMarkdown: Action? = nil,
            copyCurrentNoteFilePath: Action? = nil,
            openCurrentNoteFile: Action? = nil,
            revealCurrentNoteInFinder: Action? = nil,
            currentNoteAvailable: @escaping Predicate = { false }
        ) {
            self.newNote = newNote
            self.toggleBlink = toggleBlink
            self.showGrid = showGrid
            self.openSettings = openSettings
            self.openGuide = openGuide
            self.revealNotesFolder = revealNotesFolder
            self.openConfigFile = openConfigFile
            self.toggleCurrentNoteMode = toggleCurrentNoteMode
            self.toggleCurrentNoteFocus = toggleCurrentNoteFocus
            self.chooseCurrentNoteStyle = chooseCurrentNoteStyle
            self.hideCurrentNote = hideCurrentNote
            self.closeCurrentNote = closeCurrentNote
            self.copyCurrentNoteID = copyCurrentNoteID
            self.copyCurrentNoteMarkdown = copyCurrentNoteMarkdown
            self.copyCurrentNoteFilePath = copyCurrentNoteFilePath
            self.openCurrentNoteFile = openCurrentNoteFile
            self.revealCurrentNoteInFinder = revealCurrentNoteInFinder
            self.currentNoteAvailable = currentNoteAvailable
        }
    }

    let activities: [BlinkActivity]

    init(handlers: Handlers = .init()) {
        activities = Self.makeActivities(handlers: handlers)
    }

    /// Executable entries, including unavailable entries a palette may choose
    /// to show disabled in order to teach their contextual nature.
    var paletteActivities: [BlinkActivity] {
        activities.filter(\.isExecutable)
    }

    var availablePaletteActivities: [BlinkActivity] {
        paletteActivities.filter(\.isAvailable)
    }

    func activities(in group: BlinkActivityGroup) -> [BlinkActivity] {
        activities.filter { $0.group == group }
    }
}

// MARK: - Catalog contents

private extension BlinkActivityCatalog {
    static func makeActivities(handlers h: Handlers) -> [BlinkActivity] {
        let currentNoteAvailability: BlinkActivity.Availability = {
            h.currentNoteAvailable()
        }

        func configured(_ keyPath: KeyPath<BlinkConfig.Hotkeys, String>)
            -> BlinkActivity.ShortcutResolver
        {
            {
                let raw = BlinkConfigStore.shared.config.hotkeys[keyPath: keyPath]
                return KeyChord.parse(raw)?.display ?? raw
            }
        }

        func fixed(_ display: String) -> BlinkActivity.ShortcutResolver {
            { display }
        }

        func actionAvailability(_ action: Action?) -> BlinkActivity.Availability {
            { action != nil }
        }

        func currentActionAvailability(_ action: Action?) -> BlinkActivity.Availability {
            { action != nil && currentNoteAvailability() }
        }

        return [
            BlinkActivity(
                id: .newNote,
                title: "New Note",
                description: "Capture a new note from anywhere.",
                symbolName: "square.and.pencil",
                group: .capture,
                scope: .global,
                keywords: ["create", "capture", "write"],
                shortcut: configured(\.newNote),
                availability: actionAvailability(h.newNote),
                execution: h.newNote
            ),
            BlinkActivity(
                id: .dictateCapture,
                title: "Dictate a Capture",
                description: "Use macOS Dictation in the popover capture field.",
                symbolName: "mic.fill",
                group: .capture,
                scope: .popover,
                keywords: ["voice", "speech", "microphone"],
                shortcut: fixed("Mic button")
            ),
            BlinkActivity(
                id: .createFromCapture,
                title: "Create from Capture",
                description: "Turn the current capture text into a new note.",
                symbolName: "plus.rectangle.on.rectangle",
                group: .capture,
                scope: .popover,
                keywords: ["new", "query", "text"],
                shortcut: fixed("⌘↩")
            ),

            BlinkActivity(
                id: .commandPalette,
                title: "Command Palette",
                description: "Find any note or available Canvas action.",
                symbolName: "command",
                group: .findAndOpen,
                scope: .application,
                keywords: ["commands", "actions", "search"],
                shortcut: fixed("⌘K")
            ),
            BlinkActivity(
                id: .searchNotes,
                title: "Search Notes",
                description: "Search titles, contents, and tags from the popover or command palette.",
                symbolName: "magnifyingglass",
                group: .findAndOpen,
                scope: .popover,
                keywords: ["find", "filter", "tags"],
                shortcut: fixed("Type to search")
            ),
            BlinkActivity(
                id: .openSelectedNote,
                title: "Open Selected Note",
                description: "Open or focus the selected note's one panel.",
                symbolName: "arrow.turn.down.right",
                group: .findAndOpen,
                scope: .popover,
                keywords: ["return", "focus", "panel"],
                shortcut: fixed("↩")
            ),
            BlinkActivity(
                id: .openNoteLink,
                title: "Open a Note Link",
                description: "Follow a rendered wiki link to open or focus its note.",
                symbolName: "link",
                group: .findAndOpen,
                scope: .panel,
                keywords: ["wiki", "backlink", "click"],
                shortcut: fixed("Click [[link]]")
            ),
            BlinkActivity(
                id: .openSettings,
                title: "Settings",
                description: "Open Canvas settings.",
                symbolName: "gearshape",
                group: .findAndOpen,
                scope: .application,
                keywords: ["preferences", "configure"],
                shortcut: fixed("⌘,"),
                availability: actionAvailability(h.openSettings),
                execution: h.openSettings
            ),
            BlinkActivity(
                id: .openGuide,
                title: "Help & Shortcuts",
                description: "Learn Canvas's workspace model and review every shortcut.",
                symbolName: "questionmark.circle",
                group: .findAndOpen,
                scope: .application,
                keywords: ["help", "hints", "shortcuts", "learn"],
                shortcut: fixed("⌘?"),
                availability: actionAvailability(h.openGuide),
                execution: h.openGuide
            ),
            BlinkActivity(
                id: .quitBlink,
                title: "Quit Canvas",
                description: "Flush pending saves and quit Canvas.",
                symbolName: "power",
                group: .findAndOpen,
                scope: .application,
                keywords: ["exit", "close app"],
                shortcut: fixed("⌘Q")
            ),

            BlinkActivity(
                id: .showGrid,
                title: "Spatial Grid",
                description: "Show the nine keyboard-addressable placement slots.",
                symbolName: "square.grid.3x3",
                group: .arrange,
                scope: .global,
                keywords: ["constellation", "deploy", "place", "snap"],
                shortcut: configured(\.grid),
                availability: actionAvailability(h.showGrid),
                execution: h.showGrid
            ),
            BlinkActivity(
                id: .placeOnGrid,
                title: "Place on the Grid",
                description: "Move the active or most recently active note into a 3×3 slot.",
                symbolName: "rectangle.grid.3x2",
                group: .arrange,
                scope: .grid,
                keywords: ["qwe", "asd", "zxc", "slot", "deploy"],
                shortcut: fixed("Q W E · A S D · Z X C")
            ),
            BlinkActivity(
                id: .cancelGrid,
                title: "Leave the Grid",
                description: "Dismiss the spatial grid without moving a note.",
                symbolName: "xmark.circle",
                group: .arrange,
                scope: .grid,
                keywords: ["escape", "cancel", "dismiss"],
                shortcut: fixed("⎋")
            ),
            BlinkActivity(
                id: .movePanel,
                title: "Move a Panel",
                description: "Drag the top band to place a note anywhere on the desktop.",
                symbolName: "arrow.up.and.down.and.arrow.left.and.right",
                group: .arrange,
                scope: .panel,
                keywords: ["drag", "position", "geometry"],
                shortcut: fixed("Drag top band")
            ),
            BlinkActivity(
                id: .resizePanel,
                title: "Resize a Panel",
                description: "Resize a note from any window edge; its geometry is remembered.",
                symbolName: "arrow.up.left.and.arrow.down.right",
                group: .arrange,
                scope: .panel,
                keywords: ["size", "geometry", "edge"],
                shortcut: fixed("Drag an edge")
            ),
            BlinkActivity(
                id: .flingPanel,
                title: "Fling a Panel",
                description: "Release a fast drag to glide the note and bounce it off screen edges.",
                symbolName: "cursorarrow.motionlines",
                group: .arrange,
                scope: .panel,
                keywords: ["momentum", "physics", "throw", "bounce"],
                shortcut: fixed("Fast drag + release")
            ),

            BlinkActivity(
                id: .readSelection,
                title: "Read Selection",
                description: "Lift the selection in any app into a focused reading layer. ⌘S keeps it as a note.",
                symbolName: "text.viewfinder",
                group: .readAndWrite,
                scope: .global,
                keywords: ["reader", "terminal", "selection", "focus", "reflow"],
                shortcut: configured(\.reader)
            ),
            BlinkActivity(
                id: .toggleReadEdit,
                title: "Flip Read / Edit",
                description: "Switch the same panel between rendered reading and markdown editing.",
                symbolName: "book.pages",
                group: .readAndWrite,
                scope: .panel,
                keywords: ["preview", "markdown", "mode", "write"],
                shortcut: configured(\.toggleMode),
                availability: currentActionAvailability(h.toggleCurrentNoteMode),
                execution: h.toggleCurrentNoteMode
            ),
            BlinkActivity(
                id: .editReadingNote,
                title: "Edit a Reading Note",
                description: "Flip a rendered note into edit mode in place.",
                symbolName: "pencil",
                group: .readAndWrite,
                scope: .panel,
                keywords: ["preview", "reader", "write"],
                shortcut: fixed("Double-click note")
            ),
            BlinkActivity(
                id: .saveNote,
                title: "Save Now",
                description: "Flush the current edit immediately; Canvas also saves automatically.",
                symbolName: "square.and.arrow.down",
                group: .readAndWrite,
                scope: .editor,
                keywords: ["flush", "write", "disk"],
                shortcut: fixed("⌘S")
            ),
            BlinkActivity(
                id: .standardEditing,
                title: "Standard Editing",
                description: "Undo, redo, cut, copy, paste, and select all use standard macOS keys.",
                symbolName: "text.cursor",
                group: .readAndWrite,
                scope: .editor,
                keywords: ["undo", "redo", "cut", "copy", "paste", "select all"],
                shortcut: fixed("⌘Z · ⇧⌘Z · ⌘X · ⌘C · ⌘V · ⌘A")
            ),

            BlinkActivity(
                id: .toggleBlink,
                title: "Show or Hide All Notes",
                description: "Hide every note, or restore the whole arrangement.",
                symbolName: "eye",
                group: .focusAndVisibility,
                scope: .global,
                keywords: ["show", "hide", "visibility", "all"],
                shortcut: configured(\.blink),
                availability: actionAvailability(h.toggleBlink),
                execution: h.toggleBlink
            ),
            BlinkActivity(
                id: .toggleFocus,
                title: "Focus Mode",
                description: "Quiet the desktop and recede the other notes around the current panel.",
                symbolName: "circle.dashed",
                group: .focusAndVisibility,
                scope: .panel,
                keywords: ["dim", "distraction", "quiet"],
                shortcut: configured(\.focus),
                availability: currentActionAvailability(h.toggleCurrentNoteFocus),
                execution: h.toggleCurrentNoteFocus
            ),
            BlinkActivity(
                id: .quietNote,
                title: "Step Down",
                description: "Leave edit mode first, then leave focus mode on the next press.",
                symbolName: "escape",
                group: .focusAndVisibility,
                scope: .panel,
                keywords: ["escape", "cancel", "read", "focus"],
                shortcut: fixed("⎋")
            ),
            BlinkActivity(
                id: .shakeToShade,
                title: "Shake to Shade",
                description: "Shake a panel side to side while dragging to fold or unfold it.",
                symbolName: "waveform.path",
                group: .focusAndVisibility,
                scope: .panel,
                keywords: ["windowshade", "fold", "collapse", "gesture"],
                shortcut: fixed("Shake while dragging")
            ),
            BlinkActivity(
                id: .doubleClickToShade,
                title: "Shade from the Top Band",
                description: "Fold or unfold a panel without disturbing its remembered full size.",
                symbolName: "rectangle.compress.vertical",
                group: .focusAndVisibility,
                scope: .panel,
                keywords: ["windowshade", "fold", "collapse", "gesture"],
                shortcut: fixed("Double-click top band")
            ),
            BlinkActivity(
                id: .hideNote,
                title: "Hide Current Note",
                description: "Remove the note from the desktop without closing its panel.",
                symbolName: "eye.slash",
                group: .focusAndVisibility,
                scope: .panel,
                keywords: ["visibility", "order out"],
                availability: currentActionAvailability(h.hideCurrentNote),
                execution: h.hideCurrentNote
            ),
            BlinkActivity(
                id: .closeNote,
                title: "Close Current Note",
                description: "Flush pending edits, then close the panel.",
                symbolName: "xmark",
                group: .focusAndVisibility,
                scope: .panel,
                keywords: ["window", "dismiss", "flush"],
                shortcut: fixed("⌘W"),
                availability: currentActionAvailability(h.closeCurrentNote),
                execution: h.closeCurrentNote
            ),

            BlinkActivity(
                id: .openNoteMenu,
                title: "Note Action Menu",
                description: "See file, copy, style, visibility, and close actions for a note.",
                symbolName: "cursorarrow.click.2",
                group: .styleAndFiles,
                scope: .panel,
                keywords: ["context", "right click", "actions"],
                shortcut: fixed("Right-click note")
            ),
            BlinkActivity(
                id: .chooseNoteStyle,
                title: "Choose Note Style",
                description: "Apply a sheet treatment to the current note.",
                symbolName: "paintpalette",
                group: .styleAndFiles,
                scope: .panel,
                keywords: ["theme", "sheet", "appearance", "treatment"],
                availability: currentActionAvailability(h.chooseCurrentNoteStyle),
                execution: h.chooseCurrentNoteStyle
            ),
            BlinkActivity(
                id: .copyNoteID,
                title: "Copy Note ID",
                description: "Copy the stable agent-facing identifier for the current note.",
                symbolName: "number",
                group: .styleAndFiles,
                scope: .panel,
                keywords: ["identifier", "agent", "clipboard"],
                availability: currentActionAvailability(h.copyCurrentNoteID),
                execution: h.copyCurrentNoteID
            ),
            BlinkActivity(
                id: .copyNoteMarkdown,
                title: "Copy Entire Note as Markdown",
                description: "Copy the current note's complete markdown source.",
                symbolName: "doc.on.doc",
                group: .styleAndFiles,
                scope: .panel,
                keywords: ["source", "clipboard", "content"],
                availability: currentActionAvailability(h.copyCurrentNoteMarkdown),
                execution: h.copyCurrentNoteMarkdown
            ),
            BlinkActivity(
                id: .copyNoteFilePath,
                title: "Copy Note File Path",
                description: "Copy the current note's markdown path.",
                symbolName: "link",
                group: .styleAndFiles,
                scope: .panel,
                keywords: ["file", "clipboard", "location"],
                availability: currentActionAvailability(h.copyCurrentNoteFilePath),
                execution: h.copyCurrentNoteFilePath
            ),
            BlinkActivity(
                id: .openNoteFile,
                title: "Open Markdown File",
                description: "Open the current note's backing file in its default app.",
                symbolName: "doc.text",
                group: .styleAndFiles,
                scope: .panel,
                keywords: ["external", "source", "disk"],
                availability: currentActionAvailability(h.openCurrentNoteFile),
                execution: h.openCurrentNoteFile
            ),
            BlinkActivity(
                id: .revealNoteInFinder,
                title: "Reveal Note in Finder",
                description: "Show the current note's backing markdown file in Finder.",
                symbolName: "folder",
                group: .styleAndFiles,
                scope: .panel,
                keywords: ["file", "location", "disk"],
                availability: currentActionAvailability(h.revealCurrentNoteInFinder),
                execution: h.revealCurrentNoteInFinder
            ),
            BlinkActivity(
                id: .revealNotesFolder,
                title: "Reveal Notes Folder",
                description: "Open Canvas's notes directory in Finder.",
                symbolName: "folder",
                group: .styleAndFiles,
                scope: .application,
                keywords: ["files", "markdown", "directory", "finder"],
                availability: actionAvailability(h.revealNotesFolder),
                execution: h.revealNotesFolder
            ),
            BlinkActivity(
                id: .openConfigFile,
                title: "Open Config File",
                description: "Open Canvas's agent-editable configuration file.",
                symbolName: "doc.badge.gearshape",
                group: .styleAndFiles,
                scope: .application,
                keywords: ["json", "settings", "theme", "hotkeys"],
                availability: actionAvailability(h.openConfigFile),
                execution: h.openConfigFile
            ),
        ]
    }
}
