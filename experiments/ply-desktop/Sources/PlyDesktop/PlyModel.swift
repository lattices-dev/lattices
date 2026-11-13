import AppKit
import ImageIO

enum PlyPose: Int, CaseIterable {
    case rest, noticed, browsing, arranging, focused, thinking, question, happy

    var title: String {
        switch self {
        case .rest: "At rest"
        case .noticed: "Noticed you"
        case .browsing: "Browsing"
        case .arranging: "Arranging"
        case .focused: "Gentle focus"
        case .thinking: "Thinking"
        case .question: "A question"
        case .happy: "That worked"
        }
    }
}

struct PlyDrag {
    let pointer: CGPoint
    let origin: CGPoint
    private(set) var moved = false

    mutating func update(_ point: CGPoint) -> CGPoint? {
        let dx = point.x - pointer.x, dy = point.y - pointer.y
        moved = moved || hypot(dx, dy) >= 4
        return moved ? CGPoint(x: origin.x + dx, y: origin.y + dy) : nil
    }
}

enum PlyPlacement {
    static func clamped(_ frame: CGRect, to screens: [CGRect]) -> CGRect {
        guard !screens.isEmpty else { return frame }
        let center = CGPoint(x: frame.midX, y: frame.midY)
        let screen = screens.min { a, b in
            distance(center, to: a) < distance(center, to: b)
        }!
        let width = min(frame.width, screen.width), height = min(frame.height, screen.height)
        return CGRect(x: min(max(frame.minX, screen.minX), screen.maxX - width),
                      y: min(max(frame.minY, screen.minY), screen.maxY - height),
                      width: width, height: height)
    }

    private static func distance(_ point: CGPoint, to rect: CGRect) -> CGFloat {
        let x = min(max(point.x, rect.minX), rect.maxX)
        let y = min(max(point.y, rect.minY), rect.maxY)
        return hypot(point.x - x, point.y - y)
    }
}

final class PlyAtlas {
    let frames: [CGImage]
    private let bitmaps: [NSBitmapImageRep]

    init() throws {
        let url = Bundle.main.url(forResource: "ply-desktop-v1", withExtension: "png")
            ?? Bundle.module.url(forResource: "ply-desktop-v1", withExtension: "png")!
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        frames = try PlyPose.allCases.map { pose in
            let column = pose.rawValue % 4, row = pose.rawValue / 4
            let x = image.width * column / 4, y = image.height * row / 2
            let right = image.width * (column + 1) / 4, bottom = image.height * (row + 1) / 2
            guard let frame = image.cropping(to: CGRect(x: x, y: y, width: right - x, height: bottom - y)) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return frame
        }
        bitmaps = frames.map(NSBitmapImageRep.init(cgImage:))
    }

    func alpha(at point: CGPoint, pose: PlyPose) -> CGFloat {
        guard point.x >= 0, point.x < 1, point.y >= 0, point.y < 1 else { return 0 }
        let bitmap = bitmaps[pose.rawValue]
        return bitmap.colorAt(x: Int(point.x * CGFloat(bitmap.pixelsWide)),
                              y: bitmap.pixelsHigh - 1 - Int(point.y * CGFloat(bitmap.pixelsHigh)))?.alphaComponent ?? 0
    }

    func image(_ pose: PlyPose, size: CGFloat) -> NSImage {
        NSImage(cgImage: frames[pose.rawValue], size: NSSize(width: size, height: size))
    }
}
