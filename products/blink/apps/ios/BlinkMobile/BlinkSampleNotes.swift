import BlinkCore
import Foundation

/// Bundled examples for the real reader. Never pass this snapshot to the cache.
enum BlinkSampleNotes {
    static let snapshot = BlinkSnapshot(
        generatedAt: Date(timeIntervalSince1970: 1_787_616_000),
        etag: "\"canvas-sample-notes-v1\"",
        notes: [
            note(
                id: "sample-welcome", title: "A place for your notes", slot: 1,
                workspace: "Getting started", tags: ["guide"],
                content: """
                # A place for your notes

                Keep ideas, plans, and reference material close at hand.

                Canvas on iPhone and iPad is a **read-only companion** to Canvas on your Mac. Browse your workspaces, search your notes, and read your last synced copy offline.

                These are sample notes. They are never saved over your own notes or sent to a Mac. Choose **Exit Samples** when you are ready to connect.
                """
            ),
            note(
                id: "sample-project", title: "A small project", slot: 5,
                workspace: "Getting started", tags: ["ideas", "checklist"],
                content: """
                # A small project

                Turn a rough idea into something you can share.

                ## First steps

                - Sketch the idea on paper.
                - Collect a few useful references.
                - Pick one small thing to make today.

                > Leave room for a better idea tomorrow.

                ## A note from the terminal

                On your Mac, the Canvas command-line tool can create a note:

                ```sh
                canvas new "A small project"
                ```

                On iPad, notes with a saved position appear on the workspace board. Tap a note to open the reader.
                """
            ),
            note(
                id: "sample-weekend", title: "An unhurried weekend", slot: 9,
                workspace: nil, tags: ["personal"],
                content: """
                # An unhurried weekend

                Coffee, a long walk, and time to read.

                - Visit the bookshop near the park.
                - Bring a notebook for sketches.
                - Make soup for the week.

                This note is **Unfiled**. Use the workspace menu to find it, or search for *coffee*.
                """
            ),
        ],
        tombstones: [],
        issues: []
    )

    private static func note(
        id: String, title: String, slot: Int, workspace: String?, tags: [String], content: String
    ) -> BlinkSnapshotNote {
        let date = Date(timeIntervalSince1970: 1_787_616_000 - Double(slot * 60))
        var presentation = NotePresentation()
        presentation.workspace = workspace
        presentation.slot = slot
        let note = Note(
            id: id, content: content, createdAt: date, updatedAt: date,
            tags: tags, presentation: presentation
        )
        return BlinkSnapshotNote(
            id: id, revision: "\(id)-v1", markdown: Frontmatter.encode(note),
            title: title, updatedAt: date, tags: tags, pinned: false,
            presentation: presentation
        )
    }
}
