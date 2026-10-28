import AppKit
import CryptoKit
import CoreGraphics
import Foundation

final class CaptureController {
    static let shared = CaptureController()

    private init() {}

    private final class CaptureBox {
        private let lock = NSLock()
        private var image: CGImage?

        func set(_ image: CGImage?) {
            lock.lock()
            self.image = image
            lock.unlock()
        }

        func value() -> CGImage? {
            lock.lock()
            defer { lock.unlock() }
            return image
        }
    }

    func screenshotWindow(params: JSON?) throws -> JSON {
        let source = params?["source"]?.stringValue ?? "daemon"
        let target = try resolveWindow(params: params)
        let ownsRun = params?["runId"]?.stringValue?.isEmpty ?? true
        let run = try resolveRun(
            params: params,
            title: params?["title"]?.stringValue ?? "Screenshot \(target.app)",
            source: source,
            surfaces: [.window(target)]
        )

        if ownsRun {
            _ = try RunStore.shared.markRunning(
                id: run.id,
                summary: "Capturing window screenshot",
                data: ["wid": .int(Int(target.wid)), "app": .string(target.app)]
            )
        } else {
            _ = try RunStore.shared.appendTrace(
                id: run.id,
                kind: "capture.screenshot.started",
                summary: "Capturing window screenshot",
                data: ["wid": .int(Int(target.wid)), "app": .string(target.app)]
            )
        }

        let filename = sanitizedFilename(
            params?["filename"]?.stringValue
                ?? "screenshot-window-\(target.wid)-\(Self.fileTimestamp()).png"
        )
        let outputURL = RunStore.shared.artifactURL(for: run, filename: filename)
        let startedAt = Date()

        do {
            let cgImage = try captureWindowImage(wid: target.wid, timeoutSeconds: 15)
            let data = try pngData(from: cgImage)
            try data.write(to: outputURL, options: .atomic)

            let artifact = RunStore.shared.makeArtifact(
                run: run,
                kind: "screenshot",
                url: outputURL,
                mimeType: "image/png",
                metadata: [
                    "wid": .int(Int(target.wid)),
                    "app": .string(target.app),
                    "title": .string(target.title),
                    "width": .int(cgImage.width),
                    "height": .int(cgImage.height),
                    "byteSize": .int(data.count),
                    "elapsedMs": .int(Int(Date().timeIntervalSince(startedAt) * 1000)),
                    "frame": .object([
                        "x": .double(target.frame.x),
                        "y": .double(target.frame.y),
                        "w": .double(target.frame.w),
                        "h": .double(target.frame.h),
                    ]),
                ]
            )
            let updated = try RunStore.shared.appendArtifact(artifact)
            let responseRun: RunSession
            if ownsRun {
                responseRun = try RunStore.shared.complete(
                    id: updated.id,
                    summary: "Saved window screenshot",
                    data: ["artifactId": .string(artifact.id), "path": .string(artifact.path)]
                )
            } else {
                responseRun = try RunStore.shared.appendTrace(
                    id: updated.id,
                    kind: "capture.screenshot.saved",
                    summary: "Saved window screenshot",
                    data: ["artifactId": .string(artifact.id), "path": .string(artifact.path)]
                )
            }

            return .object([
                "ok": .bool(true),
                "run": responseRun.json,
                "artifact": artifact.json,
                "target": Encoders.window(target),
            ])
        } catch {
            let data: [String: JSON] = [
                "wid": .int(Int(target.wid)),
                "error": .string(error.localizedDescription),
            ]
            if ownsRun {
                _ = try? RunStore.shared.fail(
                    id: run.id,
                    summary: "Window screenshot failed",
                    data: data
                )
            } else {
                _ = try? RunStore.shared.appendTrace(
                    id: run.id,
                    kind: "capture.screenshot.failed",
                    summary: "Window screenshot failed",
                    data: data
                )
            }
            throw RouterError.custom("Window \(target.wid) capture failed: \(error.localizedDescription). Check Screen Recording permission; the window may be unavailable or excluded from capture. Retry lats windows --include-panels --json. For a composited still run: lats capture region --x \(target.frame.x) --y \(target.frame.y) --width \(target.frame.w) --height \(target.frame.h) (includes overlapping apps).")
        }
    }

    func screenshotRegion(params: JSON?) throws -> JSON {
        let source = params?["source"]?.stringValue ?? "daemon"
        let resolved = try resolveRegion(params: params)
        let ownsRun = params?["runId"]?.stringValue?.isEmpty ?? true
        let run = try resolveRun(
            params: params,
            title: params?["title"]?.stringValue ?? "Screenshot Region",
            source: source,
            surfaces: resolved.surfaces
        )

        if ownsRun {
            _ = try RunStore.shared.markRunning(
                id: run.id,
                summary: "Capturing region screenshot",
                data: ["region": regionJSON(resolved.rect)]
            )
        } else {
            _ = try RunStore.shared.appendTrace(
                id: run.id,
                kind: "capture.screenshotRegion.started",
                summary: "Capturing region screenshot",
                data: ["region": regionJSON(resolved.rect)]
            )
        }

        let filename = sanitizedFilename(
            params?["filename"]?.stringValue
                ?? "screenshot-region-\(Self.fileTimestamp()).png"
        )
        let outputURL = RunStore.shared.artifactURL(for: run, filename: filename)
        let startedAt = Date()

        do {
            let cgImage = try captureRegionImage(rect: resolved.rect, timeoutSeconds: 15)
            let data = try pngData(from: cgImage)
            try data.write(to: outputURL, options: .atomic)

            var metadata: [String: JSON] = [
                "width": .int(cgImage.width),
                "height": .int(cgImage.height),
                "byteSize": .int(data.count),
                "elapsedMs": .int(Int(Date().timeIntervalSince(startedAt) * 1000)),
                "region": regionJSON(resolved.rect),
            ]
            if let target = resolved.target {
                metadata["wid"] = .int(Int(target.wid))
                metadata["app"] = .string(target.app)
                metadata["title"] = .string(target.title)
            }

            let artifact = RunStore.shared.makeArtifact(
                run: run,
                kind: "screenshot-region",
                url: outputURL,
                mimeType: "image/png",
                metadata: metadata
            )
            let updated = try RunStore.shared.appendArtifact(artifact)
            let responseRun: RunSession
            if ownsRun {
                responseRun = try RunStore.shared.complete(
                    id: updated.id,
                    summary: "Saved region screenshot",
                    data: ["artifactId": .string(artifact.id), "path": .string(artifact.path)]
                )
            } else {
                responseRun = try RunStore.shared.appendTrace(
                    id: updated.id,
                    kind: "capture.screenshotRegion.saved",
                    summary: "Saved region screenshot",
                    data: ["artifactId": .string(artifact.id), "path": .string(artifact.path)]
                )
            }

            var object: [String: JSON] = [
                "ok": .bool(true),
                "run": responseRun.json,
                "artifact": artifact.json,
                "region": regionJSON(resolved.rect),
            ]
            if let target = resolved.target {
                object["target"] = Encoders.window(target)
            }
            return .object(object)
        } catch {
            let data: [String: JSON] = [
                "region": regionJSON(resolved.rect),
                "error": .string(error.localizedDescription),
            ]
            if ownsRun {
                _ = try? RunStore.shared.fail(
                    id: run.id,
                    summary: "Region screenshot failed",
                    data: data
                )
            } else {
                _ = try? RunStore.shared.appendTrace(
                    id: run.id,
                    kind: "capture.screenshotRegion.failed",
                    summary: "Region screenshot failed",
                    data: data
                )
            }
            throw error
        }
    }

    func screenshotDisplay(params: JSON?) throws -> JSON {
        let source = params?["source"]?.stringValue ?? "daemon"
        let resolved = try resolveDisplay(params: params)
        let showsCursor = params?["cursor"]?.boolValue ?? true
        let clipboardRequested = params?["clipboard"]?.boolValue ?? true
        let ownsRun = params?["runId"]?.stringValue?.isEmpty ?? true
        let run = try resolveRun(
            params: params,
            title: params?["title"]?.stringValue ?? "Screenshot \(resolved.name)",
            source: source,
            surfaces: [resolved.surface]
        )

        if ownsRun {
            _ = try RunStore.shared.markRunning(
                id: run.id,
                summary: "Capturing display screenshot",
                data: [
                    "display": resolved.json,
                    "cursor": .bool(showsCursor),
                    "clipboard": .bool(clipboardRequested),
                ]
            )
        } else {
            _ = try RunStore.shared.appendTrace(
                id: run.id,
                kind: "capture.screenshotDisplay.started",
                summary: "Capturing display screenshot",
                data: [
                    "display": resolved.json,
                    "cursor": .bool(showsCursor),
                    "clipboard": .bool(clipboardRequested),
                ]
            )
        }

        let filename = sanitizedFilename(
            params?["filename"]?.stringValue
                ?? "screenshot-display-\(resolved.index)-\(Self.fileTimestamp()).png"
        )
        let outputURL = RunStore.shared.artifactURL(for: run, filename: filename)
        let startedAt = Date()

        do {
            let cgImage = try captureDisplayImage(
                displayID: resolved.displayID,
                showsCursor: showsCursor,
                timeoutSeconds: 15
            )
            let data = try pngData(from: cgImage)
            try data.write(to: outputURL, options: .atomic)
            let clipboardCopied = clipboardRequested ? copyPNGToClipboard(data) : false

            let artifact = RunStore.shared.makeArtifact(
                run: run,
                kind: "screenshot-display",
                url: outputURL,
                mimeType: "image/png",
                metadata: [
                    "displayIndex": .int(resolved.index),
                    "displayID": .int(Int(resolved.displayID)),
                    "displayName": .string(resolved.name),
                    "width": .int(cgImage.width),
                    "height": .int(cgImage.height),
                    "byteSize": .int(data.count),
                    "elapsedMs": .int(Int(Date().timeIntervalSince(startedAt) * 1000)),
                    "cursor": .bool(showsCursor),
                    "clipboardRequested": .bool(clipboardRequested),
                    "clipboardCopied": .bool(clipboardCopied),
                    "frame": regionJSON(resolved.frame),
                ]
            )
            let updated = try RunStore.shared.appendArtifact(artifact)
            let completionData: [String: JSON] = [
                "artifactId": .string(artifact.id),
                "path": .string(artifact.path),
                "displayIndex": .int(resolved.index),
                "clipboardCopied": .bool(clipboardCopied),
            ]
            let responseRun: RunSession
            if ownsRun {
                responseRun = try RunStore.shared.complete(
                    id: updated.id,
                    summary: "Saved display screenshot",
                    data: completionData
                )
            } else {
                responseRun = try RunStore.shared.appendTrace(
                    id: updated.id,
                    kind: "capture.screenshotDisplay.saved",
                    summary: "Saved display screenshot",
                    data: completionData
                )
            }

            return .object([
                "ok": .bool(true),
                "run": responseRun.json,
                "artifact": artifact.json,
                "display": resolved.json,
                "cursor": .bool(showsCursor),
                "clipboard": .object([
                    "requested": .bool(clipboardRequested),
                    "copied": .bool(clipboardCopied),
                ]),
            ])
        } catch {
            let data: [String: JSON] = [
                "display": resolved.json,
                "error": .string(error.localizedDescription),
            ]
            if ownsRun {
                _ = try? RunStore.shared.fail(
                    id: run.id,
                    summary: "Display screenshot failed",
                    data: data
                )
            } else {
                _ = try? RunStore.shared.appendTrace(
                    id: run.id,
                    kind: "capture.screenshotDisplay.failed",
                    summary: "Display screenshot failed",
                    data: data
                )
            }
            throw error
        }
    }

    func zoomArtifact(params: JSON?) throws -> JSON {
        let source = params?["source"]?.stringValue ?? "daemon"
        let resolved = try resolveArtifact(params: params, source: source, fallbackTitle: "Zoom artifact")
        let sourceImage = try loadCGImage(path: resolved.path)
        let crop = artifactCropRect(params: params, image: sourceImage)
        guard let cropped = sourceImage.cropping(to: crop) else {
            throw RouterError.custom("Unable to crop artifact image")
        }
        let scale = max(1, min(params?["scale"]?.numericDouble ?? params?["zoom"]?.numericDouble ?? 2, 8))
        let zoomed = try scaledImage(cropped, scale: scale)
        let data = try pngData(from: zoomed)
        let filename = sanitizedFilename(
            params?["filename"]?.stringValue
                ?? "zoom-artifact-\(Self.fileTimestamp()).png"
        )
        let outputURL = RunStore.shared.artifactURL(for: resolved.run, filename: filename)
        try data.write(to: outputURL, options: .atomic)

        let artifact = RunStore.shared.makeArtifact(
            run: resolved.run,
            kind: "zoom",
            url: outputURL,
            mimeType: "image/png",
            metadata: [
                "sourceArtifactId": resolved.artifact.map { .string($0.id) } ?? .null,
                "sourcePath": .string(resolved.path),
                "crop": regionJSON(crop),
                "scale": .double(scale),
                "width": .int(zoomed.width),
                "height": .int(zoomed.height),
                "byteSize": .int(data.count),
            ]
        )
        let updated = try RunStore.shared.appendArtifact(artifact)
        let traced = try RunStore.shared.appendTrace(
            id: updated.id,
            kind: "capture.zoomArtifact.created",
            summary: "Created zoomed artifact",
            data: [
                "artifactId": .string(artifact.id),
                "sourcePath": .string(resolved.path),
                "scale": .double(scale),
            ]
        )
        let responseRun = resolved.createdRun
            ? try RunStore.shared.complete(
                id: traced.id,
                summary: "Created zoomed artifact",
                data: [
                    "artifactId": .string(artifact.id),
                    "sourcePath": .string(resolved.path),
                ]
            )
            : traced

        return .object([
            "ok": .bool(true),
            "run": responseRun.json,
            "artifact": artifact.json,
            "sourceArtifact": resolved.artifact?.json ?? .null,
            "crop": regionJSON(crop),
            "scale": .double(scale),
        ])
    }

    func analyzeWindow(params: JSON?) throws -> JSON {
        let source = params?["source"]?.stringValue ?? "daemon"
        _ = try requiredInstruction(params)
        let window = try resolveWindow(params: params)
        let run = try RunStore.shared.createRun(
            title: "Analyze window \(window.app)",
            source: source,
            surfaces: [.window(window)]
        )
        _ = try RunStore.shared.markRunning(
            id: run.id,
            summary: "Capturing window for local vision analysis",
            data: ["wid": .int(Int(window.wid)), "app": .string(window.app)]
        )

        do {
            let captured = try screenshotWindow(params: mergeParams(params, [
                "runId": .string(run.id),
                "source": .string(source),
                "wid": .int(Int(window.wid)),
                "filename": .string("vision-window-\(window.wid)-\(Self.fileTimestamp()).png"),
            ]))
            guard let artifact = captured["artifact"] else {
                throw RouterError.custom("Window analysis did not produce an artifact")
            }
            return try analyzeArtifact(params: mergeParams(params, [
                "runId": .string(run.id),
                "artifactId": artifact["id"] ?? .null,
                "path": artifact["path"] ?? .null,
                "source": .string(source),
                "completeRun": .bool(true),
            ]))
        } catch {
            _ = try? RunStore.shared.fail(
                id: run.id,
                summary: "Window analysis failed",
                data: ["error": .string(error.localizedDescription)]
            )
            throw error
        }
    }

    func analyzeArtifact(params: JSON?) throws -> JSON {
        let source = params?["source"]?.stringValue ?? "daemon"
        let instruction = try requiredInstruction(params)
        let resolved = try resolveArtifact(params: params, source: source, fallbackTitle: "Analyze artifact")
        let shouldCompleteRun = resolved.createdRun || params?["completeRun"]?.boolValue == true

        do {
            let image = try loadCGImage(path: resolved.path)
            let blocks = ScreenText.recognize(in: image)
            let fullText = blocks.map(\.text).joined(separator: "\n")
            let answer = localVisionAnswer(instruction: instruction, fullText: fullText)
            let verified = localVisionMatch(params: params, fullText: fullText)

            let traced = try RunStore.shared.appendTrace(
                id: resolved.run.id,
                kind: "vision.analyzeArtifact.completed",
                summary: "Completed local artifact analysis",
                data: [
                    "provider": .string("local-ocr"),
                    "instruction": .string(instruction),
                    "sourcePath": .string(resolved.path),
                    "blockCount": .int(blocks.count),
                    "verified": verified.map { .bool($0) } ?? .null,
                ]
            )
            let responseRun = shouldCompleteRun
                ? try RunStore.shared.complete(
                    id: traced.id,
                    summary: "Completed local artifact analysis",
                    data: [
                        "provider": .string("local-ocr"),
                        "blockCount": .int(blocks.count),
                    ]
                )
                : traced

            var object: [String: JSON] = [
                "ok": .bool(true),
                "provider": .string("local-ocr"),
                "model": .string("vision-text-recognition"),
                "instruction": .string(instruction),
                "answer": .string(answer),
                "fullText": .string(fullText),
                "blocks": .array(blocks.map(ocrBlockJSON)),
                "run": responseRun.json,
                "sourcePath": .string(resolved.path),
            ]
            if let artifact = resolved.artifact {
                object["artifact"] = artifact.json
            }
            if let verified {
                object["verified"] = .bool(verified)
            }
            return .object(object)
        } catch {
            if shouldCompleteRun {
                _ = try? RunStore.shared.fail(
                    id: resolved.run.id,
                    summary: "Local artifact analysis failed",
                    data: ["error": .string(error.localizedDescription)]
                )
            }
            throw error
        }
    }

    func verifyVisual(params: JSON?) throws -> JSON {
        let mode = params?["mode"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            ?? params?["type"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            ?? "ocr"

        if mode == "artifactchanged" || mode == "artifact-changed" || mode == "changed" {
            return try verifyArtifactChanged(params: params)
        }

        guard let expectation = verificationExpectation(params: params) else {
            throw RouterError.missingParam("contains, expected, or notContains")
        }

        let analysis: JSON
        if hasArtifactTarget(params) {
            analysis = try analyzeArtifact(params: mergeParams(params, [
                "instruction": params?["instruction"] ?? .string("Verify OCR text expectation"),
            ]))
        } else {
            analysis = try analyzeWindow(params: mergeParams(params, [
                "instruction": params?["instruction"] ?? .string("Verify OCR text expectation"),
            ]))
        }
        let fullText = analysis["fullText"]?.stringValue ?? ""
        let verified = evaluateExpectation(expectation, fullText: fullText)

        return .object([
            "ok": .bool(true),
            "verified": .bool(verified),
            "mode": .string("ocr"),
            "expectation": expectation.json,
            "analysis": analysis,
            "fullText": .string(fullText),
        ])
    }

    func resolveWindow(params: JSON?) throws -> WindowEntry {
        DesktopModel.shared.forcePoll()

        if let wid = params?["wid"]?.uint32Value {
            guard let window = DesktopModel.captureWindows().first(where: { $0.wid == wid })
                ?? DesktopModel.shared.windows[wid] else {
                throw RouterError.custom("Window \(wid) is not in the current WindowServer inventory (closed, stale ID, or unavailable). Run: lats windows --include-panels --json; then lats capture window <wid>. For visible content use lats capture region --x X --y Y --width W --height H (includes other apps).")
            }
            return window
        }

        if let session = params?["session"]?.stringValue, !session.isEmpty {
            guard let window = DesktopModel.shared.windowForSession(session) else {
                throw RouterError.notFound("window for session \(session)")
            }
            return window
        }

        if let app = params?["app"]?.stringValue, !app.isEmpty {
            return try Self.windowForCapture(app: app, title: params?["title"]?.stringValue,
                                             candidates: DesktopModel.captureWindows())
        }

        if let window = DesktopModel.shared.allWindows().first(where: { candidate in
            candidate.isOnScreen &&
                candidate.app != "Lattices" &&
                !candidate.app.localizedCaseInsensitiveContains("lattices")
        }) {
            return window
        }

        guard let frontmost = DesktopModel.shared.frontmostWindow() else {
            throw RouterError.notFound("frontmost window")
        }
        return frontmost
    }

    static func windowForCapture(app: String, title: String?, candidates: [WindowEntry]) throws -> WindowEntry {
        let matches = candidates.filter { candidate in
            candidate.app.localizedCaseInsensitiveContains(app) &&
            (title.map { title in candidate.title.localizedCaseInsensitiveContains(title) } ?? true)
        }
        if matches.count > 1 {
            let choices = matches.map { "wid:\($0.wid) \($0.app) \($0.title.isEmpty ? "(untitled)" : $0.title) [\($0.frame.x),\($0.frame.y) \($0.frame.w)x\($0.frame.h)]" }.joined(separator: "; ")
            throw RouterError.custom("Multiple windows match \(app): \(choices). Choose explicitly: lats capture window <wid>.")
        }
        guard let window = matches.first else {
            throw RouterError.custom("No on-screen window matches app \(app). Run: lats windows --include-panels --json; select an explicit wid, or use lats capture region --x X --y Y --width W --height H for visible content.")
        }
        return window
    }

    func resolveRun(params: JSON?, title: String, source: String, surfaces: [RunSurface]) throws -> RunSession {
        if let runId = params?["runId"]?.stringValue, !runId.isEmpty {
            guard let run = RunStore.shared.get(id: runId) else {
                throw RouterError.notFound("run \(runId)")
            }
            return run
        }
        return try RunStore.shared.createRun(title: title, source: source, surfaces: surfaces)
    }

    struct RegionResolution {
        let rect: CGRect
        let target: WindowEntry?
        let surfaces: [RunSurface]
    }

    struct DisplayResolution {
        let index: Int
        let displayID: CGDirectDisplayID
        let name: String
        let frame: CGRect

        var surface: RunSurface {
            RunSurface(
                id: "display-\(displayID)",
                kind: "display",
                wid: nil,
                app: nil,
                title: name,
                frame: RunFrame(WindowFrame(
                    x: Double(frame.origin.x),
                    y: Double(frame.origin.y),
                    w: Double(frame.width),
                    h: Double(frame.height)
                )),
                latticesSession: nil,
                x: nil,
                y: nil
            )
        }

        var json: JSON {
            .object([
                "displayIndex": .int(index),
                "displayID": .int(Int(displayID)),
                "name": .string(name),
                "frame": .object([
                    "x": .double(Double(frame.origin.x)),
                    "y": .double(Double(frame.origin.y)),
                    "w": .double(Double(frame.width)),
                    "h": .double(Double(frame.height)),
                ]),
            ])
        }
    }

    private struct ArtifactResolution {
        let run: RunSession
        let artifact: RunArtifact?
        let path: String
        let createdRun: Bool
    }

    private struct VerificationExpectation {
        let kind: String
        let value: String

        var json: JSON {
            .object([
                "kind": .string(kind),
                "value": .string(value),
            ])
        }
    }

    /// One compressed frame for a remote viewer: a display, a window or a
    /// region, returned inline with the rect it covers in layout coordinates.
    func still(params: JSON?) throws -> JSON {
        let maxWidth = max(160, min(3840, params?["maxWidth"]?.intValue ?? 1600))
        let quality = max(20, min(95, params?["quality"]?.intValue ?? 70))
        let image: CGImage
        let frame: CGRect
        var display: JSON = .null
        if params?["width"] != nil || params?["w"] != nil {
            let region = try resolveRegion(params: params)
            frame = region.rect
            image = try captureRegionImage(rect: region.rect, timeoutSeconds: 5)
        } else if let wid = params?["wid"]?.intValue {
            let target = try resolveWindow(params: params)
            frame = CGRect(x: target.frame.x, y: target.frame.y, width: target.frame.w, height: target.frame.h)
            image = try captureWindowImage(wid: UInt32(wid), timeoutSeconds: 5)
        } else {
            let resolved = try resolveDisplay(params: params)
            frame = resolved.frame
            display = .object(["index": .int(resolved.index), "name": .string(resolved.name)])
            image = try captureDisplayImage(displayID: resolved.displayID, showsCursor: true, timeoutSeconds: 5)
        }
        let scaled = image.width > maxWidth ? try smoothScaled(image, width: maxWidth) : image
        let rep = NSBitmapImageRep(cgImage: scaled)
        guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: Double(quality) / 100]) else {
            throw RouterError.custom("Unable to encode frame")
        }
        return .object([
            "format": .string("jpeg"),
            "width": .int(scaled.width),
            "height": .int(scaled.height),
            "data": .string(data.base64EncodedString()),
            "frame": .object(["x": .double(frame.minX), "y": .double(frame.minY), "w": .double(frame.width), "h": .double(frame.height)]),
            "display": display,
        ])
    }

    private func smoothScaled(_ image: CGImage, width: Int) throws -> CGImage {
        let height = max(1, Int((Double(image.height) * Double(width) / Double(image.width)).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw RouterError.custom("Unable to create frame context")
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage() else { throw RouterError.custom("Unable to render frame") }
        return scaled
    }

    private func captureWindowImage(wid: UInt32, timeoutSeconds: Int) throws -> CGImage {
        guard CGPreflightScreenCaptureAccess() else {
            throw RouterError.custom("Screen Recording permission is not granted to this Lattices process. Enable it in System Settings > Privacy & Security > Screen Recording, then retry.")
        }
        let semaphore = DispatchSemaphore(value: 0)
        let box = CaptureBox()

        Task.detached(priority: .userInitiated) {
            let captured = await WindowCapture.image(
                listOption: .optionIncludingWindow,
                windowID: CGWindowID(wid),
                imageOption: [.boundsIgnoreFraming, .bestResolution]
            )
            box.set(captured)
            semaphore.signal()
        }

        if semaphore.wait(timeout: .now() + .seconds(timeoutSeconds)) == .timedOut {
            throw RouterError.custom("Timed out capturing window \(wid)")
        }
        guard let captured = box.value() else {
            throw RouterError.custom("Unable to capture window \(wid). Check Screen Recording permission.")
        }
        return captured
    }

    private func captureRegionImage(rect: CGRect, timeoutSeconds: Int) throws -> CGImage {
        let semaphore = DispatchSemaphore(value: 0)
        let box = CaptureBox()

        Task.detached(priority: .userInitiated) {
            let captured = await WindowCapture.region(rect: rect, imageOption: [.bestResolution])
            box.set(captured)
            semaphore.signal()
        }

        if semaphore.wait(timeout: .now() + .seconds(timeoutSeconds)) == .timedOut {
            throw RouterError.custom("Timed out capturing region \(Int(rect.origin.x)),\(Int(rect.origin.y)),\(Int(rect.width))x\(Int(rect.height))")
        }
        guard let captured = box.value() else {
            throw RouterError.custom("Unable to capture screen region. Check Screen Recording permission.")
        }
        return captured
    }

    private func captureDisplayImage(
        displayID: CGDirectDisplayID,
        showsCursor: Bool,
        timeoutSeconds: Int
    ) throws -> CGImage {
        let semaphore = DispatchSemaphore(value: 0)
        let box = CaptureBox()

        Task.detached(priority: .userInitiated) {
            let captured = await WindowCapture.display(
                displayID: displayID,
                showsCursor: showsCursor,
                imageOption: [.bestResolution]
            )
            box.set(captured)
            semaphore.signal()
        }

        if semaphore.wait(timeout: .now() + .seconds(timeoutSeconds)) == .timedOut {
            throw RouterError.custom("Timed out capturing display \(displayID)")
        }
        guard let captured = box.value() else {
            throw RouterError.custom("Unable to capture display \(displayID). Check Screen Recording permission.")
        }
        return captured
    }

    private func pngData(from cgImage: CGImage) throws -> Data {
        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw RouterError.custom("Unable to encode screenshot as PNG")
        }
        return data
    }

    private func copyPNGToClipboard(_ data: Data) -> Bool {
        onMainThread {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            return pasteboard.setData(data, forType: .png)
        }
    }

    func resolveRegion(params: JSON?) throws -> RegionResolution {
        let x = params?["x"]?.numericDouble
        let y = params?["y"]?.numericDouble
        let width = params?["width"]?.numericDouble ?? params?["w"]?.numericDouble
        let height = params?["height"]?.numericDouble ?? params?["h"]?.numericDouble

        if let x, let y, let width, let height {
            let rect = normalizedRect(CGRect(x: x, y: y, width: width, height: height))
            return RegionResolution(
                rect: rect,
                target: nil,
                surfaces: [
                    RunSurface(
                        id: "region-\(Int(rect.origin.x))-\(Int(rect.origin.y))-\(Int(rect.width))-\(Int(rect.height))",
                        kind: "region",
                        wid: nil,
                        app: nil,
                        title: "Screen region",
                        frame: RunFrame(WindowFrame(
                            x: Double(rect.origin.x),
                            y: Double(rect.origin.y),
                            w: Double(rect.width),
                            h: Double(rect.height)
                        )),
                        latticesSession: nil,
                        x: nil,
                        y: nil
                    )
                ]
            )
        }

        let target = try resolveWindow(params: params)
        let rect = normalizedRect(CGRect(
            x: target.frame.x,
            y: target.frame.y,
            width: target.frame.w,
            height: target.frame.h
        ))
        return RegionResolution(rect: rect, target: target, surfaces: [.window(target)])
    }

    func resolveDisplay(params: JSON?) throws -> DisplayResolution {
        try onMainThread {
            let screens = NSScreen.screens
            guard !screens.isEmpty else {
                throw RouterError.notFound("display")
            }

            let requestedIndex = params?["displayIndex"]?.intValue
                ?? params?["display"]?.intValue
            let screen: NSScreen
            if let requestedIndex {
                guard requestedIndex >= 0,
                      let requestedScreen = DisplayGeometryMapper.screen(forDisplayIndex: requestedIndex) else {
                    throw RouterError.notFound("display \(requestedIndex)")
                }
                screen = requestedScreen
            } else {
                let pointer = NSEvent.mouseLocation
                guard let pointerScreen = screens.first(where: { $0.frame.contains(pointer) })
                        ?? NSScreen.main
                        ?? screens.first else {
                    throw RouterError.notFound("current display")
                }
                screen = pointerScreen
            }

            let key = NSDeviceDescriptionKey("NSScreenNumber")
            guard let number = screen.deviceDescription[key] as? NSNumber else {
                throw RouterError.custom("Unable to resolve the CoreGraphics id for \(screen.localizedName)")
            }
            let displayID = CGDirectDisplayID(number.uint32Value)
            let displayIndex = requestedIndex
                ?? apiDisplayIndex(for: screen, displayID: displayID, screens: screens)
            let frame = CGDisplayBounds(displayID)
            guard !frame.isNull, !frame.isInfinite, !frame.isEmpty else {
                throw RouterError.custom("Display \(displayID) has no capturable frame")
            }

            return DisplayResolution(
                index: displayIndex,
                displayID: displayID,
                name: screen.localizedName,
                frame: frame
            )
        }
    }

    private func apiDisplayIndex(
        for screen: NSScreen,
        displayID: CGDirectDisplayID,
        screens: [NSScreen]
    ) -> Int {
        for display in WindowTiler.getDisplaySpaces() {
            guard let mappedScreen = DisplayGeometryMapper.screen(for: display, in: screens),
                  let number = mappedScreen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                continue
            }
            if CGDirectDisplayID(number.uint32Value) == displayID {
                return display.displayIndex
            }
        }
        return screens.firstIndex(where: { $0 === screen }) ?? 0
    }

    private func onMainThread<T>(_ body: () throws -> T) rethrows -> T {
        if Thread.isMainThread {
            return try body()
        }
        return try DispatchQueue.main.sync(execute: body)
    }

    private func normalizedRect(_ rect: CGRect) -> CGRect {
        CGRect(
            x: rect.width >= 0 ? rect.origin.x : rect.origin.x + rect.width,
            y: rect.height >= 0 ? rect.origin.y : rect.origin.y + rect.height,
            width: abs(rect.width),
            height: abs(rect.height)
        )
    }

    private func regionJSON(_ rect: CGRect) -> JSON {
        .object([
            "x": .double(Double(rect.origin.x)),
            "y": .double(Double(rect.origin.y)),
            "w": .double(Double(rect.width)),
            "h": .double(Double(rect.height)),
        ])
    }

    private func resolveArtifact(
        params: JSON?,
        source: String,
        fallbackTitle: String
    ) throws -> ArtifactResolution {
        let runId = params?["runId"]?.stringValue ?? params?["id"]?.stringValue
        let artifactId = params?["artifactId"]?.stringValue
            ?? params?["artifact-id"]?.stringValue
            ?? params?["artifact"]?.stringValue
        let explicitPath = params?["path"]?.stringValue
            ?? params?["artifactPath"]?.stringValue
            ?? params?["artifact-path"]?.stringValue

        if let runId, !runId.isEmpty {
            guard let run = RunStore.shared.get(id: runId) else {
                throw RouterError.notFound("run \(runId)")
            }
            let artifact = try artifactId.flatMap { id -> RunArtifact? in
                guard !id.isEmpty else { return nil }
                guard let artifact = run.artifacts.first(where: { $0.id == id }) else {
                    throw RouterError.notFound("artifact \(id) in run \(runId)")
                }
                return artifact
            } ?? imageArtifact(in: run)
            let path = explicitPath ?? artifact?.path
            guard let path, !path.isEmpty else {
                throw RouterError.missingParam("path or artifactId")
            }
            return ArtifactResolution(run: run, artifact: artifact, path: path, createdRun: false)
        }

        if let artifactId, !artifactId.isEmpty {
            for run in RunStore.shared.list(limit: 500) {
                if let artifact = run.artifacts.first(where: { $0.id == artifactId }) {
                    return ArtifactResolution(run: run, artifact: artifact, path: artifact.path, createdRun: false)
                }
            }
            throw RouterError.notFound("artifact \(artifactId)")
        }

        if let explicitPath, !explicitPath.isEmpty {
            let run = try RunStore.shared.createRun(title: fallbackTitle, source: source, surfaces: [])
            return ArtifactResolution(run: run, artifact: nil, path: explicitPath, createdRun: true)
        }

        throw RouterError.missingParam("runId, artifactId, or path")
    }

    private func imageArtifact(in run: RunSession) -> RunArtifact? {
        run.artifacts.last(where: { artifact in
            artifact.mimeType == "image/png" || artifact.kind.contains("screenshot") || artifact.kind == "zoom"
        })
    }

    private func artifactCropRect(params: JSON?, image: CGImage) -> CGRect {
        let imageRect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let ratioX = params?["xRatio"]?.numericDouble
        let ratioY = params?["yRatio"]?.numericDouble
        let ratioW = params?["widthRatio"]?.numericDouble ?? params?["wRatio"]?.numericDouble
        let ratioH = params?["heightRatio"]?.numericDouble ?? params?["hRatio"]?.numericDouble
        if ratioX != nil || ratioY != nil || ratioW != nil || ratioH != nil {
            let x = max(0, min(1, ratioX ?? 0)) * Double(image.width)
            let y = max(0, min(1, ratioY ?? 0)) * Double(image.height)
            let w = max(0.01, min(1, ratioW ?? 1)) * Double(image.width)
            let h = max(0.01, min(1, ratioH ?? 1)) * Double(image.height)
            return normalizedRect(CGRect(x: x, y: y, width: w, height: h)).intersection(imageRect)
        }

        let x = params?["x"]?.numericDouble ?? 0
        let y = params?["y"]?.numericDouble ?? 0
        let width = params?["width"]?.numericDouble ?? params?["w"]?.numericDouble ?? Double(image.width)
        let height = params?["height"]?.numericDouble ?? params?["h"]?.numericDouble ?? Double(image.height)
        let crop = normalizedRect(CGRect(x: x, y: y, width: width, height: height)).intersection(imageRect)
        return crop.isNull || crop.isEmpty ? imageRect : crop.integral
    }

    private func loadCGImage(path: String) throws -> CGImage {
        let url = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: url)
        guard let rep = NSBitmapImageRep(data: data), let image = rep.cgImage else {
            throw RouterError.custom("Unable to decode image artifact at \(path)")
        }
        return image
    }

    private func scaledImage(_ image: CGImage, scale: Double) throws -> CGImage {
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw RouterError.custom("Unable to create zoom image context")
        }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage() else {
            throw RouterError.custom("Unable to render zoom image")
        }
        return scaled
    }

    private func ocrBlockJSON(_ block: OcrTextBlock) -> JSON {
        .object([
            "text": .string(block.text),
            "confidence": .double(Double(block.confidence)),
            "x": .double(Double(block.boundingBox.origin.x)),
            "y": .double(Double(block.boundingBox.origin.y)),
            "w": .double(Double(block.boundingBox.width)),
            "h": .double(Double(block.boundingBox.height)),
        ])
    }

    private func requiredInstruction(_ params: JSON?) throws -> String {
        let instruction = params?["instruction"]?.stringValue
            ?? params?["prompt"]?.stringValue
            ?? params?["question"]?.stringValue
            ?? params?["query"]?.stringValue
        guard let instruction = instruction?.trimmingCharacters(in: .whitespacesAndNewlines),
              !instruction.isEmpty else {
            throw RouterError.missingParam("instruction")
        }
        return instruction
    }

    private func localVisionAnswer(instruction: String, fullText: String) -> String {
        let trimmed = fullText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "No readable text was detected by local OCR for instruction: \(instruction)"
        }
        return "Local OCR detected \(trimmed.count) characters. Use fullText/blocks for exact evidence."
    }

    private func localVisionMatch(params: JSON?, fullText: String) -> Bool? {
        verificationExpectation(params: params).map { evaluateExpectation($0, fullText: fullText) }
    }

    private func verificationExpectation(params: JSON?) -> VerificationExpectation? {
        if let value = params?["contains"]?.stringValue
            ?? params?["expected"]?.stringValue
            ?? params?["text"]?.stringValue {
            return VerificationExpectation(kind: "contains", value: value)
        }
        if let value = params?["notContains"]?.stringValue
            ?? params?["not-contains"]?.stringValue
            ?? params?["absent"]?.stringValue {
            return VerificationExpectation(kind: "notContains", value: value)
        }
        return nil
    }

    private func evaluateExpectation(_ expectation: VerificationExpectation, fullText: String) -> Bool {
        let haystack = fullText.lowercased()
        let needle = expectation.value.lowercased()
        switch expectation.kind {
        case "notContains":
            return !haystack.contains(needle)
        default:
            return haystack.contains(needle)
        }
    }

    private func verifyArtifactChanged(params: JSON?) throws -> JSON {
        let beforePath = try artifactPath(
            params: params,
            pathKeys: ["beforePath", "before-path"],
            artifactKeys: ["beforeArtifactId", "before-artifact-id"]
        )
        let afterPath = try artifactPath(
            params: params,
            pathKeys: ["afterPath", "after-path"],
            artifactKeys: ["afterArtifactId", "after-artifact-id"]
        )
        let beforeHash = try sha256Hex(Data(contentsOf: URL(fileURLWithPath: beforePath)))
        let afterHash = try sha256Hex(Data(contentsOf: URL(fileURLWithPath: afterPath)))
        let changed = beforeHash != afterHash
        return .object([
            "ok": .bool(true),
            "verified": .bool(changed),
            "mode": .string("artifactChanged"),
            "beforePath": .string(beforePath),
            "afterPath": .string(afterPath),
            "beforeSha256": .string(beforeHash),
            "afterSha256": .string(afterHash),
        ])
    }

    private func artifactPath(
        params: JSON?,
        pathKeys: [String],
        artifactKeys: [String]
    ) throws -> String {
        for key in pathKeys {
            if let value = params?[key]?.stringValue, !value.isEmpty {
                return value
            }
        }
        for key in artifactKeys {
            if let artifactId = params?[key]?.stringValue, !artifactId.isEmpty {
                for run in RunStore.shared.list(limit: 500) {
                    if let artifact = run.artifacts.first(where: { $0.id == artifactId }) {
                        return artifact.path
                    }
                }
                throw RouterError.notFound("artifact \(artifactId)")
            }
        }
        throw RouterError.missingParam(pathKeys.first ?? "path")
    }

    private func sha256Hex(_ data: Data) -> String {
        Data(SHA256.hash(data: data)).map { String(format: "%02x", $0) }.joined()
    }

    private func hasArtifactTarget(_ params: JSON?) -> Bool {
        params?["runId"]?.stringValue != nil
            || params?["artifactId"]?.stringValue != nil
            || params?["artifact-id"]?.stringValue != nil
            || params?["path"]?.stringValue != nil
    }

    private func mergeParams(_ params: JSON?, _ overrides: [String: JSON]) -> JSON {
        var object: [String: JSON] = [:]
        if case .object(let existing) = params {
            object = existing
        }
        for (key, value) in overrides where value != .null {
            object[key] = value
        }
        return .object(object)
    }

    private func sanitizedFilename(_ raw: String) -> String {
        let fallback = "screenshot-window-\(Self.fileTimestamp()).png"
        let name = raw.isEmpty ? fallback : raw
        let safe = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return safe.lowercased().hasSuffix(".png") ? safe : "\(safe).png"
    }

    private static func fileTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}
