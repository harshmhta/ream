import CoreGraphics
import Foundation

/// Smooths raw pointer samples into a cleaner freehand stroke. Two algorithms
/// are offered; Ream defaults to Catmull-Rom because it interpolates through
/// the original points (the stroke passes where the user drew) while rounding
/// the corners.
enum InkSmoothing {

    enum Algorithm {
        case catmullRom
        case chaikin
    }

    /// Smooth a single stroke. Strokes shorter than 3 points are returned as-is.
    static func smooth(_ points: [CGPoint],
                       algorithm: Algorithm = .catmullRom,
                       iterations: Int = 2) -> [CGPoint] {
        guard points.count >= 3 else { return points }
        let deduped = dedupe(points)
        guard deduped.count >= 3 else { return deduped }
        switch algorithm {
        case .catmullRom: return catmullRom(deduped, samplesPerSegment: 6)
        case .chaikin:    return chaikin(deduped, iterations: iterations)
        }
    }

    /// Drop consecutive samples closer than `minDistance` to reduce jitter and
    /// keep the point count sane on high-frequency trackpads/styluses.
    static func dedupe(_ points: [CGPoint], minDistance: CGFloat = 1.5) -> [CGPoint] {
        guard let first = points.first else { return [] }
        var result = [first]
        for p in points.dropFirst() {
            if let last = result.last, hypot(p.x - last.x, p.y - last.y) >= minDistance {
                result.append(p)
            }
        }
        // Always retain the final point so the stroke ends where the user lifted.
        if let last = points.last, result.last != last { result.append(last) }
        return result
    }

    /// Centripetal-ish Catmull-Rom spline sampled into a polyline.
    static func catmullRom(_ points: [CGPoint], samplesPerSegment: Int) -> [CGPoint] {
        guard points.count >= 3 else { return points }
        var result: [CGPoint] = [points[0]]
        let n = points.count
        for i in 0..<(n - 1) {
            let p0 = points[max(i - 1, 0)]
            let p1 = points[i]
            let p2 = points[i + 1]
            let p3 = points[min(i + 2, n - 1)]
            for s in 1...samplesPerSegment {
                let t = CGFloat(s) / CGFloat(samplesPerSegment)
                result.append(catmullPoint(p0, p1, p2, p3, t))
            }
        }
        return result
    }

    private static func catmullPoint(_ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint, _ t: CGFloat) -> CGPoint {
        let t2 = t * t
        let t3 = t2 * t
        func axis(_ a: CGFloat, _ b: CGFloat, _ c: CGFloat, _ d: CGFloat) -> CGFloat {
            0.5 * ((2 * b) + (-a + c) * t + (2 * a - 5 * b + 4 * c - d) * t2 + (-a + 3 * b - 3 * c + d) * t3)
        }
        return CGPoint(x: axis(p0.x, p1.x, p2.x, p3.x), y: axis(p0.y, p1.y, p2.y, p3.y))
    }

    /// Chaikin corner-cutting subdivision (keeps endpoints fixed).
    static func chaikin(_ points: [CGPoint], iterations: Int) -> [CGPoint] {
        guard points.count >= 3, iterations > 0 else { return points }
        var current = points
        for _ in 0..<iterations {
            var next: [CGPoint] = [current.first!]
            for i in 0..<(current.count - 1) {
                let p = current[i], q = current[i + 1]
                let quarter = CGPoint(x: 0.75 * p.x + 0.25 * q.x, y: 0.75 * p.y + 0.25 * q.y)
                let threeQuarter = CGPoint(x: 0.25 * p.x + 0.75 * q.x, y: 0.25 * p.y + 0.75 * q.y)
                next.append(quarter); next.append(threeQuarter)
            }
            next.append(current.last!)
            current = next
        }
        return current
    }
}
