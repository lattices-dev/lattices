import Foundation
import Testing
@testable import BlinkCore

@Suite("Canvas storage compatibility")
struct CanvasCompatibilityTests {
    @Test("Default storage and IPC identity stay attached to existing installations")
    func defaultIdentity() {
        let existing = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Blink", isDirectory: true)
        #expect(BlinkPaths.home(environment: [:]) == existing)
        #expect(BlinkPaths.socket(environment: [:]).lastPathComponent == "blink.sock")
        #expect(!BlinkPaths.hasHomeOverride(environment: [:]))
        #expect(!BlinkPaths.hasHomeOverride(environment: ["CANVAS_HOME": "", "BLINK_HOME": ""]))
    }

    @Test("Canvas override wins and the Blink override remains compatible")
    func environmentPrecedence() {
        let both = ["CANVAS_HOME": "/tmp/canvas", "BLINK_HOME": "/tmp/blink"]
        #expect(BlinkPaths.home(environment: both).path == "/tmp/canvas")
        #expect(BlinkPaths.home(environment: ["CANVAS_HOME": "", "BLINK_HOME": "/tmp/blink"]).path == "/tmp/blink")
        #expect(BlinkPaths.hasHomeOverride(environment: ["CANVAS_HOME": "/tmp/canvas"]))
        #expect(BlinkPaths.hasHomeOverride(environment: ["BLINK_HOME": "/tmp/blink"]))
        #expect(BlinkPaths.home(environment: ["CANVAS_HOME": "~/canvas"]).path == ("~/canvas" as NSString).expandingTildeInPath)
    }

    @Test("Both names share existing notes, settings, desks, attachments and edit history")
    func sameStoreWithoutMigration() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("canvas-compat-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = ["BLINK_HOME": root.path]
        let canonical = ["CANVAS_HOME": root.path]
        let oldStore = NoteFileStore(directory: BlinkPaths.notes(environment: legacy))
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var presentation = NotePresentation()
        presentation.slot = 4
        let note = Note(id: "existing", content: "# Existing note\n\n![image](blink://attachments/pic.png)\n",
                        createdAt: now, updatedAt: now, tags: ["keep"], pinned: true,
                        presentation: presentation, extraFrontmatter: ["external: preserve"],
                        extraBlink: ["  futureSetting: keep"])
        try oldStore.save(note)
        let config = Data("{\"workspaces\":{\"existing\":{}}}\n".utf8)
        try config.write(to: BlinkPaths.config(environment: legacy))
        let original = try Data(contentsOf: oldStore.url(for: note.id))
        let newStore = NoteFileStore(directory: BlinkPaths.notes(environment: canonical))
        let loaded = try newStore.load(id: note.id)
        #expect(loaded.content == note.content)
        #expect(loaded.pinned && loaded.tags == note.tags)
        #expect(loaded.presentation.slot == 4)
        #expect(loaded.extraFrontmatter.contains("external: preserve"))
        #expect(loaded.extraBlink.contains("  futureSetting: keep"))
        #expect(try Data(contentsOf: newStore.url(for: note.id)) == original)
        #expect(try Data(contentsOf: BlinkPaths.config(environment: canonical)) == config)
        #expect(BlinkPaths.desks(environment: canonical) == BlinkPaths.desks(environment: legacy))
        #expect(BlinkPaths.edits(environment: canonical) == BlinkPaths.edits(environment: legacy))
        #expect(BlinkPaths.tombstones(environment: canonical) == BlinkPaths.tombstones(environment: legacy))
        #expect(BlinkPaths.attachments(environment: canonical) == BlinkPaths.attachments(environment: legacy))
    }
}
