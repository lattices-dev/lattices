import AppKit
import Foundation
import NaturalLanguage

private struct IntentCandidate {
    let intent: IntentDef
    let slots: [String: JSON]
    let score: Double
    let semanticScore: Double
    let keywordBoost: Double
    let slotBoost: Double
    let matchedExample: String
}

private struct ExtractedSlots {
    let slots: [String: JSON]
    let boost: Double
}

final class VoiceIntentResolver {
    static let shared = VoiceIntentResolver()

    private let embedding = NLEmbedding.sentenceEmbedding(for: .english)

    private init() {}

    func match(text: String) -> IntentMatch? {
        let input = normalizeUtterance(text)
        guard !input.isEmpty else { return nil }

        if let direct = directMatch(for: input) {
            return direct
        }

        var candidates = IntentEngine.shared.definitions().compactMap { candidate(for: $0, input: input) }
        candidates.sort { lhs, rhs in
            if lhs.score == rhs.score {
                return lhs.semanticScore > rhs.semanticScore
            }
            return lhs.score > rhs.score
        }

        guard let best = candidates.first else { return nil }

        let minimumScore = best.intent.slots.contains(where: \.required) ? 0.42 : 0.36
        guard best.score >= minimumScore else { return nil }

        if let runnerUp = candidates.dropFirst().first,
           best.score - runnerUp.score < 0.05,
           best.keywordBoost < 0.18,
           best.slotBoost < 0.12 {
            return nil
        }

        return IntentMatch(
            intentName: best.intent.name,
            slots: best.slots,
            confidence: min(0.98, max(0.35, best.score)),
            matchedPhrase: best.matchedExample
        )
    }

    func execute(_ match: IntentMatch) throws -> JSON {
        try IntentEngine.shared.execute(IntentRequest(
            intent: match.intentName,
            slots: match.slots,
            rawText: nil,
            confidence: match.confidence,
            source: "voice-local"
        ))
    }

    func catalog() -> JSON {
        IntentEngine.shared.catalog()
    }

    private func candidate(for intent: IntentDef, input: String) -> IntentCandidate? {
        let extracted = extractSlots(for: intent.name, input: input)
        let requiredMissing = intent.slots.contains { $0.required && extracted.slots[$0.name] == nil }
        let exampleMatch = bestExampleMatch(for: intent, input: input)
        let keywordBoost = keywordBoost(for: intent.name, input: input)
        let exactBoost = normalizeUtterance(exampleMatch.example) == input ? 0.20 : 0.0
        let missingPenalty = requiredMissing ? 0.22 : 0.0
        let score = exampleMatch.score + keywordBoost + extracted.boost + exactBoost - missingPenalty

        if score <= 0 {
            return nil
        }

        return IntentCandidate(
            intent: intent,
            slots: extracted.slots,
            score: score,
            semanticScore: exampleMatch.score,
            keywordBoost: keywordBoost,
            slotBoost: extracted.boost,
            matchedExample: exampleMatch.example
        )
    }

    private func bestExampleMatch(for intent: IntentDef, input: String) -> (example: String, score: Double) {
        let examples = intent.examples + supplementalExamples[intent.name, default: []]
        guard !examples.isEmpty else { return ("", 0) }

        let best = examples
            .map { example -> (String, Double) in
                let normalizedExample = normalizeUtterance(example)
                if normalizedExample == input {
                    return (example, 0.62)
                }

                let distance = semanticDistance(between: input, and: normalizedExample)
                let semantic = max(0, 1.18 - distance) * 0.48
                let overlap = tokenOverlap(input, normalizedExample) * 0.24
                return (example, semantic + overlap)
            }
            .max { $0.1 < $1.1 } ?? ("", 0)

        return best
    }

    private func semanticDistance(between lhs: String, and rhs: String) -> Double {
        guard let embedding else {
            return lhs == rhs ? 0 : 2
        }
        return Double(embedding.distance(between: lhs, and: rhs))
    }

    private func keywordBoost(for intentName: String, input: String) -> Double {
        guard let keywords = intentKeywords[intentName] else { return 0 }

        var boost = 0.0
        for keyword in keywords {
            if input.contains(keyword) {
                boost += keyword.contains(" ") ? 0.12 : 0.08
            }
        }
        return min(boost, 0.28)
    }

    private func extractSlots(for intentName: String, input: String) -> ExtractedSlots {
        switch intentName {
        case "tile_window":
            var slots: [String: JSON] = [:]
            var boost = 0.0

            if let position = resolvePosition(in: input) {
                slots["position"] = .string(position)
                boost += 0.28
            } else {
                return ExtractedSlots(slots: [:], boost: 0)
            }

            if refersToSelection(in: input) {
                slots["selection"] = .bool(true)
                boost += 0.08
            }

            return ExtractedSlots(slots: slots, boost: boost)

        case "distribute":
            var slots: [String: JSON] = [:]
            var boost = 0.0

            if let region = resolvePosition(in: input) {
                slots["region"] = .string(region)
                boost += 0.18
            }

            if let app = detectKnownApp(in: input) {
                slots["app"] = .string(app)
                boost += 0.14
            }

            if refersToSelection(in: input) {
                slots["selection"] = .bool(true)
                boost += 0.12
            }

            return ExtractedSlots(slots: slots, boost: boost)

        case "focus":
            if let app = detectKnownApp(in: input) ?? extractEntity(in: input, prefixes: focusPrefixes) {
                let resolved = resolveApp(app)
                guard !resolved.isEmpty else { return ExtractedSlots(slots: [:], boost: 0) }
                return ExtractedSlots(slots: ["app": .string(resolved)], boost: 0.18)
            }
            return ExtractedSlots(slots: [:], boost: 0)

        case "launch":
            if let project = extractEntity(in: input, prefixes: launchPrefixes) {
                let cleaned = cleanEntity(project)
                guard !cleaned.isEmpty else { return ExtractedSlots(slots: [:], boost: 0) }
                return ExtractedSlots(slots: ["project": .string(cleaned)], boost: 0.16)
            }
            return ExtractedSlots(slots: [:], boost: 0)

        case "switch_layer":
            if let layer = extractLayer(in: input) {
                guard !layer.isEmpty else { return ExtractedSlots(slots: [:], boost: 0) }
                return ExtractedSlots(slots: ["layer": .string(layer)], boost: 0.18)
            }
            return ExtractedSlots(slots: [:], boost: 0)

        case "search":
            if let query = extractSearchQuery(from: input) {
                let cleaned = cleanQuery(query)
                guard !cleaned.isEmpty else { return ExtractedSlots(slots: [:], boost: 0) }
                return ExtractedSlots(slots: ["query": .string(cleaned)], boost: 0.16)
            }
            return ExtractedSlots(slots: [:], boost: 0)

        case "create_layer":
            if let name = extractLayerName(from: input) {
                let cleaned = cleanEntity(name)
                guard !cleaned.isEmpty else { return ExtractedSlots(slots: [:], boost: 0) }
                return ExtractedSlots(slots: ["name": .string(cleaned)], boost: 0.14)
            }
            return ExtractedSlots(slots: [:], boost: 0)

        case "kill":
            if let session = extractEntity(in: input, prefixes: killPrefixes) {
                let cleaned = cleanEntity(session)
                guard !cleaned.isEmpty else { return ExtractedSlots(slots: [:], boost: 0) }
                return ExtractedSlots(slots: ["session": .string(cleaned)], boost: 0.16)
            }
            return ExtractedSlots(slots: [:], boost: 0)

        default:
            return ExtractedSlots(slots: [:], boost: 0)
        }
    }

    private func extractSearchQuery(from input: String) -> String? {
        let prefixes = [
            "find all the ", "find all ", "find ",
            "search for all ", "search for ", "search ",
            "look for ", "look up ", "locate all ", "locate ",
            "where is ", "where s ", "where does it say ", "where did i see ",
            "which window has ", "which window shows ",
            "help me find ", "can you find ",
            "show me all the ", "show me all ", "show all the ", "show all ",
            "open up all the ", "open up all ", "open all the ", "open all ",
            "pull up everything with ", "pull up all ", "pull up ",
            "bring up all the ", "bring up all ", "bring up my ",
            "where d my ", "i lost my ", "i lost ", "where the hell is ",
            "see all my ", "see all ", "see where s ", "see where is "
        ]

        if let entity = extractEntity(in: input, prefixes: prefixes) {
            return entity
        }

        if input.hasSuffix(" windows") || input.hasSuffix(" window") {
            return cleanQuery(input)
        }

        let wordCount = input.split(separator: " ").count
        if wordCount <= 3, !genericNonCommandPhrases.contains(input) {
            return input
        }

        return nil
    }

    private func extractLayerName(from input: String) -> String? {
        if let called = extractEntity(in: input, prefixes: [
            "create a layer called ", "create layer called ", "make a layer called ",
            "make layer called ", "new layer called ", "name this layer "
        ]) {
            return called
        }

        return extractEntity(in: input, prefixes: [
            "save this layout as ", "save layout as ", "save as layer ", "save as ",
            "create a layer ", "create layer ", "create new layer ",
            "make a layer ", "make layer ", "make a new layer ", "new layer "
        ])
    }

    private func extractLayer(in input: String) -> String? {
        if input == "next layer" || input == "previous layer" {
            return input
        }

        if let literal = [
            "layer one": "1",
            "layer two": "2",
            "layer three": "3",
            "first layer": "1",
            "second layer": "2",
            "third layer": "3",
        ][input] {
            return literal
        }

        if let entity = extractEntity(in: input, prefixes: [
            "switch to layer ", "switch to the ", "switch to ",
            "go to layer ", "go to the ", "go to ",
            "activate layer ", "activate the ", "change to layer ",
            "change layer to ", "layer "
        ]) {
            return cleanLayer(entity)
        }

        return nil
    }

    private func extractEntity(in input: String, prefixes: [String]) -> String? {
        for prefix in prefixes.sorted(by: { $0.count > $1.count }) {
            if input.hasPrefix(prefix) {
                return String(input.dropFirst(prefix.count))
            }
        }
        return nil
    }

    private func normalizeUtterance(_ text: String) -> String {
        var input = text.lowercased()
            .replacingOccurrences(of: #"[^\w\s-]"#, with: " ", options: .regularExpression)
            .split(separator: " ").joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var changed = true
        while changed {
            changed = false
            for prefix in leadingNoise {
                if input.hasPrefix(prefix) {
                    input = String(input.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                    changed = true
                    break
                }
            }
        }

        var stripped = true
        while stripped {
            stripped = false
            for suffix in trailingNoise {
                if input.hasSuffix(suffix) {
                    input = String(input.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
                    stripped = true
                    break
                }
            }
        }

        return input
    }

    private func resolvePosition(in input: String) -> String? {
        let map: [(keywords: [String], position: String)] = [
            (["top left", "upper left", "top-left"], "top-left"),
            (["top right", "upper right", "top-right"], "top-right"),
            (["bottom left", "lower left", "bottom-left"], "bottom-left"),
            (["bottom right", "lower right", "bottom-right"], "bottom-right"),
            (["left half", "left side", "the left", "left"], "left"),
            (["right half", "right side", "the right", "right"], "right"),
            (["maximize", "full screen", "full", "big", "max"], "maximize"),
            (["center", "middle", "centre"], "center"),
            (["top half", "top"], "top"),
            (["bottom half", "bottom"], "bottom"),
        ]

        for entry in map {
            if entry.keywords.contains(where: input.contains) {
                return entry.position
            }
        }
        return nil
    }

    private func directMatch(for input: String) -> IntentMatch? {
        if let intent = exactIntentMatches[input] {
            return IntentMatch(intentName: intent, slots: [:], confidence: 0.99, matchedPhrase: input)
        }

        if let query = exactSearchQuery(for: input) {
            return IntentMatch(
                intentName: "search",
                slots: ["query": .string(query)],
                confidence: 0.98,
                matchedPhrase: input
            )
        }

        // Explicit launch syntax identifies the intent independently of the
        // target's vocabulary. Sentence embeddings can otherwise reject an
        // unfamiliar proper name even in an unambiguous "open <name>" request.
        // The launch handler still validates the target before opening it.
        if let target = exactLaunchTarget(for: input) {
            return IntentMatch(
                intentName: "launch",
                slots: ["project": .string(target)],
                confidence: 0.98,
                matchedPhrase: input
            )
        }

        if let app = exactFocusApp(for: input) {
            return IntentMatch(
                intentName: "focus",
                slots: ["app": .string(app)],
                confidence: 0.98,
                matchedPhrase: input
            )
        }

        if let position = exactTilePosition(for: input) {
            return IntentMatch(
                intentName: "tile_window",
                slots: ["position": .string(position)],
                confidence: 0.99,
                matchedPhrase: input
            )
        }

        if let session = exactKillSession(for: input) {
            return IntentMatch(
                intentName: "kill",
                slots: ["session": .string(session)],
                confidence: 0.98,
                matchedPhrase: input
            )
        }

        return nil
    }

    /// True when another intent declares this exact utterance
    /// as one of its own examples.
    ///
    /// The search shortcuts below are *shape* heuristics — "starts with find",
    /// "ends in windows" — and they run inside `directMatch`, which fires before
    /// any intent gets to compete. So a heuristic about a suffix outranked
    /// intents that had spelled the phrase out, and it did so at 0.98
    /// confidence: `search` claimed nine of the resolver's own declared
    /// examples, including "where's my mouse" (find_mouse), "organize the
    /// windows" (distribute), and "show me all windows" (list_windows). A
    /// confident wrong answer is worse than no answer, because nothing
    /// downstream second-guesses 0.98.
    ///
    /// Yielding here doesn't hand the utterance to the other intent — it just
    /// stops short-circuiting, and lets the semantic scorer below decide on the
    /// merits.
    private func isDeclaredByOtherIntent(_ input: String, excluding intent: String = "search") -> Bool {
        IntentEngine.shared.definitions().contains { def in
            def.name != intent
                && def.examples.contains { normalizeUtterance($0) == input }
        }
    }

    private func exactLaunchTarget(for input: String) -> String? {
        guard !isDeclaredByOtherIntent(input, excluding: "launch"),
              let target = extractEntity(in: input, prefixes: [
                "open up ", "open my ", "open the ", "open ",
                "launch the ", "launch my ", "launch ",
              ]) else { return nil }
        let cleaned = cleanEntity(target)
        return cleaned.isEmpty ? nil : cleaned
    }

    private func exactSearchQuery(for input: String) -> String? {
        guard !isDeclaredByOtherIntent(input) else { return nil }

        if let query = extractSearchQuery(from: input), !query.isEmpty,
           searchPrefixes.contains(where: input.hasPrefix) {
            return cleanQuery(query)
        }

        if input.hasSuffix(" windows"), input != "list windows" {
            let query = cleanQuery(input)
            return query.isEmpty ? nil : query
        }

        return nil
    }

    private func exactFocusApp(for input: String) -> String? {
        if input.hasPrefix("see "), let app = detectKnownApp(in: input) ?? extractEntity(in: input, prefixes: ["see "]) {
            let resolved = resolveApp(app)
            return resolved.isEmpty ? nil : resolved
        }

        if input.hasSuffix(" on screen"), input.hasPrefix("get "),
           let app = extractEntity(in: input, prefixes: ["get "]) {
            let resolved = resolveApp(cleanEntity(app.replacingOccurrences(of: " on screen", with: "")))
            return resolved.isEmpty ? nil : resolved
        }

        return nil
    }

    private func exactTilePosition(for input: String) -> String? {
        if input == "right side" { return "right" }
        if input == "left side" { return "left" }
        return nil
    }

    private func exactKillSession(for input: String) -> String? {
        if input.hasPrefix("kill "), let session = extractEntity(in: input, prefixes: ["kill "]) {
            return session
        }
        if input.hasPrefix("stop "), let session = extractEntity(in: input, prefixes: ["stop "]) {
            return session
        }
        return nil
    }

    private func refersToSelection(in input: String) -> Bool {
        let markers = [
            "grid that", "grid these", "grid those",
            "tile that", "tile these", "tile those",
            "selected windows", "selection", "selected", "these windows", "those windows", "them"
        ]
        return markers.contains(where: input.contains)
    }

    private func detectKnownApp(in input: String) -> String? {
        for app in knownApps() {
            let lower = app.lowercased()
            if input.contains(lower) {
                return app
            }
        }
        return nil
    }

    private func knownApps() -> [String] {
        var names = Set(DesktopModel.shared.windows.values.map(\.app))
        for app in NSWorkspace.shared.runningApplications {
            if let name = app.localizedName, !name.isEmpty {
                names.insert(name)
            }
        }
        return names.sorted { $0.count > $1.count }
    }

    private func resolveApp(_ raw: String) -> String {
        let trimmed = cleanEntity(raw)
        let knownAliases: [String: String] = [
            "visual studio code": "Visual Studio Code",
            "vs code": "Visual Studio Code",
            "vscode": "Visual Studio Code",
            "google chrome": "Google Chrome",
            "iterm2": "iTerm2",
            "iterm": "iTerm2",
        ]

        if let alias = knownAliases[trimmed.lowercased()] {
            return alias
        }

        return trimmed
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    private func cleanLayer(_ raw: String) -> String {
        cleanEntity(raw)
            .replacingOccurrences(of: " layer", with: "")
            .trimmingCharacters(in: .whitespaces)
    }

    private func cleanEntity(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let leading = ["the ", "my ", "a ", "an ", "this ", "that ", "like ", "um ", "uh "]
        let postscriptDelimiters = [
            " in iterm", " in iterm2", " in terminal", " in the terminal",
            " using iterm", " with iterm", " i think ", " i guess ",
            " um ", " uh "
        ]
        let trailing = [
            " please", " for me", " right now", " real quick", " quickly",
            " session", " project", " app", " windows", " window", " layer"
        ]

        var changed = true
        while changed {
            changed = false

            for delimiter in postscriptDelimiters {
                if let range = value.range(of: delimiter) {
                    value = String(value[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
                    changed = true
                }
            }

            for prefix in leading {
                if value.hasPrefix(prefix) {
                    value = String(value.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                    changed = true
                }
            }

            for suffix in trailing {
                if value.hasSuffix(suffix) {
                    value = String(value.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
                    changed = true
                }
            }
        }

        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func cleanQuery(_ raw: String) -> String {
        var query = raw
        let noise = [
            "all instances of ", "all of the ", "all the ", "all ",
            "instances of ", "of the ",
            "that mentioned ", "that mention ", "that say ", "that says ",
            "that have ", "that has ", "that are ", "that is ",
            "everything with ", "everything that has ",
            "windows ", "window ", "windows", "window",
            "stuff ", "stuff", "project ", "project", "app ", "app",
            "with the name ", "named ", "called ",
            "in the title", "in my title", "in the name", "on my screen", "on screen",
            " in it", " in there", " at", " go"
        ]

        for item in noise {
            query = query.replacingOccurrences(of: item, with: " ")
        }

        return query
            .split(separator: " ")
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func tokenOverlap(_ lhs: String, _ rhs: String) -> Double {
        let lhsTokens = Set(lhs.split(separator: " ").map(String.init))
        let rhsTokens = Set(rhs.split(separator: " ").map(String.init))
        guard !lhsTokens.isEmpty, !rhsTokens.isEmpty else { return 0 }
        let intersection = lhsTokens.intersection(rhsTokens).count
        let union = lhsTokens.union(rhsTokens).count
        return Double(intersection) / Double(union)
    }

    private let leadingNoise = [
        "alright let s go ahead and ", "alright let s go ahead ", "let s go ahead and ",
        "alright let s ", "all right let s ",
        "okay let s ", "ok let s ",
        "can you please ", "could you please ", "would you please ",
        "i think i want to ", "i think i need to ",
        "can you ", "could you ", "would you ", "will you ",
        "i want to ", "i d like to ", "i would like to ",
        "i want you to ", "i need to ", "i need you to ",
        "i wanna ", "i think ", "i need ",
        "let s ", "let me ", "please ", "go ahead and ", "just ", "now ",
        "alright ", "all right ",
        "no sorry ", "sorry ", "no wait ", "wait ",
        "actually ", "okay ", "ok ",
        "um ", "uh ", "like ", "hmm ", "yeah ", "hey ", "yo ", "so "
    ]

    private let trailingNoise = [
        " please", " for me", " real quick", " right now", " quickly",
        " if you can", " when you get a chance", " at", " up"
    ]

    private let focusPrefixes = [
        "show me the ", "show me ", "show ", "focus on ", "focus the ", "focus ",
        "switch over to ", "switch to ", "go back to ", "go to ",
        "bring up the ", "bring up ", "bring forward ", "raise the ", "raise ",
        "pull up the ", "pull up ", "i want to see ", "let me see ",
        "take me to ", "give me the ", "give me ", "activate the ", "activate ",
        "jump to ", "can i get ", "see "
    ]

    private let launchPrefixes = [
        "open up ", "open my ", "open the ", "open ",
        "launch the ", "launch my ", "launch ",
        "start working on ", "start up ", "start the ", "start my ", "start ",
        "work on the ", "work on ",
        "begin working on ", "begin ",
        "fire up the ", "fire up ", "spin up ", "boot up ",
        "load up ", "load ", "run the ", "run "
    ]

    private let killPrefixes = [
        "kill the ", "kill ", "stop the ", "stop ",
        "shut down the ", "shut down ", "close the ", "close ",
        "terminate the ", "terminate ", "end the ", "end "
    ]

    private let genericNonCommandPhrases: Set<String> = [
        "what time is it",
        "tell me a joke",
        "how are you doing",
        "the weather today",
        "play some music",
        "set a timer for five minutes"
    ]

    private let intentKeywords: [String: [String]] = [
        "tile_window": ["tile", "snap", "move", "put", "throw", "left", "right", "top", "bottom", "center", "maximize", "full screen"],
        "focus": ["show", "focus", "switch to", "go to", "bring up", "pull up", "activate", "jump to"],
        "launch": ["open", "launch", "start", "begin", "fire up", "boot up", "work on", "run"],
        "switch_layer": ["layer", "switch to", "next layer", "previous layer"],
        "search": ["find", "search", "look for", "where is", "where d", "locate", "lost", "show me all", "windows"],
        "list_windows": ["what s open", "list windows", "which windows", "what do i have open"],
        "list_sessions": ["list sessions", "what s running", "which projects", "show my sessions"],
        "distribute": ["distribute", "spread", "organize", "arrange", "tidy", "clean up", "grid", "selected", "selection"],
        "create_layer": ["create layer", "save layout", "snapshot", "remember this layout"],
        "kill": ["kill", "stop", "shut down", "close", "terminate", "end"],
        "scan": ["scan", "rescan", "ocr", "read the screen", "what s on my screen", "screen text"],
        "help": ["help", "what can i do", "what can you do", "commands", "options"]
    ]

    private let searchPrefixes = [
        "find all the ", "find all ", "find ",
        "search for all ", "search for ", "search ",
        "look for ", "look up ", "locate all ", "locate ",
        "where is ", "where s ", "where does it say ", "where did i see ",
        "which window has ", "which window shows ",
        "help me find ", "can you find ",
        "show me all the ", "show me all ", "show all the ", "show all ",
        "open up all the ", "open up all ", "open all the ", "open all ",
        "pull up everything with ", "pull up all ", "pull up ",
        "bring up all the ", "bring up all ", "bring up my ",
        "where d my ", "i lost my ", "i lost ", "where the hell is ",
        "see all my ", "see all "
    ]

    private let exactIntentMatches: [String: String] = [
        "help": "help",
        "help me": "help",
        "what can i do": "help",
        "what can you do": "help",
        "how does this work": "help",
        "what can i say": "help",
        "what are my options": "help",
        "show me the commands": "help",
        "list windows": "list_windows",
        "what windows do i have": "list_windows",
        "list sessions": "list_sessions",
        "show me my sessions": "list_sessions",
        "rescan": "scan",
        "do a scan": "scan",
        "do a quick scan": "scan",
        "scan the screen": "scan",
        "read the screen": "scan",
        "refresh the screen text": "scan",
        "what s on my screen": "scan",
        "what s on the screen": "scan",
        "show me what s on the screen": "scan",
        "organize": "distribute",
        "organize my windows": "distribute",
        "line everything up": "distribute",
        "let s get everything organized": "distribute",
        "get everything organized": "distribute",
        "clean up the windows": "distribute",
        "tidy up": "distribute"
    ]

    private let supplementalExamples: [String: [String]] = [
        "tile_window": ["put this on the left side", "move this over to the right", "maximize", "center it"],
        "focus": ["i need to see chrome", "can i get safari up", "show me visual studio code"],
        "launch": ["fire up vox", "start working on lattices", "open my notes app"],
        "switch_layer": ["next layer", "previous layer", "switch to review"],
        "search": ["where d my slack go", "pull up everything with dewey in it", "show me all the chrome windows", "dewey"],
        "list_windows": ["what do i have open", "what windows do i have"],
        "list_sessions": ["show me my sessions", "which projects are active"],
        "distribute": ["tidy up", "line everything up", "clean up the windows", "grid that in the bottom half", "arrange the selected windows"],
        "create_layer": ["snapshot this", "remember this layout"],
        "kill": ["close the dewey session", "stop my session"],
        "scan": ["what s on my screen", "read the screen", "give me a fresh scan"],
        "help": ["what can i say", "show me the commands"]
    ]
}
