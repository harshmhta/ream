import CoreGraphics
import Foundation

/// Small geometry helpers shared by the custom annotations, ink smoothing, and
/// the XFDF codec. Kept free of PDFKit so it stays unit-testable in isolation.
enum ReamGeometry {
    /// Pack points into a compact comma-separated string: "x0,y0,x1,y1,…".
    /// Used to persist vertex/quad geometry in a custom annotation key.
    static func packPoints(_ points: [CGPoint]) -> String {
        points.flatMap { [Self.fmt($0.x), Self.fmt($0.y)] }.joined(separator: ",")
    }

    /// Inverse of ``packPoints(_:)``. Tolerant of empty/nil and odd counts.
    static func unpackPoints(_ string: String?) -> [CGPoint] {
        guard let string, !string.isEmpty else { return [] }
        let nums = string.split(separator: ",").compactMap { Double($0) }
        var points: [CGPoint] = []
        var i = 0
        while i + 1 < nums.count {
            points.append(CGPoint(x: nums[i], y: nums[i + 1]))
            i += 2
        }
        return points
    }

    /// Format a coordinate with a stable, compact representation (max 3 dp, no
    /// trailing zeros) so packed strings are deterministic across runs.
    static func fmt(_ value: CGFloat) -> String {
        let rounded = (value * 1000).rounded() / 1000
        if rounded == rounded.rounded() {
            return String(Int(rounded))
        }
        return String(format: "%g", rounded)
    }

    /// Axis-aligned bounding box of a point set, optionally padded.
    static func boundingBox(of points: [CGPoint], padding: CGFloat = 0) -> CGRect {
        guard let first = points.first else { return .zero }
        var minX = first.x, minY = first.y, maxX = first.x, maxY = first.y
        for p in points.dropFirst() {
            minX = Swift.min(minX, p.x); minY = Swift.min(minY, p.y)
            maxX = Swift.max(maxX, p.x); maxY = Swift.max(maxY, p.y)
        }
        return CGRect(x: minX - padding, y: minY - padding,
                      width: (maxX - minX) + padding * 2,
                      height: (maxY - minY) + padding * 2)
    }

    /// Distance from point `p` to segment `a`–`b` (used by the eraser).
    static func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        if lengthSquared == 0 { return hypot(p.x - a.x, p.y - a.y) }
        var t = ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared
        t = Swift.max(0, Swift.min(1, t))
        let proj = CGPoint(x: a.x + t * dx, y: a.y + t * dy)
        return hypot(p.x - proj.x, p.y - proj.y)
    }
}
