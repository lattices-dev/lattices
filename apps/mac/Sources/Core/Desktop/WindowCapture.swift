import CoreGraphics
import ScreenCaptureKit

enum WindowCapture {
    private static var lastDeniedLogAt: Date?
    private(set) static var lastFailureWasPermission = false

    // ScreenCaptureKit replacement for the macOS-26-removed
    // CGWindowListCreateImage window snapshot path. Callers still pass the
    // same CoreGraphics-style options, but unsupported combinations degrade
    // to nil instead of falling back to private/dlsym'd CoreGraphics symbols.
    static func image(
        bounds: CGRect = .null,
        listOption: CGWindowListOption,
        windowID: CGWindowID,
        imageOption: CGWindowImageOption
    ) async -> CGImage? {
        _ = listOption
        guard hasScreenRecordingAccess() else { return nil }

        do {
            let content = try await SCShareableContent.current
            guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
                return nil
            }

            let filter = SCContentFilter(desktopIndependentWindow: window)
            let contentInfo = SCShareableContent.info(for: filter)
            let configuration = SCStreamConfiguration()

            if let sourceRect = sourceRect(from: bounds) {
                configuration.sourceRect = sourceRect
            }

            let pointSize = captureSize(
                bounds: bounds,
                contentRect: contentInfo.contentRect,
                windowFrame: window.frame
            )
            let scale = outputScale(for: imageOption, contentInfo: contentInfo)
            configuration.width = max(1, Int((pointSize.width * scale).rounded(.up)))
            configuration.height = max(1, Int((pointSize.height * scale).rounded(.up)))
            configuration.captureResolution = captureResolution(for: imageOption)
            configuration.scalesToFit = true
            configuration.preservesAspectRatio = true
            configuration.showsCursor = false
            configuration.ignoreShadowsSingleWindow = imageOption.contains(.boundsIgnoreFraming)
            configuration.ignoreGlobalClipSingleWindow = true
            configuration.capturesShadowsOnly = imageOption.contains(.onlyShadows)
            configuration.shouldBeOpaque = imageOption.contains(.shouldBeOpaque)

            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )
            lastFailureWasPermission = false
            return image
        } catch {
            logCaptureFailure("image wid=\(windowID)", error)
            return nil
        }
    }

    static func region(
        rect: CGRect,
        imageOption: CGWindowImageOption = [.bestResolution]
    ) async -> CGImage? {
        guard !rect.isNull, !rect.isInfinite, !rect.isEmpty else {
            return nil
        }
        guard hasScreenRecordingAccess() else { return nil }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                true,
                onScreenWindowsOnly: true
            )
            guard let selection = regionSelection(for: rect, displays: content.displays) else {
                return nil
            }

            let filter = SCContentFilter(display: selection.display, excludingWindows: [])
            let contentInfo = SCShareableContent.info(for: filter)
            let scale = outputScale(for: imageOption, contentInfo: contentInfo)
            let configuration = SCStreamConfiguration()
            configuration.sourceRect = selection.sourceRect
            configuration.width = max(1, Int((selection.sourceRect.width * scale).rounded(.up)))
            configuration.height = max(1, Int((selection.sourceRect.height * scale).rounded(.up)))
            configuration.captureResolution = captureResolution(for: imageOption)
            configuration.scalesToFit = true
            configuration.preservesAspectRatio = true
            configuration.showsCursor = false
            configuration.shouldBeOpaque = imageOption.contains(.shouldBeOpaque)

            return try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )
        } catch {
            logCaptureFailure("region", error)
            return nil
        }
    }

    /// Capture one complete display exactly as WindowServer composites it.
    ///
    /// A display filter with no excluded windows intentionally includes
    /// Lattices overlays along with the underlying apps. That makes this path
    /// suitable for diagnostic snapshots of transient UI such as Hyper+G.
    static func display(
        displayID: CGDirectDisplayID,
        showsCursor: Bool = true,
        imageOption: CGWindowImageOption = [.bestResolution],
        excludingWindowIDs: [CGWindowID] = [],
        maximumPixelSize: CGFloat? = nil
    ) async -> CGImage? {
        guard hasScreenRecordingAccess() else { return nil }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                return nil
            }

            let excluded = content.windows.filter { excludingWindowIDs.contains($0.windowID) }
            let filter = SCContentFilter(display: display, excludingWindows: excluded)
            filter.includeMenuBar = true
            let contentInfo = SCShareableContent.info(for: filter)
            let scale = outputScale(for: imageOption, contentInfo: contentInfo)
            var pixelWidth = CGFloat(display.width) * scale
            var pixelHeight = CGFloat(display.height) * scale
            if let maximumPixelSize, max(pixelWidth, pixelHeight) > maximumPixelSize {
                let fit = maximumPixelSize / max(pixelWidth, pixelHeight)
                pixelWidth *= fit
                pixelHeight *= fit
            }
            let configuration = SCStreamConfiguration()
            configuration.width = max(1, Int(pixelWidth.rounded(.up)))
            configuration.height = max(1, Int(pixelHeight.rounded(.up)))
            configuration.captureResolution = captureResolution(for: imageOption)
            configuration.scalesToFit = true
            configuration.preservesAspectRatio = true
            configuration.showsCursor = showsCursor
            configuration.shouldBeOpaque = true

            return try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )
        } catch {
            logCaptureFailure("display \(displayID)", error)
            return nil
        }
    }

    /// Small shots of specific windows, including ones on other Spaces.
    /// One window list is fetched, then captures run a few at a time in the
    /// given order; `onBatch` gets each group as soon as it lands. Stops
    /// early when the calling task is cancelled.
    @discardableResult
    static func thumbnails(
        windowIDs: [CGWindowID],
        maximumPixelSize: CGFloat,
        ignoreShadows: Bool = false,
        nativeResolution: Bool = false,
        onBatch: (@Sendable ([CGWindowID: CGImage]) async -> Void)? = nil
    ) async -> [CGWindowID: CGImage] {
        guard hasScreenRecordingAccess(), !windowIDs.isEmpty else { return [:] }
        do {
            let content = try await SCShareableContent.current
            let byID = Dictionary(content.windows.map { ($0.windowID, $0) }, uniquingKeysWith: { first, _ in first })
            let windows = windowIDs.compactMap { byID[$0] }
            var images: [CGWindowID: CGImage] = [:]
            var index = 0
            while index < windows.count {
                if Task.isCancelled { break }
                let end = min(index + 4, windows.count)
                let chunk = windows[index..<end]
                index = end
                var batch: [CGWindowID: CGImage] = [:]
                await withTaskGroup(of: (CGWindowID, CGImage)?.self) { group in
                    for window in chunk {
                        group.addTask {
                            let filter = SCContentFilter(desktopIndependentWindow: window)
                            let configuration = SCStreamConfiguration()
                            let pixelScale = nativeResolution
                                ? CGFloat(SCShareableContent.info(for: filter).pointPixelScale) : 1
                            let pixelSize = thumbnailPixelSize(pointSize: window.frame.size,
                                                               pointPixelScale: pixelScale,
                                                               maximumPixelSize: maximumPixelSize)
                            configuration.width = Int(pixelSize.width)
                            configuration.height = Int(pixelSize.height)
                            configuration.captureResolution = nativeResolution ? .best : .nominal
                            configuration.scalesToFit = true
                            configuration.preservesAspectRatio = true
                            configuration.showsCursor = false
                            configuration.ignoreShadowsSingleWindow = ignoreShadows
                            configuration.ignoreGlobalClipSingleWindow = true
                            guard let image = try? await SCScreenshotManager.captureImage(
                                contentFilter: filter,
                                configuration: configuration
                            ) else { return nil }
                            return (window.windowID, image)
                        }
                    }
                    for await item in group {
                        if let (id, image) = item {
                            batch[id] = image
                        }
                    }
                }
                images.merge(batch) { _, new in new }
                if let onBatch, !batch.isEmpty { await onBatch(batch) }
            }
            return images
        } catch {
            logCaptureFailure("thumbnails", error)
            return [:]
        }
    }

    /// Respect the window's native pixel density without manufacturing extra
    /// detail. The limit is in pixels, including on Retina displays.
    static func thumbnailPixelSize(pointSize: CGSize, pointPixelScale: CGFloat,
                                   maximumPixelSize: CGFloat) -> CGSize {
        guard pointSize.width.isFinite, pointSize.height.isFinite,
              pointSize.width > 0, pointSize.height > 0 else {
            return CGSize(width: 1, height: 1)
        }
        let density = pointPixelScale.isFinite ? max(1, pointPixelScale) : 1
        let limit = maximumPixelSize.isFinite ? max(1, maximumPixelSize.rounded(.down)) : 1
        let longest = max(pointSize.width, pointSize.height)
        let scale = min(density, limit / longest)
        return CGSize(width: min(limit, max(1, (pointSize.width * scale).rounded(.up))),
                      height: min(limit, max(1, (pointSize.height * scale).rounded(.up))))
    }

    static func hasScreenRecordingAccess() -> Bool {
        let granted = CGPreflightScreenCaptureAccess()
        if !granted { logDeniedOnce() }
        return granted
    }

    private static func logCaptureFailure(_ label: String, _ error: Error) {
        let nsError = error as NSError
        lastFailureWasPermission = isPermissionError(nsError)
        DiagnosticLog.shared.warn(
            "WindowCapture.\(label) failed: \(nsError.domain)#\(nsError.code) \(nsError.localizedDescription)"
        )
    }

    private static func isPermissionError(_ error: NSError) -> Bool {
        if error.code == -3801 || error.code == 3801 { return true }
        let haystack = "\(error.domain) \(error.localizedDescription)".lowercased()
        return haystack.contains("not authorized")
            || haystack.contains("denied")
            || haystack.contains("tcc")
            || haystack.contains("screen recording")
    }

    private static func logDeniedOnce() {
        let now = Date()
        if let lastDeniedLogAt, now.timeIntervalSince(lastDeniedLogAt) < 10 { return }
        lastDeniedLogAt = now
        DiagnosticLog.shared.warn("WindowCapture: Screen Recording not granted; skipping capture")
    }

    private struct RegionSelection {
        let display: SCDisplay
        let sourceRect: CGRect
    }

    private static func sourceRect(from bounds: CGRect) -> CGRect? {
        guard !bounds.isNull, !bounds.isInfinite, !bounds.isEmpty else {
            return nil
        }
        return bounds
    }

    private static func captureSize(
        bounds: CGRect,
        contentRect: CGRect,
        windowFrame: CGRect
    ) -> CGSize {
        if let sourceRect = sourceRect(from: bounds) {
            return sourceRect.size
        }
        if !contentRect.isNull, !contentRect.isEmpty {
            return contentRect.size
        }
        return windowFrame.size
    }

    private static func captureResolution(
        for imageOption: CGWindowImageOption
    ) -> SCCaptureResolutionType {
        if imageOption.contains(.bestResolution) {
            return .best
        }
        if imageOption.contains(.nominalResolution) {
            return .nominal
        }
        return .automatic
    }

    private static func outputScale(
        for imageOption: CGWindowImageOption,
        contentInfo: SCShareableContentInfo
    ) -> CGFloat {
        if imageOption.contains(.nominalResolution) {
            return 1
        }
        return max(CGFloat(contentInfo.pointPixelScale), 1)
    }

    private static func regionSelection(
        for rect: CGRect,
        displays: [SCDisplay]
    ) -> RegionSelection? {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        guard let display = displays.first(where: { $0.frame.contains(center) })
                ?? displays.first(where: { $0.frame.intersects(rect) })
                ?? displays.first else {
            return nil
        }
        let clipped = rect.intersection(display.frame)
        guard !clipped.isNull, !clipped.isEmpty else {
            return nil
        }
        return RegionSelection(
            display: display,
            sourceRect: CGRect(
                x: clipped.origin.x - display.frame.origin.x,
                y: clipped.origin.y - display.frame.origin.y,
                width: clipped.width,
                height: clipped.height
            )
        )
    }
}
