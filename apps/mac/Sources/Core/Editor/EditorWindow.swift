import AppKit
import WebKit
import SwiftUI
import Combine

/// All transport constants live here. This scheme serves bundled files only;
/// it neither opens a port nor starts the Companion bridge.
enum EditorTransport {
    static let scheme = "lattices-editor"
    static let host = "bundle"
    static let handler = "hudsonEditor"
    static let event = "hudson:host-event"
    static let indexURL = URL(string: "\(scheme)://\(host)/index.html")!
    static func isLocal(_ url: URL) -> Bool {
        url.scheme == scheme && url.host == host && url.user == nil && url.password == nil && url.port == nil
    }
}

final class EditorBundleHandler: NSObject, WKURLSchemeHandler {
    let root: URL
    init(root: URL) { self.root = root.standardizedFileURL.resolvingSymlinksInPath() }

    func file(for url: URL) throws -> URL {
        guard EditorTransport.isLocal(url), !url.path.contains("\0"), !url.path.contains("\\") else {
            throw EditorBridgeError("unavailable", "Editor resource origin is not allowed.")
        }
        let candidate = root.appendingPathComponent(url.path).standardizedFileURL.resolvingSymlinksInPath()
        guard candidate.path.hasPrefix(root.path + "/") else {
            throw EditorBridgeError("unavailable", "Editor resource must be inside its bundle.")
        }
        return candidate
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        do {
            guard let url = task.request.url, task.request.httpMethod == "GET" else {
                throw EditorBridgeError("unavailable", "Only bundled Editor resources can be read.")
            }
            let file = try file(for: url)
            let data = try Data(contentsOf: file)
            let types = ["html": "text/html", "js": "text/javascript", "css": "text/css",
                         "json": "application/json", "svg": "image/svg+xml", "woff2": "font/woff2",
                         "png": "image/png", "ico": "image/x-icon"]
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: [
                "Content-Type": types[file.pathExtension] ?? "application/octet-stream",
                "Content-Security-Policy": "default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self'; connect-src 'none'; frame-src 'none'; base-uri 'none'; form-action 'none'",
                "X-Content-Type-Options": "nosniff"
            ])!
            task.didReceive(response); task.didReceive(data); task.didFinish()
        } catch { task.didFailWithError(error) }
    }
    // Reads are synchronous; there is no queued task to cancel after return.
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

final class EditorWebHost: NSObject, WKScriptMessageHandlerWithReply, WKNavigationDelegate {
    let web: WKWebView
    private let bridge: EditorBridge
    private var timer: Timer?
    private var failed = false

    init(bundleRoot: URL, bridge: EditorBridge = EditorBridge(capture: { try LayerIndexState.shared.snapshot() })) {
        self.bridge = bridge
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(EditorBundleHandler(root: bundleRoot), forURLScheme: EditorTransport.scheme)
        // Persistent default store retains subject-scoped layout across closing
        // and reopening. No workspace config is ever stored by this webview.
        configuration.websiteDataStore = .default()
        web = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        configuration.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: EditorTransport.handler)
        web.navigationDelegate = self
        web.setValue(false, forKey: "drawsBackground")
        web.underPageBackgroundColor = NSColor(Palette.bg)
        bridge.onEvent = { [weak self] event in
            guard let self else { return }
            // callAsyncJavaScript passes structured arguments, never interpolates
            // source/config strings into executable JavaScript.
            self.web.callAsyncJavaScript(
                "window.dispatchEvent(new CustomEvent(eventName, {detail: envelope}));",
                arguments: ["eventName": EditorTransport.event, "envelope": event], in: nil,
                in: .page, completionHandler: nil)
        }
    }

    func start() {
        web.load(URLRequest(url: EditorTransport.indexURL))
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.bridge.poll() }
    }

    func stop() {
        timer?.invalidate(); timer = nil
        bridge.onEvent = nil
        web.configuration.userContentController.removeScriptMessageHandler(forName: EditorTransport.handler, contentWorld: .page)
        web.stopLoading()
        web.navigationDelegate = nil
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        guard message.name == EditorTransport.handler, message.frameInfo.isMainFrame,
              let url = message.frameInfo.request.url, EditorTransport.isLocal(url) else {
            replyHandler(nil, "Editor messages require the bundled main frame."); return
        }
        replyHandler(bridge.reply(to: message.body), nil)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url,
              (EditorTransport.isLocal(url) && navigationAction.targetFrame?.isMainFrame == true)
                || (failed && url.absoluteString == "about:blank") else {
            decisionHandler(.cancel); return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { unavailable() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { unavailable() }
    private func unavailable() {
        guard !failed else { return }
        failed = true
        web.loadHTMLString("""
        <!doctype html><meta name="color-scheme" content="dark"><title>Lattices Editor</title>
        <body style="background:#060607;color:#d4d4d4;font:14px system-ui;padding:32px">
        <h1 style="font-size:18px">Editor unavailable in this Lattices version</h1>
        <p>The bundled Editor could not be loaded. Install a build that includes the Editor bundle.</p>
        </body>
        """, baseURL: nil)
    }
}

/// Compatibility entry point for menu items and lattices://editor.
/// The standalone window has been removed.
final class EditorWindowController {
    static let shared = EditorWindowController()
    func show() { ScreenMapWindowController.shared.showPage(.layers) }
}

/// Owns a single WKWebView independently of SwiftUI's page-view lifetime.
/// Switching pages only detaches/reattaches it; start() is called exactly once.
final class LayersPageModel: ObservableObject {
    static let shared = LayersPageModel()
    @Published private(set) var state: EditorUIState?
    private let bridge = EditorBridge(hostChrome: true, capture: { try LayerIndexState.shared.snapshot() })
    private var assistantWatches: [String: AnyCancellable] = [:]
    private var assistants: [String: WorkspaceAssistantSession] = [:]
    private var assistantLayerId: String?
    private func assistant(for layerId: String) -> WorkspaceAssistantSession {
        if let session = assistants[layerId] { return session }
        let session = WorkspaceAssistantSession.makeEditorSession()
        assistants[layerId] = session
        assistantWatches[layerId] = session.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.bridge.publishAssistantState(layerId: layerId) }
        }
        return session
    }
    private var selectionWatch: AnyCancellable?
    private var retainedHost: EditorWebHost?

    var host: EditorWebHost {
        if let retainedHost { return retainedHost }
        bridge.actionCapture = { try EditorBridge.liveSnapshot() }
        bridge.actions = EditorActions(execute: { try WorkspaceManager.shared.executeEditorAction($0) }, reveal: {
            let outcome = WorkspaceManager.shared.exitLayers()
            return ["restored": outcome.unparked.count, "skipped": outcome.remainingToRestore]
        }, journalFactory: { EditorMutationJournal() })
        bridge.assistantState = { [weak self] requested in
            guard let self, let layerId = requested ?? self.assistantLayerId else {
                return ["layerId": NSNull(), "messages": [], "isSending": false, "error": NSNull(), "suggestions": []]
            }
            let assistant = self.assistant(for: layerId)
            return
            ["layerId": layerId, "messages": assistant.messages.map { ["id": $0.id.uuidString, "role": String(describing: $0.role), "text": $0.text] },
             "isSending": assistant.isSending, "error": assistant.editorError as Any? ?? NSNull(),
             "suggestions": assistant.editorSuggestions]
        }
        bridge.assistantSend = { [weak self] text, layerId, snapshot in
            guard let self else { throw EditorBridgeError("unavailable", "Editor closed.") }
            self.assistantLayerId = layerId
            let assistant = self.assistant(for: layerId)
            guard !assistant.isSending else { throw EditorBridgeError("busy", "Wait for the current answer.") }
            let group = (snapshot.projection["groups"] as? [[String: Any]])?.first { $0["id"] as? String == layerId }
            let context: [String: Any] = ["layerId": layerId, "source": snapshot.subject.source,
                "projection": group as Any? ?? NSNull()]
            let data = try JSONSerialization.data(withJSONObject: context, options: [.sortedKeys])
            assistant.send(text, editorContext: String(decoding: data, as: UTF8.self), layerId: layerId)
        }
        bridge.selectedLayerIds = { LayerIndexState.shared.selected }
        bridge.onUIState = { [weak self] state in
            DispatchQueue.main.async {
                self?.state = state
                if let ids = state.selectedLayerIds { LayerIndexState.shared.select(ids) }
            }
        }
        selectionWatch = LayerIndexState.shared.$selected.dropFirst().sink { [weak self] ids in
            guard let self, self.state != nil, self.state?.selectedLayerIds != ids else { return }
            self.bridge.selectLayers(ids)
        }
        let root = AppResources.directory(named: "Editor") ?? {
            // Loading fails and shows the "Editor unavailable" page instead of trapping.
            DiagnosticLog.shared.error("Editor: no bundled Editor resources found")
            return Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/Editor", isDirectory: true)
        }()
        let host = EditorWebHost(bundleRoot: root, bridge: bridge)
        retainedHost = host
        host.start()
        return host
    }

    func command(_ command: String, value: String? = nil) {
        guard state != nil else { return }
        bridge.sendUICommand(command, value: value)
    }

    var actions: [PageAction] {
        let viewSelector = PageAction(id: "layers.view", title: "Layers view", isEnabled: state != nil,
                                     segments: EditorUIState.views.map { view in
            PageActionItem(id: view, title: view.capitalized, isOn: (state?.view ?? "overview") == view) {
                self.command("view", value: view)
            }
        })
        guard state?.view == "workspace" else { return [viewSelector] }
        return [
            viewSelector,
            PageAction(id: "layers.arrangement", title: "Arrangement", icon: "rectangle.3.group",
                       isEnabled: state != nil, menu: EditorUIState.arrangements.map { value in
                PageActionItem(id: value, title: value.capitalized, isOn: state?.arrangement == value) {
                    self.command("arrangement", value: value)
                }
            }),
            PageAction(id: "layers.panels", title: "Panels", icon: "sidebar.left",
                       isEnabled: state != nil, menu: EditorUIState.panelIDs.map { value in
                PageActionItem(id: value, title: value.capitalized, isOn: state?.panels.contains(value) == true) {
                    self.command("togglePanel", value: value)
                }
            }),
            PageAction(id: "layers.source", title: "Inspect source", icon: "curlybraces",
                       isEnabled: state != nil, isOn: state?.sourceOpen == true) {
                self.command("toggleSource")
            }
        ]
    }
}

struct LayersPage: View {
    @ObservedObject private var model = LayersPageModel.shared
    @ObservedObject private var workspace = WorkspaceManager.shared
    var body: some View {
        VStack(spacing: 0) {
            if let message = workspace.layerRecoveryMessage {
                Text(message)
                    .font(Typo.body())
                    .foregroundColor(Palette.textDim)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
            }
            LayersWebView(host: model.host)
        }
            .background(Palette.bg)
            .pageActions(model.actions + [PageAction(
                id: "layers.exit", title: "Exit Layers", icon: "rectangle.portrait.and.arrow.right"
            ) { workspace.exitLayers() }])
    }
}

private struct LayersWebView: NSViewRepresentable {
    let host: EditorWebHost
    func makeNSView(context: Context) -> WKWebView { host.web }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
