import AppKit
import Combine
import SwiftUI

/// State for the unified command bar — one bar for search, slash-commands and
/// (later) voice. It **composes** the existing `OmniSearchState` (which itself
/// owns the `CommandBarState` slash-command engine), so search + commands are
/// reused verbatim. This layer only adds the single text binding, the entry
/// mode, and the "what should the panel show" detail computation.
///
/// Phase A: search + commands. Voice (`VoiceCommandState`) and the assistant
/// handoff are wired in later phases.
final class UnifiedCommandBarState: ObservableObject {
    enum Mode { case command, search, voice }

    /// What the expansion panel under the bar should render. `.none` keeps the
    /// bar slim — detail is revealed only when there's something to show.
    enum Detail: Equatable { case none, search, command, voice, welcome, browse, nlCommand }

    /// The single text-field binding. Forwarded verbatim into the composed
    /// engine, which routes a leading "/" into command mode (the visible trigger)
    /// and everything else into search.
    @Published var query: String = "" {
        didSet {
            guard query != search.query else { return }
            search.query = query
        }
    }

    /// Composed engines. `search.command` is the slash-command engine; `voice`
    /// is reused **verbatim** (its deadlock-safe DiagnosticLog observer is the
    /// highest-risk code to rewrite, so we compose rather than absorb it).
    let search: OmniSearchState
    let voice = VoiceCommandState()

    private var cancellables = Set<AnyCancellable>()

    init(arrangementTarget: AppArrangementTarget? = nil) {
        search = OmniSearchState(arrangementTarget: arrangementTarget)
        // Re-publish nested engine changes so the view re-renders (and `detail`
        // recomputes) whenever results, command suggestions, or voice phase update.
        for child in [search.objectWillChange, voice.objectWillChange] {
            child.sink { [weak self] _ in self?.objectWillChange.send() }
                .store(in: &cancellables)
        }
    }

    /// A leading "/" is the visible command trigger.
    var commandMode: Bool { query.hasPrefix("/") }

    /// Voice has taken over the bar (listening / transcribing / showing a result).
    var voiceActive: Bool { voice.phase != .idle }

    /// Typed free text that reads as a Lattices *question* → the send button
    /// becomes an "ask" affordance and Enter hands off to the assistant.
    var wantsAssistant: Bool {
        !voiceActive && !commandMode && IntentHeuristics.shouldAskAssistant(query)
    }

    /// Natural-language *command* typed without a leading "/" (e.g. "tile chrome
    /// left", "move this to display 2"). When the NL resolver confidently maps it
    /// to an actionable intent, the bar previews it and Enter runs it — so you
    /// don't have to know the slash syntax. Search stays the bar's plain-text job,
    /// so a resolved "search" intent is intentionally *not* treated as a command.
    ///
    /// The resolve runs an embedding, so it's gated on a cheap string check and
    /// cached per query — view re-renders never re-embed.
    private var nlCache: (query: String, match: IntentMatch?)?
    var nlMatch: IntentMatch? {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        // An explicit current-app arrangement result owns this small vocabulary.
        // Do not let NL turn "tile Ghostty" into a single-window move or
        // "arrange" into a distribution of every app on the desktop.
        if search.arrangementTarget?.matches(trimmed) == true { return nil }
        guard !voiceActive, !commandMode, !wantsAssistant, !trimmed.isEmpty,
              IntentHeuristics.looksLikeCommand(trimmed.lowercased()) else { return nil }
        if let c = nlCache, c.query == trimmed { return c.match }
        let resolved = VoiceIntentResolver.shared.match(text: trimmed)
        let actionable = resolved.flatMap { $0.intentName == "search" ? nil : $0 }
        nlCache = (trimmed, actionable)
        return actionable
    }

    /// Placement target for the resolved NL command, if it tiles a window — drives
    /// the ghost preview.
    var nlSpec: PlacementSpec? {
        guard let m = nlMatch, let pos = m.slots["position"]?.stringValue else { return nil }
        return PlacementSpec(string: pos)
    }

    private var voiceHasContent: Bool {
        !voice.partialText.isEmpty || !voice.finalText.isEmpty
            || voice.intentName != nil || !voice.resultItems.isEmpty
            || !voice.resultSummary.isEmpty || voice.executionError != nil
    }

    var detail: Detail {
        // Voice wins while it's active — reveal its detail once there's something
        // to show (the bar itself reflects the listening state before then).
        if voiceActive { return voiceHasContent ? .voice : .none }
        if commandMode {
            // `/` is the visible trigger: command suggestions, filtered as you type
            // (↑/↓ navigate, ⇥ complete, ↵ run).
            return search.command.suggestions.isEmpty ? .none : .command
        }
        // Empty bar → the browse menu (no-typing actions), or a short welcome
        // when there's nothing to browse.
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            return search.results.isEmpty ? .welcome : .browse
        }
        // Plain text that reads as an actionable command → preview it; else search.
        if nlMatch != nil { return .nlCommand }
        return search.results.isEmpty ? .none : .search
    }

    func moveSelection(_ delta: Int) { search.moveSelection(delta) }
}
