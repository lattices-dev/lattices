import AppKit
import SwiftUI

@MainActor
final class RemoteVNCWindows: NSObject, NSWindowDelegate {
    static let shared = RemoteVNCWindows()
    private var windows: [String: NSWindow] = [:]
    private var forms: [NSWindow: RemoteVNCForm] = [:]

    func show(host: String, address: String, platform: String?, displayIndex: Int? = nil) {
        if let window = windows[host] { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let form = RemoteVNCForm(host: host, address: address, platform: platform, displayIndex: displayIndex)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 340),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "VNC · \(host)"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: RemoteVNCConnectionView(form: form))
        window.delegate = self
        windows[host] = window; forms[window] = form
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, let form = forms.removeValue(forKey: window) else { return }
        form.cancel()
        windows.removeValue(forKey: form.host)
    }
}

@MainActor
final class RemoteVNCForm: ObservableObject {
    let host: String
    let platform: String?
    let displayIndex: Int?
    @Published var settings: RemoteVNCSettings
    @Published var port: String
    @Published private(set) var busy = false
    @Published private(set) var message: String?
    private var task: Task<Void, Never>?

    init(host: String, address: String, platform: String?, displayIndex: Int?) {
        self.host = host; self.platform = platform; self.displayIndex = displayIndex
        let settings = RemoteVNCConnections.shared.settings(host: host, address: address, platform: platform)
        self.settings = settings; port = String(settings.port)
    }

    func connect() {
        guard !busy else { return }
        guard let port = Int(port), (1...65535).contains(port) else { message = "Enter a VNC port between 1 and 65535."; return }
        var settings = settings
        settings.address = settings.address.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.port = port
        settings.startLinuxServer = platform == "linux" && settings.throughSSH && settings.startLinuxServer
        busy = true; message = nil
        task = Task {
            defer { busy = false; task = nil }
            do {
                try await RemoteVNCConnections.shared.connect(host: host, settings: settings, displayIndex: displayIndex)
                message = "Opened in Screen Sharing."
            } catch is CancellationError { message = nil }
            catch { message = error.localizedDescription }
        }
    }

    func cancel() { task?.cancel() }
}

private struct RemoteVNCConnectionView: View {
    @ObservedObject var form: RemoteVNCForm
    @ObservedObject private var connections = RemoteVNCConnections.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Connect with VNC").font(.headline)
            Text("Open \(form.host)’s desktop in macOS Screen Sharing.")
                .font(.callout).foregroundStyle(.secondary)
            Form {
                Picker("Connection", selection: $form.settings.throughSSH) {
                    Text("Through SSH").tag(true)
                    Text("Direct VNC").tag(false)
                }
                TextField(form.settings.throughSSH ? "SSH host" : "VNC address", text: $form.settings.address)
                    .help(form.settings.throughSSH ? "An SSH host or user@host. Uses your existing SSH configuration, keys and known hosts." : "The VNC server’s hostname or IP address.")
                TextField("VNC port", text: $form.port)
                if form.platform == "linux", form.settings.throughSSH {
                    Toggle("Start WayVNC on this machine", isOn: $form.settings.startLinuxServer)
                        .help("Uses the remote Lattices host over SSH. WayVNC must be installed and configured for VNC authentication.")
                }
            }
            .disabled(form.busy)
            if form.settings.throughSSH {
                Text("SSH forwards the remote VNC port securely. Disconnect the tunnel here when finished; quitting Lattices also closes it.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Direct VNC requires a server already listening on the remote machine’s network address. To start WayVNC with Lattices, choose Through SSH.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let message = form.message { Text(message).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
            HStack {
                if connections.connected.contains(form.host) {
                    Button("Disconnect VNC") { connections.disconnect(form.host) }.disabled(form.busy)
                }
                Spacer()
                if form.busy {
                    ProgressView().controlSize(.small)
                    Button("Cancel") { form.cancel() }
                } else {
                    Button("Connect", action: form.connect).keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20).frame(width: 460)
    }
}
