import Foundation

/// A retained zoom route. Selection and hover belong to the view; only an
/// intentional destination change retargets this route. Both taps and held
/// zoom evaluate it at a scale, so reversing does not invent a new path.
struct SpaceCanvasNavigation: Equatable {
    private(set) var overview: SpaceCanvasCamera
    private(set) var focused: SpaceCanvasCamera

    init(overview: SpaceCanvasCamera, focused: SpaceCanvasCamera) {
        self.overview = overview
        self.focused = focused
    }

    func camera(atScale scale: CGFloat) -> SpaceCanvasCamera {
        if scale <= overview.scale { return overview }
        if scale >= focused.scale { return focused }
        return Self.camera(atScale: scale, from: overview, to: focused)
    }

    /// Clicking a desktop or choosing one with the keyboard changes the
    /// destination without discarding the retained overview/pan position.
    mutating func retarget(focused: SpaceCanvasCamera) {
        self.focused = focused
    }

    /// Retain a manually panned or pointer-anchored camera on the route,
    /// while preserving both scale limits. Keep the farther endpoint and
    /// derive the nearer one: extrapolating through two almost identical
    /// scales would otherwise amplify a small pan into a huge displacement.
    mutating func rebase(at camera: SpaceCanvasCamera) {
        guard focused.scale > overview.scale else {
            overview = camera
            focused = camera
            return
        }
        var anchor = camera
        anchor.scale = min(max(camera.scale, overview.scale), focused.scale)
        let fromOverview = log(anchor.scale / overview.scale)
        let fromFocus = log(focused.scale / anchor.scale)
        if fromOverview <= fromFocus {
            overview = Self.camera(atScale: overview.scale, from: anchor, to: focused)
        } else {
            focused = Self.camera(atScale: focused.scale, from: overview, to: anchor)
        }
    }

    /// Center times scale is affine in scale along the existing camera
    /// glide. This form also supports rebasing by extrapolation, without
    /// repeatedly integrating rounded frame-to-frame camera positions.
    private static func camera(atScale scale: CGFloat, from a: SpaceCanvasCamera,
                               to b: SpaceCanvasCamera) -> SpaceCanvasCamera {
        if scale == a.scale { return a }
        if scale == b.scale { return b }
        let t = (scale - a.scale) / (b.scale - a.scale)
        return SpaceCanvasCamera(center: CGPoint(
            x: (a.center.x * a.scale * (1 - t) + b.center.x * b.scale * t) / scale,
            y: (a.center.y * a.scale * (1 - t) + b.center.y * b.scale * t) / scale),
            scale: scale)
    }
}
