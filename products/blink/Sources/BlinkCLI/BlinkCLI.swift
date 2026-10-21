import ArgumentParser
import BlinkCore
import Foundation

/// The agent surface, layer 2: a CLI over
/// the exact same files and codec the app uses. Writes are atomic and
/// slug-safe via BlinkCore; the running app reconciles the directory and picks
/// every change up live — no IPC, no daemon, no racing.
@main
struct BlinkCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "canvas",
        abstract: "Canvas notes from the command line.",
        discussion: """
        Operates on the same files as the app: $CANVAS_HOME/Notes, then $BLINK_HOME/Notes when set, \
        else ~/Library/Application Support/Blink/Notes. Every command takes \
        --json for structured output. The blink command remains a compatibility alias.
        """,
        version: "2.3.0",
        subcommands: [
            Ls.self, Cat.self, New.self, Present.self, Append.self, Type.self, Write.self,
            Search.self, Rm.self, PathCommand.self, WorkspaceCommand.self, DeskCommand.self,
            Log.self,
        ]
    )
}

// MARK: - Commands

struct Ls: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List notes, most recently updated first."
    )

    @Flag(help: "Structured output.") var json = false
    @Option(name: .shortAndLong, help: "Show at most this many notes.") var limit: Int?

    func run() async throws {
        var notes = try await loadedStore().all()
        if let limit { notes = Array(notes.prefix(limit)) }
        try output(notes, json: json)
    }
}

struct Cat: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Print a note's markdown content (frontmatter stripped)."
    )

    @Argument(help: "The note id (slug).") var id: String
    @Flag(help: "Full note as JSON — content plus all metadata.") var json = false

    func run() throws {
        let note = try existingNote(id: id)
        if json {
            try printJSON(NoteJSON(note, full: true))
        } else {
            // Exact bytes, like cat(1) — no added trailing newline.
            FileHandle.standardOutput.write(Data(note.content.utf8))
        }
    }
}

struct New: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Create a note from arguments or stdin; prints the assigned id.",
        discussion: "The first line becomes the title; the id is a unique slug derived from it."
    )

    @Option(help: "Create the note inside this workspace (blink.workspace).")
    var workspace: String?
    @Option(help: "Who is writing (blink.lastWriter). Defaults to cli.")
    var writer: String?
    @Argument(parsing: .remaining, help: "Note content (omit to read stdin).")
    var content: [String] = []
    @Flag(help: "Structured output.") var json = false

    func run() async throws {
        var text = content.joined(separator: " ")
        if text.isEmpty, isatty(0) == 0 {
            text = String(
                decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self
            )
        }
        var presentation = NotePresentation()
        if let workspace {
            presentation.workspace = try WorkspaceStore.normalize(workspace)
        }
        let note = try await loadedStore().create(
            content: text,
            presentation: presentation,
            writer: attributedWriter(writer)
        )
        if json {
            try printJSON(NoteJSON(note, full: false))
        } else {
            print(note.id)
        }
    }
}

struct Present: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Create or update a note with content and presentation in one call.",
        discussion: """
        The compound arrival verb. Sets a note's markdown AND its blink: \
        presentation (style, slot, accent, …) in one write, get-or-create by id. \
        Only the presentation fields you pass are changed; the rest are preserved. \
        Omit content to change presentation alone. The running app reconciles the \
        write and applies the look live; slot is placement intent for the grid.
        """
    )

    @Argument(help: "The note id (slug); created if it doesn't exist.") var id: String
    @Argument(parsing: .allUnrecognized, help: "Markdown content (omit to keep existing / read stdin).")
    var content: [String] = []

    @Option(help: "Workspace to file this note under (blink.workspace).") var workspace: String?
    @Option(help: "Named style preset from config (blink.style).") var style: String?
    @Option(help: "Sheet template (blink.sheet).") var sheet: String?
    @Option(help: "Accent color, e.g. #9ece6a (blink.accent).") var accent: String?
    @Option(help: "Font family (blink.font).") var font: String?
    @Option(name: .customLong("font-size"), help: "Font size in px (blink.fontSize).") var fontSize: Double?
    @Option(name: .customLong("line-height"), help: "Line height (blink.lineHeight).") var lineHeight: Double?
    @Option(help: "Glass tint 0–1 (blink.tint).") var tint: Double?
    @Option(name: .customLong("tint-read"), help: "Read-mode tint 0–1 (blink.tintRead).") var tintRead: Double?
    @Option(name: .customLong("tint-edit"), help: "Edit-mode tint 0–1 (blink.tintEdit).") var tintEdit: Double?
    @Option(help: "Corner radius in px (blink.radius).") var radius: Double?
    @Option(help: "Grid slot 1–9 — placement intent (blink.slot).") var slot: Int?
    @Option(help: "Who is writing (blink.lastWriter). Defaults to cli.")
    var writer: String?
    @Flag(help: "Full note as JSON.") var json = false

    func run() throws {
        let canonicalID = Slug.generate(from: id)

        var text = content.joined(separator: " ")
        var haveContent = !text.isEmpty
        if !haveContent, isatty(0) == 0 {
            text = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
            haveContent = !text.isEmpty
        }

        let store = fileStore()
        let now = Date()
        var note: Note
        if let existing = try? store.load(id: canonicalID) {
            note = existing
            if haveContent { note.content = text }
            note.updatedAt = now
        } else {
            note = Note(id: canonicalID, content: haveContent ? text : "", createdAt: now, updatedAt: now)
        }

        var p = note.presentation
        if let workspace { p.workspace = try WorkspaceStore.normalize(workspace) }
        if let style { p.style = style }
        if let sheet { p.sheet = sheet }
        if let accent { p.accent = accent }
        if let font { p.font = font }
        if let fontSize { p.fontSize = fontSize }
        if let lineHeight { p.lineHeight = lineHeight }
        if let tint { p.tint = tint }
        if let tintRead { p.tintRead = tintRead }
        if let tintEdit { p.tintEdit = tintEdit }
        if let radius { p.radius = radius }
        if let slot { p.slot = slot }
        p.lastWriter = attributedWriter(writer)
        note.presentation = p

        try store.save(note, writer: p.lastWriter)
        if json {
            try printJSON(NoteJSON(note, full: true))
        } else {
            print(note.id)
        }
    }
}


struct Append: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Append text to an existing note from arguments or stdin."
    )

    @Argument(help: "The note id (slug).") var id: String
    // `allUnrecognized` lets agent-authored markdown begin with "-" without
    // needing a `--` terminator, while still recognizing `--json` anywhere.
    @Argument(parsing: .allUnrecognized, help: "Text to append (omit to read stdin).")
    var content: [String] = []
    @Flag(help: "Full updated note as JSON.") var json = false
    @Option(help: "Who is writing (blink.lastWriter). Defaults to cli.")
    var writer: String?

    func run() async throws {
        try await appendToNote(id: id, text: readText(content), json: json, writer: writer)
    }
}

struct Type: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Say something into a note — appends text the open panel types on (the visible hand).",
        discussion: """
        The visible-hand verb: appends to the note like `append`, and because the \
        change is an anchored suffix the running app reveals it character by \
        character in the open panel. Use `write` instead to replace silently.
        """
    )

    @Argument(help: "The note id (slug).") var id: String
    @Argument(parsing: .allUnrecognized, help: "Text to type (omit to read stdin).")
    var content: [String] = []
    @Flag(help: "Full updated note as JSON.") var json = false
    @Option(help: "Who is writing (blink.lastWriter). Defaults to cli.")
    var writer: String?

    func run() async throws {
        try await appendToNote(id: id, text: readText(content), json: json, writer: writer)
    }
}

struct Write: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Replace a note's content wholesale — no typed reveal (the quiet sibling of type).",
        discussion: """
        Files the note rather than saying it: a non-append replacement, so the \
        open panel updates in place with no typing animation. Presentation and \
        foreign frontmatter are preserved.
        """
    )

    @Argument(help: "The note id (slug).") var id: String
    @Argument(parsing: .allUnrecognized, help: "New content (omit to read stdin).")
    var content: [String] = []
    @Flag(help: "Full updated note as JSON.") var json = false
    @Option(help: "Who is writing (blink.lastWriter). Defaults to cli.")
    var writer: String?

    func run() async throws {
        let store = try await loadedStore()
        guard await store.note(id: id) != nil else {
            throw NoteNotFound(id: id)
        }
        let note = try await store.update(
            id: id,
            content: readText(content),
            writer: attributedWriter(writer)
        )
        if json {
            try printJSON(NoteJSON(note, full: true))
        } else {
            print(note.id)
        }
    }
}

struct Search: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Find notes whose title or content contains a string (case-insensitive)."
    )

    @Argument(help: "The text to search for.") var query: String
    @Flag(help: "Structured output.") var json = false

    func run() async throws {
        let q = query.lowercased()
        let hits = try await loadedStore().all().filter {
            $0.title.lowercased().contains(q) || $0.content.lowercased().contains(q)
        }
        try output(hits, json: json)
    }
}

struct Rm: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Delete a note by id."
    )

    @Argument(help: "The note id (slug).") var id: String
    @Flag(help: "Structured output.") var json = false
    @Option(help: "Who is deleting (ledger writer). Defaults to cli.")
    var writer: String?

    func run() async throws {
        _ = try existingNote(id: id)
        try await BlinkTombstoneStore(fileURL: BlinkPaths.tombstones()).recordDeletion(id: id)
        try fileStore().delete(id: id, writer: attributedWriter(writer))
        if json {
            try printJSON(["deleted": id])
        } else {
            print("deleted \(id)")
        }
    }
}

struct PathCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "path",
        abstract: "Print the notes directory, or a note's file path."
    )

    @Argument(help: "A note id (omit for the notes directory).") var id: String?

    func run() throws {
        if let id {
            _ = try existingNote(id: id)
            print(fileStore().url(for: id).path)
        } else {
            print(BlinkPaths.notes().path)
        }
    }
}

struct Log: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show the append-only edit ledger for a note."
    )

    @Argument(help: "The note id (slug).") var id: String
    @Option(name: .shortAndLong, help: "Show at most this many rows.") var limit: Int = 50
    @Flag(help: "Structured output.") var json = false

    func run() throws {
        let rows = fileStore().ledger?.history(noteID: id, limit: limit) ?? []
        if json {
            try printJSON(rows.map(EditJSON.init))
            return
        }
        if rows.isEmpty {
            FileHandle.standardError.write(Data("no edits recorded\n".utf8))
            return
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        for row in rows {
            let who = row.writer ?? "-"
            let when = formatter.string(from: row.at)
            if row.kind == .externalDetected, let detected = row.detectedAt {
                print("\(when)  \(row.kind.rawValue)  \(who)  detected \(formatter.string(from: detected))")
            } else {
                print("\(when)  \(row.kind.rawValue)  \(who)")
            }
        }
    }
}

private struct EditJSON: Encodable {
    let id: Int64
    let noteID: String
    let kind: String
    let writer: String?
    let at: Date
    let detectedAt: Date?

    init(_ event: NoteEditEvent) {
        id = event.id
        noteID = event.noteID
        kind = event.kind.rawValue
        writer = event.writer
        at = event.at
        detectedAt = event.detectedAt
    }
}


// MARK: - Shared plumbing

func fileStore() -> NoteFileStore {
    NoteFileStore(
        directory: BlinkPaths.notes(),
        ledger: NoteEditLedger(fileURL: BlinkPaths.edits())
    )
}

func loadedStore() async throws -> NoteStore {
    let store = NoteStore(
        fileStore: fileStore(),
        tombstoneStore: BlinkTombstoneStore(fileURL: BlinkPaths.tombstones())
    )
    try await store.load()
    return store
}

func attributedWriter(_ explicit: String?) -> String {
    let trimmed = explicit?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? "cli" : trimmed
}


/// Resolve command text: joined arguments, or stdin when piped and no args given.
private func readText(_ content: [String]) -> String {
    let joined = content.joined(separator: " ")
    if !joined.isEmpty { return joined }
    if isatty(0) == 0 {
        return String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
    }
    return joined
}

/// Append one separated line to an existing note (shared by `append`/`type`).
/// The anchored suffix is what lets the open panel type the new text on.
private func appendToNote(id: String, text: String, json: Bool, writer: String?) async throws {
    let store = try await loadedStore()
    guard let existing = await store.note(id: id) else {
        throw NoteNotFound(id: id)
    }
    let note = try await store.update(
        id: id,
        content: existing.content + "\n" + text,
        writer: attributedWriter(writer)
    )
    if json {
        try printJSON(NoteJSON(note, full: true))
    } else {
        print(note.id)
    }
}

struct NoteNotFound: Error, CustomStringConvertible {
    let id: String
    var description: String { "no note with id '\(id)' in \(BlinkPaths.notes().path)" }
}

func existingNote(id: String) throws -> Note {
    do {
        return try fileStore().load(id: id)
    } catch {
        throw NoteNotFound(id: id)
    }
}

/// The JSON face of a note. `content`/`extraFrontmatter` only for full output.
struct NoteJSON: Encodable {
    let id: String
    let title: String
    let tags: [String]
    let pinned: Bool
    let created: Date
    let updated: Date
    let path: String
    let content: String?
    let extraFrontmatter: [String]?

    init(_ note: Note, full: Bool) {
        id = note.id
        title = note.title
        tags = note.tags
        pinned = note.pinned
        created = note.createdAt
        updated = note.updatedAt
        path = NoteFileStore(directory: BlinkPaths.notes()).url(for: note.id).path
        content = full ? note.content : nil
        extraFrontmatter = full ? note.extraFrontmatter : nil
    }
}

func output(_ notes: [Note], json: Bool) throws {
    if json {
        try printJSON(notes.map { NoteJSON($0, full: false) })
    } else if notes.isEmpty {
        FileHandle.standardError.write(Data("no notes\n".utf8))
    } else {
        let idWidth = notes.map(\.id.count).max() ?? 0
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        for note in notes {
            let id = note.id.padding(toLength: idWidth, withPad: " ", startingAt: 0)
            print("\(id)  \(formatter.string(from: note.updatedAt))  \(note.title)")
        }
    }
}

func printJSON(_ value: some Encodable) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .custom { date, encoder in
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var container = encoder.singleValueContainer()
        try container.encode(f.string(from: date))
    }
    let data = try encoder.encode(value)
    print(String(decoding: data, as: UTF8.self))
}
