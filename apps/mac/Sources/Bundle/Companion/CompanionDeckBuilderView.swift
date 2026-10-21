import SwiftUI
import WebKit
import AppKit
import Foundation

/// Embeds the bundled static deck editor without a network listener.
///
/// Bridge: the builder posts every layout change to
/// `window.webkit.messageHandlers.deck` as `{ type: "deck-change", decks }`.
/// The coordinator maps the builder model into the persisted Mac cockpit
/// layout, which is then published to connected iPad companions.
struct CompanionDeckBuilderView: NSViewRepresentable {
    var layout: LatticesCompanionCockpitLayout
    var onChange: (LatticesCompanionCockpitLayout) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(onChange: onChange) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let controller = WKUserContentController()
        controller.add(context.coordinator, name: "deck")
        if let json = Self.builderJSON(for: layout),
           let catalogJSON = Self.builderCatalogJSON() {
            controller.addUserScript(WKUserScript(
                source: "window.__DECK_INIT__ = \(json); window.__DECK_CATALOG__ = \(catalogJSON);",
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            ))
        }
        config.userContentController = controller
        config.setURLSchemeHandler(CompanionDeckBundleHandler(), forURLScheme: CompanionDeckTransport.scheme)

        let web = WKWebView(frame: .zero, configuration: config)
        // Dark, non-white background so entering the page doesn't flash white
        // before the (dark) editor paints. `drawsBackground` is transparent so
        // the surrounding panel shows through; underPageBackgroundColor kills the
        // white overscroll/rubber-band edge on macOS 12+.
        web.setValue(false, forKey: "drawsBackground")
        if #available(macOS 12.0, *) {
            web.underPageBackgroundColor = NSColor(red: 6.0 / 255, green: 6.0 / 255, blue: 7.0 / 255, alpha: 1)
        }
        web.navigationDelegate = context.coordinator
        context.coordinator.web = web
        web.load(URLRequest(url: CompanionDeckTransport.indexURL))
        return web
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    static func dismantleNSView(_ web: WKWebView, coordinator: Coordinator) {
        web.stopLoading()
        web.configuration.userContentController.removeScriptMessageHandler(forName: "deck")
        web.navigationDelegate = nil
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        let onChange: (LatticesCompanionCockpitLayout) -> Void
        weak var web: WKWebView?
        private var showingError = false

        init(onChange: @escaping (LatticesCompanionCockpitLayout) -> Void) {
            self.onChange = onChange
        }

        func userContentController(
            _ controller: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == "deck", message.frameInfo.isMainFrame,
                  let url = message.frameInfo.request.url, CompanionDeckTransport.isDocument(url) else { return }
            guard
                let dict = message.body as? [String: Any],
                dict["type"] as? String == "deck-change",
                let decks = dict["decks"],
                let data = try? JSONSerialization.data(withJSONObject: decks), data.count <= 1_048_576
            else { return }
            persistCompanionDeckDraft(data)
            guard let layout = CompanionDeckBuilderView.liveLayout(from: data) else { return }
            onChange(layout)
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard action.targetFrame?.isMainFrame == true,
                  let url = action.request.url, CompanionDeckTransport.isDocument(url) else {
                decisionHandler(.cancel); return
            }
            decisionHandler(.allow)
        }

        // An incomplete bundle should show a useful local hint.
        func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation!,
            withError error: Error
        ) { showUnavailable(in: webView) }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) { showUnavailable(in: webView) }

        private func showUnavailable(in webView: WKWebView) {
            guard !showingError else { return }
            showingError = true
            let html = """
            <html><body style="margin:0;background:#060607;color:#71716c;\
            font-family:ui-monospace,Menlo,monospace;font-size:12px;\
            display:flex;align-items:center;justify-content:center;height:100vh">\
            embedded deck builder unavailable — reinstall the current Lattices app</body></html>
            """
            webView.loadHTMLString(html, baseURL: CompanionDeckTransport.indexURL)
        }
    }

    static func importedLayout(fromBuilderDraft data: Data) -> LatticesCompanionCockpitLayout? {
        liveLayout(from: data)
    }
}

/// Only this bundled document may call the native persistence bridge.
enum CompanionDeckTransport {
    static let scheme = "lattices-deck"
    static let host = "bundle"
    static let indexURL = URL(string: "\(scheme)://\(host)/deck-builder")!
    static func isLocal(_ url: URL) -> Bool {
        url.scheme == scheme && url.host == host && url.user == nil && url.password == nil && url.port == nil
    }
    static func isDocument(_ url: URL) -> Bool {
        isLocal(url) && ["/deck-builder", "/index.html"].contains(url.path)
    }
}

final class CompanionDeckBundleHandler: NSObject, WKURLSchemeHandler {
    private let roots: [URL]
    init(roots: [URL] = LatticesCompanionBridgeServer.deckBuilderResourceRoots()) {
        self.roots = roots.map { $0.standardizedFileURL.resolvingSymlinksInPath() }
    }

    func file(for url: URL) throws -> URL {
        guard CompanionDeckTransport.isLocal(url), !url.path.contains("\0"), !url.path.contains("\\"),
              CompanionDeckTransport.isDocument(url) || url.path.hasPrefix("/_next/static/") else {
            throw URLError(.noPermissionsToReadFile)
        }
        let path = CompanionDeckTransport.isDocument(url) ? "index.html" : String(url.path.dropFirst())
        for root in roots {
            let file = root.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
            guard file.path.hasPrefix(root.path + "/"),
                  (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            return file
        }
        throw URLError(.fileDoesNotExist)
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        do {
            guard let url = task.request.url, task.request.httpMethod == "GET" else { throw URLError(.unsupportedURL) }
            let file = try file(for: url)
            let data = try Data(contentsOf: file)
            let types = ["html": "text/html", "js": "text/javascript", "mjs": "text/javascript", "css": "text/css",
                         "json": "application/json", "map": "application/json", "svg": "image/svg+xml",
                         "woff": "font/woff", "woff2": "font/woff2", "png": "image/png", "jpg": "image/jpeg", "webp": "image/webp"]
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: [
                "Content-Type": types[file.pathExtension.lowercased()] ?? "application/octet-stream",
                "Content-Security-Policy": "default-src 'none'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; font-src 'self'; connect-src 'none'; frame-src 'none'; base-uri 'none'; form-action 'none'",
                "X-Content-Type-Options": "nosniff"
            ])!
            task.didReceive(response); task.didReceive(data); task.didFinish()
        } catch { task.didFailWithError(error) }
    }
    // Reads complete synchronously, so there is no pending work to cancel.
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

extension CompanionDeckBuilderView {
    struct BuilderDeck: Codable {
        var id: String
        var name: String
        var subtitle: String?
        var tint: String
        var columns: Int
        var rows: Int
        var keys: [BuilderKey]
    }

    struct BuilderKey: Codable {
        var id: String
        var label: String
        var icon: String
        var tint: String
        var category: String
        var actionID: String
        var baseLabel: String?
        var baseIcon: String?
        var baseTint: String?
        var baseCategory: String?
        var col: Int
        var row: Int
        var colSpan: Int
        var rowSpan: Int
    }

    struct BuilderCatalogGroup: Codable {
        var group: String
        var items: [BuilderCatalogItem]
    }

    struct BuilderCatalogItem: Codable {
        var id: String
        var label: String
        var icon: String
        var tint: String
        var category: String
    }

    static func builderCatalogJSON() -> String? {
        let groups = LatticesCompanionShortcutCategory.allCases.compactMap { category -> BuilderCatalogGroup? in
            let items = LatticesCompanionCockpitCatalog.shortcuts.compactMap { definition -> BuilderCatalogItem? in
                guard !definition.id.isEmpty, definition.category == category else { return nil }
                return BuilderCatalogItem(
                    id: definition.id,
                    label: definition.title,
                    icon: builderIcon(for: definition.id),
                    tint: definition.category.tintToken,
                    category: definition.category.rawValue
                )
            }
            guard !items.isEmpty else { return nil }
            return BuilderCatalogGroup(group: category.title, items: items)
        }
        guard let data = try? JSONEncoder().encode(groups) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func builderJSON(for layout: LatticesCompanionCockpitLayout) -> String? {
        let normalized = LatticesCompanionCockpitCatalog.normalized(layout)
        let decks = normalized.pages.map { page -> BuilderDeck in
            let slots: [LatticesCompanionCockpitLayout.Slot]
            if let positioned = page.slots {
                slots = positioned
            } else {
                slots = page.slotIDs.enumerated().compactMap { index, shortcutID in
                    guard !shortcutID.isEmpty else { return nil }
                    return .init(
                        shortcutID: shortcutID,
                        col: index % max(1, page.columns),
                        row: index / max(1, page.columns)
                    )
                }
            }

            let keys = slots.enumerated().compactMap { index, slot -> BuilderKey? in
                guard let definition = LatticesCompanionCockpitCatalog.definition(for: slot.shortcutID),
                      !slot.shortcutID.isEmpty else { return nil }
                return BuilderKey(
                    id: "\(page.id)-\(index)",
                    label: slot.customLabel ?? definition.title,
                    icon: slot.customBuilderIcon ?? builderIcon(for: slot.shortcutID),
                    tint: slot.customTint ?? definition.category.tintToken,
                    category: slot.customCategory ?? definition.category.rawValue,
                    actionID: slot.shortcutID,
                    baseLabel: definition.title,
                    baseIcon: builderIcon(for: slot.shortcutID),
                    baseTint: definition.category.tintToken,
                    baseCategory: definition.category.rawValue,
                    col: slot.col,
                    row: slot.row,
                    colSpan: slot.colSpan,
                    rowSpan: slot.rowSpan
                )
            }
            return BuilderDeck(
                id: page.id,
                name: page.title,
                subtitle: page.subtitle,
                tint: keys.first?.tint ?? "blue",
                columns: page.columns,
                rows: page.rows ?? max(1, Int(ceil(Double(max(1, page.slotIDs.count)) / Double(max(1, page.columns))))),
                keys: keys
            )
        }
        guard let data = try? JSONEncoder().encode(decks) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func liveLayout(from data: Data) -> LatticesCompanionCockpitLayout? {
        guard let decks = try? JSONDecoder().decode([BuilderDeck].self, from: data) else { return nil }
        let pages = decks.map { deck in
            LatticesCompanionCockpitLayout.Page(
                id: deck.id,
                title: deck.name,
                subtitle: deck.subtitle,
                columns: min(5, max(2, deck.columns)),
                rows: min(4, max(1, deck.rows)),
                slots: deck.keys.prefix(LatticesCompanionCockpitCatalog.slotCount).compactMap { key in
                    let shortcutID = canonicalShortcutID(key.actionID)
                    guard let definition = LatticesCompanionCockpitCatalog.definition(for: shortcutID) else { return nil }
                    let defaultIcon = builderIcon(for: shortcutID)
                    return .init(
                        shortcutID: shortcutID,
                        col: key.col,
                        row: key.row,
                        colSpan: max(1, key.colSpan),
                        rowSpan: max(1, key.rowSpan),
                        customLabel: key.label == (key.baseLabel ?? definition.title) ? nil : key.label,
                        customBuilderIcon: key.icon == (key.baseIcon ?? defaultIcon) ? nil : key.icon,
                        customTint: key.tint == (key.baseTint ?? definition.category.tintToken) ? nil : key.tint,
                        customCategory: key.category == (key.baseCategory ?? definition.category.rawValue) ? nil : key.category
                    )
                }
            )
        }
        return LatticesCompanionCockpitCatalog.normalized(.init(pages: pages))
    }

    static func canonicalShortcutID(_ builderID: String) -> String {
        let legacy: [String: String] = [
            "voice.toggle": "voice-toggle", "voice.cancel": "voice-cancel",
            "key.escape": "key-escape", "key.enter": "key-enter", "key.space": "key-space",
            "switch.appPrev": "switch-app-prev", "switch.appNext": "switch-app-next",
            "switch.winPrev": "switch-window-prev", "switch.winNext": "switch-window-next",
            "layout.optimize": "layout-optimize", "layout.left": "place-left",
            "layout.right": "place-right", "layout.center": "place-center",
            "layout.maximize": "place-maximize", "mouse.find": "mouse-find",
            "mouse.summon": "mouse-summon", "mouse.joystick": "mouse-joystick",
        ]
        return legacy[builderID] ?? builderID
    }

    static func builderIcon(for shortcutID: String) -> String {
        let icons: [String: String] = [
            "voice-toggle": "Mic", "voice-cancel": "X", "key-escape": "CornerDownLeft",
            "key-enter": "CornerDownLeft", "key-space": "SpaceIcon",
            "switch-app-prev": "ChevronLeft", "switch-app-next": "ChevronRight",
            "switch-window-prev": "ArrowLeft", "switch-window-next": "ArrowRight",
            "layout-optimize": "LayoutGrid", "place-left": "PanelLeft", "place-right": "PanelRight",
            "place-center": "SquareDashed", "place-maximize": "Maximize2",
            "mouse-find": "Crosshair", "mouse-summon": "MousePointer2", "mouse-joystick": "Joystick",
            "paste-device": "ClipboardPaste",
        ]
        return icons[shortcutID] ?? "SquareDashed"
    }
}

/// Keep the builder's raw payload as a diagnostic draft alongside the canonical
/// UserDefaults-backed cockpit layout.
func persistCompanionDeckDraft(_ data: Data) {
    let dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".lattices", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try? data.write(to: dir.appendingPathComponent("companion-deck-draft.json"), options: .atomic)
}
