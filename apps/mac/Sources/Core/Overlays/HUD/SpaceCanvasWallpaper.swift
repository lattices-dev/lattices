import AppKit
import AVFoundation
import ImageIO

/// One decoded still of the screen's configured wallpaper for the fixed
/// canvas backdrop. macOS does not expose arbitrary inactive-Space wallpapers
/// through NSWorkspace. This never switches a Space or changes its wallpaper.
@MainActor
final class SpaceCanvasWallpaper {
    struct Image {
        let cgImage: CGImage
        let contentsRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    }

    static let shared = SpaceCanvasWallpaper()

    /// Only the inexpensive AppKit configuration lookup runs on the main actor.
    /// Cancel on close; decoding may finish into the bounded cache, but a late
    /// result cannot invoke the canvas callback after cancellation.
    @discardableResult
    func load(for screen: NSScreen, receive: @escaping (Image?) -> Void) -> Task<Void, Never> {
        let options = NSWorkspace.shared.desktopImageOptions(for: screen) ?? [:]
        let color = (options[.fillColor] as? NSColor)?.usingColorSpace(.sRGB)
            ?? NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        let displayUUID = displayID.flatMap { CGDisplayCreateUUIDFromDisplayID($0)?.takeRetainedValue() }
            .map { CFUUIDCreateString(nil, $0) as String }
        let request = SpaceCanvasWallpaperRequest(
            url: NSWorkspace.shared.desktopImageURL(for: screen), displayUUID: displayUUID,
            width: max(1, Int((screen.frame.width * screen.backingScaleFactor).rounded())),
            height: max(1, Int((screen.frame.height * screen.backingScaleFactor).rounded())),
            scaling: (options[.imageScaling] as? NSNumber)?.uintValue ?? NSImageScaling.scaleProportionallyUpOrDown.rawValue,
            clipping: (options[.allowClipping] as? NSNumber)?.boolValue ?? false,
            red: color.redComponent, green: color.greenComponent, blue: color.blueComponent)
        return Task.detached(priority: .utility) {
            let image = await SpaceCanvasWallpaperCache.shared.image(for: request)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard !Task.isCancelled else { return }
                receive(image.map { Image(cgImage: $0) })
            }
        }
    }

    /// Geometry is in display pixels, independent of the bounded decode size.
    nonisolated static func imageRect(image: CGSize, display: CGSize, scaling: NSImageScaling,
                                     clipping: Bool) -> CGRect {
        guard image.width > 0, image.height > 0, display.width > 0, display.height > 0 else { return .zero }
        if scaling == .scaleAxesIndependently { return CGRect(origin: .zero, size: display) }
        let ratios = (display.width / image.width, display.height / image.height)
        let factor: CGFloat
        switch scaling {
        case .scaleNone: factor = 1
        case .scaleProportionallyDown: factor = min(1, clipping ? max(ratios.0, ratios.1) : min(ratios.0, ratios.1))
        default: factor = clipping ? max(ratios.0, ratios.1) : min(ratios.0, ratios.1)
        }
        let size = CGSize(width: image.width * factor, height: image.height * factor)
        return CGRect(x: (display.width - size.width) / 2, y: (display.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    /// Recent macOS aerials can leave NSWorkspace pointing at DefaultDesktop.
    /// Recognize only the observed, local aerial configuration. Per-Space
    /// overrides and unknown providers retain the public-API fallback.
    nonisolated static func aerialAssetID(in data: Data, displayUUID: String?) -> String? {
        guard let store = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              (store["Spaces"] as? [String: Any] ?? [:]).isEmpty else { return nil }
        let displays = store["Displays"] as? [String: Any] ?? [:]
        let entry = displayUUID.flatMap { displays[$0] as? [String: Any] }
            ?? store["AllSpacesAndDisplays"] as? [String: Any]
        guard let desktop = entry?["Desktop"] as? [String: Any],
              let content = desktop["Content"] as? [String: Any],
              let choices = content["Choices"] as? [[String: Any]], choices.count == 1,
              choices[0]["Provider"] as? String == "com.apple.wallpaper.choice.aerials",
              let configuration = choices[0]["Configuration"] as? Data,
              let values = try? PropertyListSerialization.propertyList(from: configuration, format: nil) as? [String: Any],
              let id = values["assetID"] as? String, UUID(uuidString: id) != nil else { return nil }
        return id
    }
}

private struct SpaceCanvasWallpaperRequest: Hashable {
    var url: URL?
    let displayUUID: String?
    let width: Int
    let height: Int
    let scaling: UInt
    var clipping: Bool
    let red: CGFloat
    let green: CGFloat
    let blue: CGFloat
}

/// No AppKit objects cross into the worker. Cache keys include the source's
/// modification date, and the cache retains at most 32 MiB of decoded pixels.
private actor SpaceCanvasWallpaperCache {
    static let shared = SpaceCanvasWallpaperCache()
    private struct Key: Hashable {
        let request: SpaceCanvasWallpaperRequest
        let modified: Date?
    }
    private var images: [Key: CGImage] = [:]
    private var order: [Key] = []
    private var pending: [Key: Task<CGImage?, Never>] = [:]
    private let maximumBytes = 32 * 1024 * 1024
    private var bytes = 0

    func image(for original: SpaceCanvasWallpaperRequest) async -> CGImage? {
        var request = original
        if let aerial = Self.aerialURL(displayUUID: request.displayUUID) {
            request.url = aerial
            request.clipping = true // Aerials fill the screen; NSWorkspace's empty options are stale too.
        }
        guard let url = request.url, url.isFileURL else { return nil }
        let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let key = Key(request: request, modified: modified)
        if let image = images[key] {
            order.removeAll { $0 == key }; order.append(key)
            return image
        }
        if let task = pending[key] { return await task.value }
        let task = Task<CGImage?, Never>.detached(priority: .utility) {
            if let image = await Self.decode(request) { return image }
            // A present but incomplete aerial download must not suppress a
            // usable image from the public wallpaper API.
            guard request.url != original.url else { return nil }
            return await Self.decode(original)
        }
        pending[key] = task
        let image = await task.value
        pending[key] = nil
        guard let image else { return nil }
        let cost = image.bytesPerRow * image.height
        while bytes + cost > maximumBytes, let oldest = order.first {
            order.removeFirst()
            if let removed = images.removeValue(forKey: oldest) { bytes -= removed.bytesPerRow * removed.height }
        }
        if cost <= maximumBytes { images[key] = image; order.append(key); bytes += cost }
        return image
    }

    private static func aerialURL(displayUUID: String?) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let wallpaper = home.appendingPathComponent("Library/Application Support/com.apple.wallpaper")
        guard let data = try? Data(contentsOf: wallpaper.appendingPathComponent("Store/Index.plist")),
              let asset = SpaceCanvasWallpaper.aerialAssetID(in: data, displayUUID: displayUUID) else { return nil }
        let roots = [wallpaper.appendingPathComponent("aerials/videos"),
                     URL(fileURLWithPath: "/Library/Application Support/com.apple.idleassetsd/Customer/4KSDR240FPS")]
        return roots.map { $0.appendingPathComponent(asset).appendingPathExtension("mov") }
            .first { FileManager.default.isReadableFile(atPath: $0.path) }
    }

    private static func decode(_ request: SpaceCanvasWallpaperRequest) async -> CGImage? {
        guard let url = request.url else { return nil }
        let maximum = 2560
        let decoded: CGImage
        let naturalSize: CGSize
        if let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
           let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximum,
            kCGImageSourceShouldCacheImmediately: true] as CFDictionary) {
            decoded = image
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            var width = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? Double(image.width)
            var height = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? Double(image.height)
            if (5...8).contains((properties?[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1) { swap(&width, &height) }
            naturalSize = CGSize(width: width, height: height)
        } else {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: maximum, height: maximum)
            // A stable still avoids a video decoder and texture uploads during zoom.
            guard let result = try? await generator.image(at: .zero) else { return nil }
            decoded = result.image
            naturalSize = CGSize(width: decoded.width, height: decoded.height)
        }
        let display = CGSize(width: request.width, height: request.height)
        let factor = min(1, CGFloat(maximum) / max(display.width, display.height))
        let width = max(1, Int((display.width * factor).rounded()))
        let height = max(1, Int((display.height * factor).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(red: request.red, green: request.green, blue: request.blue, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: CGFloat(width) / display.width, y: CGFloat(height) / display.height)
        context.interpolationQuality = .high
        context.draw(decoded, in: SpaceCanvasWallpaper.imageRect(image: naturalSize, display: display,
            scaling: NSImageScaling(rawValue: request.scaling) ?? .scaleProportionallyUpOrDown,
            clipping: request.clipping))
        return context.makeImage()
    }
}
