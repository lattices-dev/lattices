import Darwin
import Foundation

/// Finds bridges by asking every address on this device's own subnet, for the
/// networks where Bonjour never arrives.
///
/// Bonjour is the right default and stays the default: it is cheap, passive,
/// and it tells you a service's name and fingerprint without anyone having to
/// look for it. But plenty of real networks drop multicast — guest Wi‑Fi, most
/// corporate networks, anything with client isolation half-configured — and on
/// those the only route in was typing an address by hand, which means knowing
/// it. Sweeping the subnet is how the app finds a host it can plainly reach.
///
/// This only ever runs when the user asks. It is a burst of a few hundred
/// short-lived requests, which is fine as a deliberate act and would be rude on
/// a timer.
@MainActor
final class LocalNetworkScanner: ObservableObject {

    enum Outcome: Equatable {
        /// Swept the subnet and this is what answered.
        case swept(checked: Int)
        /// The subnet is too big to walk politely — see `maxHosts`.
        case networkTooLarge(hosts: Int)
        /// No usable IPv4 interface, so there is no subnet to sweep.
        case noNetwork
    }

    @Published private(set) var isScanning = false
    /// 0…1 across the sweep, for a determinate bar — the one place in this flow
    /// where a progress indicator is honest, because the work really is finite
    /// and really is countable.
    @Published private(set) var progress: Double = 0
    @Published private(set) var found: [BridgeEndpoint] = []
    @Published private(set) var outcome: Outcome?

    /// Refuse to walk anything bigger than a /23. A /16 is 65,534 probes; at
    /// that size this stops being a scan and starts being a nuisance to every
    /// other device on the network.
    private let maxHosts = 512
    /// How many probes are in the air at once. High enough to finish a /24 in a
    /// few seconds, low enough not to exhaust the socket budget.
    private let concurrency = 24

    func reset() {
        found = []
        outcome = nil
        progress = 0
    }

    func scan(port: Int = 9399) async {
        guard !isScanning else { return }

        guard let interface = LocalNetworkProbe.primaryIPv4Interface() else {
            outcome = .noNetwork
            return
        }

        let hosts = interface.hostAddresses
        guard hosts.count <= maxHosts else {
            outcome = .networkTooLarge(hosts: hosts.count)
            return
        }

        isScanning = true
        progress = 0
        found = []
        outcome = nil
        defer { isScanning = false }

        let targets = hosts.filter { $0 != interface.address }
        var completed = 0

        await withTaskGroup(of: BridgeEndpoint?.self) { group in
            var next = 0
            let window = min(concurrency, targets.count)

            while next < window {
                let address = targets[next]
                group.addTask { await LocalNetworkProbe.probe(address: address, port: port) }
                next += 1
            }

            while let result = await group.next() {
                completed += 1
                progress = targets.isEmpty ? 1 : Double(completed) / Double(targets.count)

                if let result, !found.contains(where: { $0.host == result.host }) {
                    found.append(result)
                }

                if next < targets.count {
                    let address = targets[next]
                    group.addTask { await LocalNetworkProbe.probe(address: address, port: port) }
                    next += 1
                }
            }
        }

        progress = 1
        outcome = .swept(checked: targets.count)
    }
}

// MARK: - Probing
//
// Deliberately outside the actor: each probe is network work and has no reason
// to touch the main thread.

enum LocalNetworkProbe {

    struct IPv4Interface {
        let name: String
        /// Host byte order throughout — the bit arithmetic below is unreadable
        /// otherwise.
        let address: UInt32
        let netmask: UInt32

        /// Every address on this subnet except the network and broadcast ones.
        var hostAddresses: [UInt32] {
            let network = address & netmask
            let broadcast = network | ~netmask
            guard broadcast > network + 1 else { return [] }
            return Array((network + 1)...(broadcast - 1))
        }
    }

    /// The interface this device would actually reach a Mac over. Wi‑Fi wins
    /// when present, because that is where a companion bridge lives; anything
    /// else usable is a fallback rather than a guess.
    static func primaryIPv4Interface() -> IPv4Interface? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }

        var fallback: IPv4Interface?

        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(pointer.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            guard let addressPointer = pointer.pointee.ifa_addr,
                  addressPointer.pointee.sa_family == UInt8(AF_INET),
                  let maskPointer = pointer.pointee.ifa_netmask else { continue }

            let name = String(cString: pointer.pointee.ifa_name)
            let address = addressPointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
            }
            let netmask = maskPointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
            }
            guard netmask != 0 else { continue }

            let interface = IPv4Interface(name: name, address: address, netmask: netmask)
            if name == "en0" { return interface }
            if fallback == nil { fallback = interface }
        }

        return fallback
    }

    /// Sessions are per-probe-batch rather than shared, so a sweep can't leave
    /// a pile of idle connections behind it.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 1.5
        configuration.timeoutIntervalForResource = 2
        configuration.httpMaximumConnectionsPerHost = 1
        configuration.waitsForConnectivity = false
        configuration.allowsCellularAccess = false
        return URLSession(configuration: configuration)
    }()

    /// Ask one address whether it is a Lattices bridge.
    ///
    /// The answer has to be a bridge health payload, not merely an open port —
    /// plenty of things listen on plenty of ports, and a scan that reported
    /// them would fill the picker with everything on the network.
    static func probe(address: UInt32, port: Int) async -> BridgeEndpoint? {
        let host = ipv4String(address)

        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = port
        components.path = "/health"
        guard let url = components.url else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 1.5
        request.httpMethod = "GET"

        guard
            let (data, response) = try? await session.data(for: request),
            let http = response as? HTTPURLResponse,
            http.statusCode == 200,
            let health = try? JSONDecoder().decode(BridgeHealthResponse.self, from: data),
            health.ok
        else {
            return nil
        }

        let name = health.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return BridgeEndpoint(
            // The address is where it actually answered, so that is what we
            // keep — `health.hostName` may be a name this network can't resolve,
            // which is very often exactly why Bonjour failed here too.
            name: name.isEmpty ? host : name,
            host: host,
            port: port,
            source: "Scan",
            bridgeFingerprint: health.bridgeFingerprint,
            securityMode: health.mode,
            capabilities: health.capabilities ?? []
        )
    }

    static func ipv4String(_ address: UInt32) -> String {
        "\((address >> 24) & 0xFF).\((address >> 16) & 0xFF).\((address >> 8) & 0xFF).\(address & 0xFF)"
    }
}
