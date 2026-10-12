import AppKit

struct CompanionAppMenuModel: Equatable {
    struct Item: Equatable {
        let productID: CompanionProductID
        let title: String
        let action: CompanionAppAction
        let actionTitle: String?
        let statusText: String?
    }

    let items: [Item]

    static func make(
        discovery: CompanionAppDiscovery,
        catalog: [CompanionProduct] = CompanionAppCatalog.firstParty
    ) -> CompanionAppMenuModel {
        CompanionAppMenuModel(
            items: catalog.map { product in
                let installState = discovery.installState(for: product)
                let action = CompanionAppCatalog.action(for: product, installState: installState)
                let statusText: String?
                if product.distribution == .notDistributedStandalone {
                    statusText = CompanionAppCatalog.speechStandaloneStatus
                } else {
                    statusText = nil
                }
                return Item(
                    productID: product.id,
                    title: product.displayName,
                    action: action,
                    actionTitle: action.menuTitle,
                    statusText: statusText
                )
            }
        )
    }
}

enum CompanionAppsMenu {
    static let title = "Apps"

    static func attach(to menu: NSMenu) {
        CompanionAppsMenuController.shared.attach(to: menu)
    }

    static func refresh() {
        CompanionAppsMenuController.shared.refresh()
    }
}

final class CompanionAppsMenuController: NSObject, NSMenuDelegate {
    static let shared = CompanionAppsMenuController()

    private let catalog: [CompanionProduct]
    private let discovery: CompanionAppDiscovery
    private let launcher: CompanionAppLauncher
    private let install: (CompanionProductID) -> Void
    private let presentFailure: (String, String) -> Void
    private weak var appsMenu: NSMenu?

    init(
        catalog: [CompanionProduct] = CompanionAppCatalog.firstParty,
        discovery: CompanionAppDiscovery = .system,
        launcher: CompanionAppLauncher = .system(),
        install: @escaping (CompanionProductID) -> Void = { CompanionInstallerBridge.shared.install($0) },
        presentFailure: @escaping (String, String) -> Void = CompanionAppsMenuController.presentAlert
    ) {
        self.catalog = catalog
        self.discovery = discovery
        self.launcher = launcher
        self.install = install
        self.presentFailure = presentFailure
        super.init()
        CompanionInstallerBridge.shared.onChange = { [weak self] in self?.refresh() }
    }

    func attach(to menu: NSMenu) {
        let item = NSMenuItem(title: CompanionAppsMenu.title, action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.delegate = self
        item.submenu = submenu
        menu.addItem(item)
        appsMenu = submenu
        reload(submenu)
    }

    func refresh() {
        if let appsMenu {
            reload(appsMenu)
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        reload(menu)
    }

    func menuWillOpen(_ menu: NSMenu) {
        reload(menu)
    }

    func reload(_ menu: NSMenu) {
        menu.removeAllItems()
        let model = CompanionAppMenuModel.make(discovery: discovery, catalog: catalog)
        for item in model.items {
            let parent = NSMenuItem(title: item.title, action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            if let state = CompanionInstallerBridge.shared.states[item.productID] {
                let labels = ["checking": "Checking…", "downloading": "Downloading…", "verifying": "Verifying…", "installing": "Installing…", "installed": "Installed", "already-installed": "Installed", "cancelled": "Cancelled", "failed": "Installation failed", "needs-bun": "Needs Bun"]
                let status = NSMenuItem(title: labels[state.phase] ?? state.phase, action: nil, keyEquivalent: "")
                status.isEnabled = false
                status.toolTip = state.message
                submenu.addItem(status)
                if let message = state.message, !message.isEmpty {
                    let detail = NSMenuItem(title: message, action: nil, keyEquivalent: "")
                    detail.isEnabled = false
                    submenu.addItem(detail)
                }
                if state.phase == "needs-bun" {
                    let install = NSMenuItem(title: "Install Bun…", action: #selector(installBun(_:)), keyEquivalent: "")
                    install.target = self
                    submenu.addItem(install)
                }
                if state.active {
                    let cancel = NSMenuItem(title: "Cancel", action: #selector(cancelInstallation(_:)), keyEquivalent: "")
                    cancel.target = self
                    cancel.representedObject = item.productID.rawValue
                    submenu.addItem(cancel)
                    parent.submenu = submenu
                    menu.addItem(parent)
                    continue
                }
            }
            let actionItem: NSMenuItem
            if let title = item.actionTitle {
                actionItem = NSMenuItem(title: title, action: #selector(handleMenuItem(_:)), keyEquivalent: "")
                actionItem.target = self
                actionItem.representedObject = MenuActionRef(productID: item.productID, action: item.action)
                actionItem.isEnabled = true
            } else {
                actionItem = NSMenuItem(title: item.statusText ?? "Not available", action: nil, keyEquivalent: "")
                actionItem.isEnabled = false
            }
            submenu.addItem(actionItem)
            parent.submenu = submenu
            menu.addItem(parent)
        }
    }

    @objc private func handleMenuItem(_ sender: NSMenuItem) {
        guard let ref = sender.representedObject as? MenuActionRef else { return }
        if ref.action == .get {
            install(ref.productID)
            return
        }
        launcher.perform(ref.action, productID: ref.productID) { [weak self] result in
            DispatchQueue.main.async {
                self?.present(result, productID: ref.productID)
            }
        }
    }

    @objc private func installBun(_ sender: NSMenuItem) {
        CompanionInstallerBridge.installBun()
    }

    @objc private func cancelInstallation(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let product = CompanionProductID(rawValue: raw) else { return }
        CompanionInstallerBridge.shared.cancel(product)
    }

    private func present(_ result: CompanionAppLaunchResult, productID: CompanionProductID) {
        let name = catalog.first { $0.id == productID }?.displayName ?? "App"
        switch result {
        case .opened, .openedProductPage:
            return
        case .failed(.notInstalled):
            presentFailure("Could Not Open \(name)", "The app is not installed.")
        case .failed(.notDistributedStandalone):
            presentFailure("Unavailable", CompanionAppCatalog.speechStandaloneExplanation)
        case .failed(.missingProductPage):
            presentFailure("Unavailable", "No official product page is available.")
        case .failed(.launchFailed(let message)):
            presentFailure("Could Not Open \(name)", message)
            DiagnosticLog.shared.log("Companion app launch failed for \(name): \(message)", level: .error)
        }
    }

    private static func presentAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

/// `NSMenuItem.representedObject` box for Open/Get.
private final class MenuActionRef: NSObject {
    let productID: CompanionProductID
    let action: CompanionAppAction

    init(productID: CompanionProductID, action: CompanionAppAction) {
        self.productID = productID
        self.action = action
    }
}
