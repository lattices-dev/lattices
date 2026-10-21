import Foundation

enum CompanionProductID: String, CaseIterable, Equatable {
    case blink
    case action
    case speech
}

enum CompanionDistributionAvailability: Equatable {
    /// A standalone product with an established bundle identity; release availability is resolved on demand.
    case standaloneApp
    /// No standalone bundle identity or installable artifact exists.
    case notDistributedStandalone
}

enum CompanionAppAction: Equatable {
    case open
    case get
    case none

    var menuTitle: String? {
        switch self {
        case .open: return "Open"
        case .get: return "Install"
        case .none: return nil
        }
    }
}

enum CompanionInstallState: Equatable {
    case installed(url: URL)
    case missing
}

struct CompanionProduct: Equatable {
    let id: CompanionProductID
    let displayName: String
    let bundleIdentifier: String?
    let productPageURL: URL?
    let distribution: CompanionDistributionAvailability
}

enum CompanionProductPages {
    static let blink = URL(string: "https://lattices.dev/canvas")!
    static let action = URL(string: "https://lattices.dev/action")!
}

enum CompanionBundleIdentifiers {
    static let blink = "dev.arach.blink"
    static let action = "dev.lattices.Action"
    static let speech = "dev.lattices.Speech"
}

struct CompanionProductState: Equatable {
    let product: CompanionProduct
    let installedURLs: [URL]

    var isInstalled: Bool { !installedURLs.isEmpty }
    var preferredURL: URL? { installedURLs.first }

    var installState: CompanionInstallState {
        if let url = preferredURL {
            return .installed(url: url)
        }
        return .missing
    }
}

enum CompanionAppCatalog {
    static let speechStandaloneStatus = "This product is not available as a standalone app."
    static let speechStandaloneExplanation =
        "No standalone distribution is configured for this product."

    static let firstParty: [CompanionProduct] = [
        CompanionProduct(
            id: .blink,
            displayName: "Canvas",
            bundleIdentifier: CompanionBundleIdentifiers.blink,
            productPageURL: CompanionProductPages.blink,
            distribution: .standaloneApp
        ),
        CompanionProduct(
            id: .action,
            displayName: "Action",
            bundleIdentifier: CompanionBundleIdentifiers.action,
            productPageURL: CompanionProductPages.action,
            distribution: .standaloneApp
        ),
        CompanionProduct(
            id: .speech,
            displayName: "Voice",
            bundleIdentifier: CompanionBundleIdentifiers.speech,
            productPageURL: nil,
            distribution: .standaloneApp
        ),
    ]

    static func product(id: CompanionProductID) -> CompanionProduct {
        firstParty.first { $0.id == id }!
    }

    /// Open a validated standalone install. Install resolves and verifies the product release
    /// when that app is missing.
    static func action(
        for product: CompanionProduct,
        installState: CompanionInstallState
    ) -> CompanionAppAction {
        switch product.distribution {
        case .notDistributedStandalone:
            return .none
        case .standaloneApp:
            switch installState {
            case .installed:
                return .open
            case .missing:
                return .get
            }
        }
    }

    static func states(using discovery: CompanionAppDiscovery) -> [CompanionProductState] {
        firstParty.map { product in
            CompanionProductState(
                product: product,
                installedURLs: discovery.installedURLs(for: product)
            )
        }
    }
}
