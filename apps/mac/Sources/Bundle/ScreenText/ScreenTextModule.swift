import Foundation

/// Screen text history: the SQLite record of every scan and the endpoints
/// that read it. The live index is core (`OcrModel`, `ocr.snapshot`,
/// `ocr.scan`); this module keeps what it scanned after the window changes.
final class ScreenTextModule: BundleModule {
    let id = "screen-text"

    func startServices() {
        OcrStore.shared.open()
        ScreenText.shared.installHistory(OcrStore.shared)
    }

    func registerEndpoints(_ api: LatticesApi) {
        api.register(Endpoint(
            method: "ocr.search",
            description: "Search OCR text across all windows (queries persistent SQLite FTS5 index by default)",
            access: .read,
            params: [
                Param(name: "query", type: "string", required: true, description: "Search text (FTS5 query syntax)"),
                Param(name: "app", type: "string", required: false, description: "Filter by app name"),
                Param(name: "limit", type: "int", required: false, description: "Max results (default 50)"),
                Param(name: "live", type: "bool", required: false, description: "Search in-memory snapshot instead of history (default false)"),
            ],
            returns: .array(model: "OcrSearchResult"),
            handler: { params in
                guard let query = params?["query"]?.stringValue else {
                    throw RouterError.missingParam("query")
                }
                let app = params?["app"]?.stringValue
                let limit = min(1000, max(0, params?["limit"]?.intValue ?? 50))
                let live = params?["live"]?.boolValue ?? false

                if live {
                    // In-memory snapshot search (original behavior)
                    var results = Array(OcrModel.shared.results.values)
                    let q = query.lowercased()
                    results = results.filter { $0.fullText.lowercased().contains(q) }
                    if let app { results = results.filter { $0.app == app } }
                    return .array(results.prefix(limit).map { Encoders.ocrResult($0) })
                }

                // Persistent FTS5 search
                let results = OcrStore.shared.search(query: query, app: app, limit: limit)
                return .array(results.map { Encoders.ocrSearchResult($0) })
            }
        ))

        api.register(Endpoint(
            method: "ocr.history",
            description: "Get the OCR content timeline for one window, or across all windows when wid is omitted (chronological, from persistent store)",
            access: .read,
            params: [
                Param(name: "wid", type: "uint32", required: false, description: "Window ID; omit for every window"),
                Param(name: "limit", type: "int", required: false, description: "Max results (default 50)"),
            ],
            returns: .array(model: "OcrSearchResult"),
            handler: { params in
                let limit = min(1000, max(0, params?["limit"]?.intValue ?? 50))
                let results = params?["wid"]?.uint32Value.map { OcrStore.shared.history(wid: $0, limit: limit) }
                    ?? OcrStore.shared.recent(limit: limit)
                return .array(results.map { Encoders.ocrSearchResult($0) })
            }
        ))
    }
}

extension OcrStore: ScreenTextHistory {}
