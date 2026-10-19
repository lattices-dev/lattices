import ArgumentParser
import BlinkCore
import Foundation

/// `canvas workspace …` — the agent-facing face of Notes Workspaces.
///
/// A workspace is two things kept deliberately apart:
/// - a **definition** in `config.json` → `workspaces.<name>` (title + brand),
/// - **membership**, one `blink.workspace:` key in each note's frontmatter.
///
/// So the brand is edited in one place and the markdown stays portable: a note
/// carries a workspace *name*, never a color, font, or asset path. Forgetting a
/// workspace costs a look, never a note. See `docs/workspaces.md`.
struct WorkspaceCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "workspace",
        abstract: "Create and brand a named workspace of notes.",
        discussion: """
        A workspace groups notes and gives them one identity. The definition \
        (title + brand) lives in config.json; membership lives in each note's \
        `blink.workspace` frontmatter key, so note markdown stays portable and \
        free of presentation-only branding. Notes with no workspace, and \
        workspaces with no brand, render exactly as they do today.
        """,
        subcommands: [
            WorkspaceInit.self, WorkspaceList.self, WorkspaceShow.self, WorkspaceBrand.self,
            WorkspaceAdd.self, WorkspaceRemove.self, WorkspaceNotes.self, WorkspaceForget.self,
        ],
        defaultSubcommand: WorkspaceList.self
    )
}

// MARK: - Brand flags

/// The brand vocabulary, shared by `init` and `brand` so one treatment surface
/// is described in exactly one place. Every flag is optional: only what you pass
/// changes, and an unset field inherits — which is what keeps unbranded the
/// default and makes brands composable.
struct BrandOptions: ParsableArguments {
    // Surface
    @Option(help: "Sheet template: glass | card | dotted | bracket | marginalia.")
    var sheet: String?
    @Option(help: "Opaque surface color, e.g. '#070908'. Unset keeps glass transparent.")
    var background: String?
    @Option(help: "Corner radius in px — the corner treatment.")
    var radius: Double?
    @Option(help: "Glass tint 0–1 (shorthand for both modes).")
    var tint: Double?
    @Option(name: .customLong("tint-read"), help: "Read-mode glass tint 0–1.")
    var tintRead: Double?
    @Option(name: .customLong("tint-edit"), help: "Edit-mode glass tint 0–1.")
    var tintEdit: Double?

    // Typography
    @Option(help: "Body font family (CSS font-family string).")
    var font: String?
    @Option(help: "Monospace font family.")
    var mono: String?
    @Option(name: .customLong("title-font"), help: "Heading/title font family.")
    var titleFont: String?
    @Option(name: .customLong("font-size"), help: "Base font size in px.")
    var fontSize: Double?
    @Option(name: .customLong("line-height"), help: "Line height multiplier.")
    var lineHeight: Double?

    // Palette
    @Option(help: "Body text color.") var text: String?
    @Option(name: .customLong("text-strong"), help: "Headings/bold color.") var textStrong: String?
    @Option(name: .customLong("text-muted"), help: "Muted text color.") var textMuted: String?
    @Option(help: "Markdown syntax marker color.") var dim: String?
    @Option(help: "Rules, quote borders, sheet frame color.") var border: String?
    @Option(help: "Accent color (links, caret).") var accent: String?
    @Option(name: .customLong("accent-dim"), help: "Secondary accent color.") var accentDim: String?
    @Option(name: .customLong("code-background"), help: "Code block background.") var codeBackground: String?
    @Option(name: .customLong("code-text"), help: "Code ink color.") var codeText: String?
    @Option(help: "Caret color.") var caret: String?
    @Option(help: "Selection color.") var selection: String?

    // Identity
    @Option(help: "Reference an already-installed mark, relative to the attachments directory.")
    var mark: String?
    @Option(
        name: .customLong("install-mark"),
        help: "Copy an image into the attachments store and use it as the mark (the safe path)."
    )
    var installMark: String?

    // Bulk + clearing
    @Option(name: .customLong("brand-from"), help: "Read the whole brand from a JSON file.")
    var brandFrom: String?
    @Option(help: "Base style name from config.json → styles, overlaid by this brand.")
    var style: String?
    @Option(
        name: .customLong("clear"),
        help: "Unset a brand field so it inherits again (repeatable), e.g. --clear mark."
    )
    var clear: [String] = []

    /// Fold these flags into a workspace, in place.
    func apply(to workspace: inout Workspace, store: WorkspaceStore, name: String) throws {
        var brand = workspace.brand ?? Treatment()

        if let path = brandFrom {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            guard let data = try? Data(contentsOf: url) else {
                throw ValidationError("cannot read brand file at \(url.path)")
            }
            let loaded: Treatment
            do {
                loaded = try JSONDecoder().decode(Treatment.self, from: data)
            } catch {
                throw ValidationError("\(url.lastPathComponent) is not a valid brand: \(error)")
            }
            brand = brand.merging(loaded)
        }

        if let style { workspace.style = style }

        if let sheet { brand.sheet = sheet }
        if let background { brand.background = background }
        if let radius { brand.radius = radius }
        if let tint { brand.tint = tint }
        if let tintRead { brand.tintRead = tintRead }
        if let tintEdit { brand.tintEdit = tintEdit }
        if let font { brand.font = font }
        if let mono { brand.mono = mono }
        if let titleFont { brand.titleFont = titleFont }
        if let fontSize { brand.fontSize = fontSize }
        if let lineHeight { brand.lineHeight = lineHeight }
        if let text { brand.text = text }
        if let textStrong { brand.textStrong = textStrong }
        if let textMuted { brand.textMuted = textMuted }
        if let dim { brand.dim = dim }
        if let border { brand.border = border }
        if let accent { brand.accent = accent }
        if let accentDim { brand.accentDim = accentDim }
        if let codeBackground { brand.codeBackground = codeBackground }
        if let codeText { brand.codeText = codeText }
        if let caret { brand.caret = caret }
        if let selection { brand.selection = selection }

        // Reference an existing asset, or install one. Installing is the safe
        // path: the app only renders marks from inside the attachments store.
        if let mark {
            guard BlinkPaths.attachment(named: mark) != nil else {
                throw ValidationError(
                    """
                    '\(mark)' does not resolve to a file inside \(BlinkPaths.attachments().path).
                    Use --install-mark <file> to copy an asset in, or pass a path relative to that directory.
                    """
                )
            }
            brand.mark = mark
        }
        if let installMark {
            let source = URL(fileURLWithPath: (installMark as NSString).expandingTildeInPath)
            brand.mark = try store.installMark(from: source, for: name)
        }

        for field in clear {
            try Self.clear(field, in: &brand, workspace: &workspace)
        }

        workspace.brand = brand.isEmpty ? nil : brand
    }

    /// Unset one field by its brand key. Accepts camelCase or kebab-case so
    /// `--clear textMuted` and `--clear text-muted` both work.
    private static func clear(
        _ field: String,
        in brand: inout Treatment,
        workspace: inout Workspace
    ) throws {
        switch field.lowercased().replacingOccurrences(of: "-", with: "") {
        case "sheet": brand.sheet = nil
        case "background": brand.background = nil
        case "radius": brand.radius = nil
        case "tint": brand.tint = nil
        case "tintread": brand.tintRead = nil
        case "tintedit": brand.tintEdit = nil
        case "font": brand.font = nil
        case "mono": brand.mono = nil
        case "titlefont": brand.titleFont = nil
        case "fontsize": brand.fontSize = nil
        case "lineheight": brand.lineHeight = nil
        case "text": brand.text = nil
        case "textstrong": brand.textStrong = nil
        case "textmuted": brand.textMuted = nil
        case "dim": brand.dim = nil
        case "border": brand.border = nil
        case "accent": brand.accent = nil
        case "accentdim": brand.accentDim = nil
        case "codebackground": brand.codeBackground = nil
        case "codetext": brand.codeText = nil
        case "caret": brand.caret = nil
        case "selection": brand.selection = nil
        case "mark": brand.mark = nil
        case "style": workspace.style = nil
        case "brand": brand = Treatment()
        default: throw ValidationError("'\(field)' is not a brand field")
        }
    }
}

// MARK: - Commands

struct WorkspaceInit: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "init",
        abstract: "Create a workspace (idempotent); optionally brand it in the same call.",
        discussion: """
        Safe to re-run: an existing workspace is updated, never replaced. With no \
        brand flags the workspace is created unbranded, and its notes render with \
        Canvas defaults until you brand it.
        """
    )

    @Argument(help: "Workspace name; normalized to a slug.") var name: String
    @Option(help: "Human-facing label (defaults to the name).") var title: String?
    @OptionGroup var brand: BrandOptions
    @Flag(help: "Structured output.") var json = false

    func run() throws {
        let store = WorkspaceStore()
        let key = try WorkspaceStore.normalize(name)
        var workspace = try store.workspace(named: key) ?? Workspace()
        if let title { workspace.title = title }
        try brand.apply(to: &workspace, store: store, name: key)
        try store.save(workspace, named: key)
        try emit(name: key, workspace: workspace, store: store, json: json)
    }
}

struct WorkspaceList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ls",
        abstract: "List defined workspaces and how many notes are in each."
    )

    @Flag(help: "Structured output.") var json = false

    func run() async throws {
        let store = WorkspaceStore()
        let workspaces = try store.all()
        let counts = noteCounts()

        let styles = try? store.styles()
        if json {
            let rows = workspaces.keys.sorted().map { key in
                WorkspaceJSON(
                    name: key,
                    workspace: workspaces[key] ?? Workspace(),
                    noteCount: counts[key] ?? 0,
                    styles: styles
                )
            }
            try printJSON(rows)
            return
        }

        guard !workspaces.isEmpty else {
            FileHandle.standardError.write(Data("no workspaces — create one with `canvas workspace init <name>`\n".utf8))
            return
        }
        let width = workspaces.keys.map(\.count).max() ?? 0
        for key in workspaces.keys.sorted() {
            let ws = workspaces[key] ?? Workspace()
            let padded = key.padding(toLength: width, withPad: " ", startingAt: 0)
            let brand = ws.resolvedBrand(styles: styles)
            let badge = brand.isEmpty ? "unbranded" : (brand.mark == nil ? "branded" : "branded + mark")
            let count = counts[key] ?? 0
            print("\(padded)  \(count) \(count == 1 ? "note " : "notes")  \(badge)  \(ws.title ?? "")")
        }
    }
}

struct WorkspaceShow: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show",
        abstract: "Show a workspace's definition, effective brand, and notes."
    )

    @Argument(help: "Workspace name.") var name: String
    @Flag(help: "Structured output.") var json = false

    func run() async throws {
        let store = WorkspaceStore()
        let key = try WorkspaceStore.normalize(name)
        guard let workspace = try store.workspace(named: key) else {
            throw WorkspaceStoreError.unknownWorkspace(name: key)
        }
        try emit(name: key, workspace: workspace, store: store, json: json)
    }
}

struct WorkspaceBrand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "brand",
        abstract: "Set or adjust a workspace's brand — mark, palette, typography, corners.",
        discussion: """
        A partial overlay: only the fields you pass change, so you can adjust one \
        color without restating the brand. `--clear <field>` unsets a field so it \
        inherits again. Config keys this command does not own are preserved \
        byte-for-byte, so branding never disturbs the rest of config.json.
        """
    )

    @Argument(help: "Workspace name.") var name: String
    @Option(help: "Human-facing label.") var title: String?
    @OptionGroup var brand: BrandOptions
    @Flag(help: "Create the workspace if it does not exist.") var create = false
    @Flag(help: "Structured output.") var json = false

    func run() throws {
        let store = WorkspaceStore()
        let key = try WorkspaceStore.normalize(name)
        let workspace = try store.update(named: key, createIfMissing: create) { ws in
            if let title { ws.title = title }
            try brand.apply(to: &ws, store: store, name: key)
        }
        try emit(name: key, workspace: workspace, store: store, json: json)
    }
}

struct WorkspaceAdd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "Put notes in a workspace (writes blink.workspace to each note).",
        discussion: "Notes are created if they do not exist, so an agent can lay out a workspace in one call."
    )

    @Argument(help: "Workspace name.") var name: String
    @Argument(help: "Note ids.") var ids: [String]
    @Flag(help: "Structured output.") var json = false

    func run() throws {
        let store = WorkspaceStore()
        let key = try WorkspaceStore.normalize(name)
        guard try store.workspace(named: key) != nil else {
            throw WorkspaceStoreError.unknownWorkspace(name: key)
        }
        let moved = try setWorkspace(key, on: ids)
        try report(moved, json: json, verb: "added to \(key)")
    }
}

struct WorkspaceRemove: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remove",
        abstract: "Take notes out of a workspace (clears blink.workspace).",
        discussion: "The notes and their content are untouched — only membership is cleared."
    )

    @Argument(help: "Note ids.") var ids: [String]
    @Flag(help: "Structured output.") var json = false

    func run() throws {
        let moved = try setWorkspace(nil, on: ids)
        try report(moved, json: json, verb: "removed from its workspace")
    }
}

struct WorkspaceNotes: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "notes",
        abstract: "List the notes in a workspace, most recently updated first.",
        discussion: "How an agent reopens its workspace: list the ids, then `canvas cat` or open them in the app."
    )

    @Argument(help: "Workspace name.") var name: String
    @Flag(help: "Structured output.") var json = false

    func run() async throws {
        let key = try WorkspaceStore.normalize(name)
        let notes = try await loadedStore().all().filter { $0.presentation.workspace == key }
        try output(notes, json: json)
    }
}

struct WorkspaceForget: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rm",
        abstract: "Forget a workspace definition. Notes are never deleted.",
        discussion: """
        Removes only the config entry; member notes keep their `blink.workspace` \
        key and render unbranded until the workspace is defined again. Pass \
        --detach to also clear membership from every member note.
        """
    )

    @Argument(help: "Workspace name.") var name: String
    @Flag(help: "Also clear blink.workspace from every member note.") var detach = false
    @Flag(help: "Structured output.") var json = false

    func run() async throws {
        let store = WorkspaceStore()
        let key = try WorkspaceStore.normalize(name)
        var detached: [String] = []
        if detach {
            let members = try await loadedStore().all()
                .filter { $0.presentation.workspace == key }
                .map(\.id)
            detached = try setWorkspace(nil, on: members)
        }
        let removed = try store.remove(named: key)
        guard removed else { throw WorkspaceStoreError.unknownWorkspace(name: key) }
        if json {
            try printJSON(ForgotJSON(forgot: key, detached: detached))
        } else {
            print("forgot \(key)\(detached.isEmpty ? "" : " (detached \(detached.count) notes)")")
        }
    }
}

// MARK: - Shared

/// Write `blink.workspace` on each note, preserving all other presentation and
/// foreign frontmatter. Creates a note that does not exist yet so an agent can
/// scaffold a workspace in one call. Returns the ids actually written.
private func setWorkspace(_ name: String?, on ids: [String]) throws -> [String] {
    let store = fileStore()
    var written: [String] = []
    for raw in ids {
        let id = Slug.generate(from: raw)
        let now = Date()
        var note: Note
        if let existing = try? store.load(id: id) {
            note = existing
            guard note.presentation.workspace != name else { continue }
            note.updatedAt = now
        } else {
            // Removing membership from a note that does not exist is a no-op,
            // never a reason to create an empty note.
            guard name != nil else { continue }
            note = Note(id: id, content: "", createdAt: now, updatedAt: now)
        }
        note.presentation.workspace = name
        try store.save(note)
        written.append(id)
    }
    return written
}

private func report(_ ids: [String], json: Bool, verb: String) throws {
    if json {
        try printJSON(["notes": ids])
    } else if ids.isEmpty {
        print("nothing to do")
    } else {
        print("\(ids.count) \(ids.count == 1 ? "note" : "notes") \(verb): \(ids.joined(separator: ", "))")
    }
}

private struct ForgotJSON: Encodable {
    let forgot: String
    let detached: [String]
}

private func noteCounts() -> [String: Int] {
    var counts: [String: Int] = [:]
    for note in fileStore().loadAllLenient() {
        guard let ws = note.presentation.workspace else { continue }
        counts[ws, default: 0] += 1
    }
    return counts
}

private func emit(name: String, workspace: Workspace, store: WorkspaceStore, json: Bool) throws {
    let styles = try? store.styles()
    if json {
        try printJSON(
            WorkspaceJSON(
                name: name,
                workspace: workspace,
                noteCount: noteCounts()[name] ?? 0,
                styles: styles
            )
        )
        return
    }

    let brand = workspace.resolvedBrand(styles: styles)
    print("\(name)\(workspace.title.map { "  (\($0))" } ?? "")")
    if let style = workspace.style { print("  style      \(style)") }
    print("  notes      \(noteCounts()[name] ?? 0)")
    if brand.isEmpty {
        print("  brand      unbranded — Canvas defaults")
        return
    }
    if let v = brand.mark {
        let resolved = BlinkPaths.attachment(named: v)
        print("  mark       \(v)\(resolved == nil ? "  ⚠︎ not found in attachments" : "")")
    }
    for (label, value) in [
        ("sheet", brand.sheet), ("background", brand.background),
        ("accent", brand.accent), ("accentDim", brand.accentDim),
        ("text", brand.text), ("textStrong", brand.textStrong), ("textMuted", brand.textMuted),
        ("dim", brand.dim), ("border", brand.border),
        ("codeBackground", brand.codeBackground), ("codeText", brand.codeText),
        ("caret", brand.caret), ("selection", brand.selection),
        ("font", brand.font), ("mono", brand.mono), ("titleFont", brand.titleFont),
    ] where value != nil {
        print("  \(label.padding(toLength: 10, withPad: " ", startingAt: 0)) \(value ?? "")")
    }
    for (label, value) in [
        ("radius", brand.radius), ("fontSize", brand.fontSize), ("lineHeight", brand.lineHeight),
        ("tint", brand.tint), ("tintRead", brand.tintRead), ("tintEdit", brand.tintEdit),
    ] where value != nil {
        print("  \(label.padding(toLength: 10, withPad: " ", startingAt: 0)) \(value ?? 0)")
    }
}

/// The JSON face of a workspace: the stored definition plus the *effective*
/// brand (style base + overlay) an agent would otherwise have to compute, and
/// whether the mark actually resolves inside the attachments store.
struct WorkspaceJSON: Encodable {
    let name: String
    let title: String
    let style: String?
    let brand: Treatment?
    let effectiveBrand: Treatment
    let noteCount: Int
    let mark: MarkJSON?

    struct MarkJSON: Encodable {
        let path: String
        let resolved: String?
        let installed: Bool
    }

    init(name: String, workspace: Workspace, noteCount: Int, styles: [String: Treatment]?) {
        self.name = name
        title = workspace.title ?? name
        style = workspace.style
        brand = workspace.brand
        effectiveBrand = workspace.resolvedBrand(styles: styles)
        self.noteCount = noteCount
        if let path = effectiveBrand.mark {
            let url = BlinkPaths.attachment(named: path)
            mark = MarkJSON(path: path, resolved: url?.path, installed: url != nil)
        } else {
            mark = nil
        }
    }
}
