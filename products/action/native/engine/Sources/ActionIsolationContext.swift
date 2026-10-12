import CoreGraphics
import CryptoKit
import Foundation
import IOKit

struct ActionIsolationContext: Encodable {
    struct Display: Encodable {
        struct Bounds: Encodable {
            let x: CGFloat
            let y: CGFloat
            let width: CGFloat
            let height: CGFloat
        }

        struct Mode: Encodable {
            let width: Int
            let height: Int
            let pixelWidth: Int
            let pixelHeight: Int
            let refreshRate: Double
        }

        let id: CGDirectDisplayID
        let bounds: Bounds
        let mode: Mode
        let main: Bool
        let builtIn: Bool
        let active: Bool
        let online: Bool
        let inMirrorSet: Bool
        let mirrorsDisplayID: CGDirectDisplayID
        let rotation: Double
        let vendorID: UInt32
        let productID: UInt32
        let serialNumber: UInt32
    }

    let schemaVersion = 1
    let hostFingerprint: String
    let osBuild: String
    let displayConfiguration: [Display]

    static func capture() throws -> Self {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { throw failure("Host identity is unavailable.") }
        defer { IOObjectRelease(service) }
        guard let hostID = IORegistryEntryCreateCFProperty(service, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String,
              !hostID.isEmpty else { throw failure("Host UUID is unavailable.") }

        var length = 0
        guard sysctlbyname("kern.osversion", nil, &length, nil, 0) == 0, length > 1 else {
            throw failure("OS build is unavailable.")
        }
        var buffer = [CChar](repeating: 0, count: length)
        guard sysctlbyname("kern.osversion", &buffer, &length, nil, 0) == 0 else {
            throw failure("OS build could not be read.")
        }

        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else {
            throw failure("Online displays are unavailable.")
        }
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &displayIDs, &count) == .success else {
            throw failure("Display enumeration failed.")
        }
        let displays = try displayIDs.prefix(Int(count)).sorted().compactMap { displayID -> Display? in
            let vendorID = CGDisplayVendorNumber(displayID)
            let productID = CGDisplayModelNumber(displayID)
            if vendorID == ActionAgentLayerDisplay.vendorID && productID == ActionAgentLayerDisplay.productID { return nil }
            guard let mode = CGDisplayCopyDisplayMode(displayID) else {
                throw failure("Display mode is unavailable for display \(displayID).")
            }
            let bounds = CGDisplayBounds(displayID)
            return Display(
                id: displayID,
                bounds: .init(x: bounds.minX, y: bounds.minY, width: bounds.width, height: bounds.height),
                mode: .init(width: mode.width, height: mode.height, pixelWidth: mode.pixelWidth, pixelHeight: mode.pixelHeight, refreshRate: mode.refreshRate),
                main: CGDisplayIsMain(displayID) != 0,
                builtIn: CGDisplayIsBuiltin(displayID) != 0,
                active: CGDisplayIsActive(displayID) != 0,
                online: CGDisplayIsOnline(displayID) != 0,
                inMirrorSet: CGDisplayIsInMirrorSet(displayID) != 0,
                mirrorsDisplayID: CGDisplayMirrorsDisplay(displayID),
                rotation: CGDisplayRotation(displayID),
                vendorID: vendorID,
                productID: productID,
                serialNumber: CGDisplaySerialNumber(displayID)
            )
        }
        guard !displays.isEmpty else { throw failure("No non-Action displays are available.") }
        return Self(
            hostFingerprint: SHA256.hash(data: Data(hostID.utf8)).map { String(format: "%02x", $0) }.joined(),
            osBuild: String(decoding: buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self),
            displayConfiguration: displays
        )
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "ActionIsolationContext", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
