import Foundation
import CoreGraphics

/// The $1 Unistroke Recognizer — Wobbrock, Wilson & Li, UIST 2007, published
/// under a New BSD licence. Ported here rather than hand-tuned thresholds,
/// which could not tell a hand-drawn rectangle from a blob.
///
/// It answers *what* was drawn. Where and how big is left to the caller, which
/// fits the ideal shape to the actual points afterwards.
enum Unistroke: String {
    case line, circle, rectangle, triangle
}

struct DollarRecognizer {

    /// The score at which a stroke is confident enough to be replaced by an
    /// ideal shape. Owned here rather than at the call site so that the
    /// recogniser, the app and Tools/rectest.swift can never drift apart.
    static let snapThreshold: CGFloat = 0.88

    private static let sampleCount = 64
    private static let squareSize: CGFloat = 250
    private static let halfDiagonal: CGFloat = 0.5 * (squareSize * squareSize * 2).squareRoot()
    private static let angleRange: CGFloat = .pi / 4          // ±45°
    private static let anglePrecision: CGFloat = .pi / 90     // 2°
    private static let phi: CGFloat = 0.5 * (5.0.squareRoot() - 1)

    private struct Template {
        let kind: Unistroke
        let points: [CGPoint]
    }

    private let templates: [Template]

    init() {
        var built: [Template] = []

        // $1 is sensitive to where a stroke starts, so each closed shape is
        // registered from several starting corners and in both directions.
        func addClosed(_ kind: Unistroke, _ outline: [CGPoint]) {
            for offset in stride(from: 0, to: outline.count, by: max(outline.count / 4, 1)) {
                let rotated = Array(outline[offset...] + outline[..<offset])
                built.append(Template(kind: kind, points: Self.normalise(rotated)))
                built.append(Template(kind: kind, points: Self.normalise(rotated.reversed())))
            }
        }

        let steps = 96
        let circle = (0..<steps).map { i -> CGPoint in
            let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
            return CGPoint(x: cos(t) * 100, y: sin(t) * 100)
        }
        addClosed(.circle, circle)

        func perimeter(_ corners: [CGPoint]) -> [CGPoint] {
            var out: [CGPoint] = []
            for i in 0..<corners.count {
                let a = corners[i], b = corners[(i + 1) % corners.count]
                for step in 0..<24 {
                    let t = CGFloat(step) / 24
                    out.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
                }
            }
            return out
        }
        addClosed(.rectangle, perimeter([CGPoint(x: -100, y: -70), CGPoint(x: 100, y: -70),
                                         CGPoint(x: 100, y: 70), CGPoint(x: -100, y: 70)]))
        addClosed(.triangle, perimeter([CGPoint(x: 0, y: -100), CGPoint(x: 100, y: 80),
                                        CGPoint(x: -100, y: 80)]))

        let line = (0..<steps).map { CGPoint(x: CGFloat($0) / CGFloat(steps - 1) * 200 - 100, y: 0) }
        built.append(Template(kind: .line, points: Self.normalise(line)))
        built.append(Template(kind: .line, points: Self.normalise(line.reversed())))

        templates = built
    }

    /// `nil` when the stroke is too short to judge. Score runs 0…1.
    func recognise(_ points: [CGPoint]) -> (kind: Unistroke, score: CGFloat)? {
        guard points.count >= 8 else { return nil }
        let candidate = Self.normalise(points)

        var best = CGFloat.greatestFiniteMagnitude
        var match: Unistroke?
        for template in templates {
            let d = Self.distanceAtBestAngle(candidate, template.points)
            if d < best { best = d; match = template.kind }
        }
        guard let match else { return nil }
        return (match, 1 - best / Self.halfDiagonal)
    }

    // MARK: - The $1 pipeline

    private static func normalise(_ points: [CGPoint]) -> [CGPoint] {
        var p = resample(points, to: sampleCount)
        p = rotate(p, by: -indicativeAngle(p))
        p = scaleToSquare(p)
        return translateToOrigin(p)
    }

    private static func pathLength(_ points: [CGPoint]) -> CGFloat {
        var total: CGFloat = 0
        for i in 1..<points.count { total += hypot(points[i].x - points[i-1].x, points[i].y - points[i-1].y) }
        return total
    }

    private static func resample(_ points: [CGPoint], to count: Int) -> [CGPoint] {
        let interval = pathLength(points) / CGFloat(count - 1)
        guard interval > 0 else { return Array(repeating: points[0], count: count) }
        var distance: CGFloat = 0
        var source = points
        var out = [points[0]]
        var i = 1
        while i < source.count {
            let previous = source[i - 1], current = source[i]
            let step = hypot(current.x - previous.x, current.y - previous.y)
            if distance + step >= interval {
                let t = (interval - distance) / step
                let inserted = CGPoint(x: previous.x + t * (current.x - previous.x),
                                       y: previous.y + t * (current.y - previous.y))
                out.append(inserted)
                source.insert(inserted, at: i)
                distance = 0
            } else {
                distance += step
            }
            i += 1
        }
        while out.count < count { out.append(source[source.count - 1]) }
        return Array(out.prefix(count))
    }

    private static func centroid(_ points: [CGPoint]) -> CGPoint {
        let sum = points.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        return CGPoint(x: sum.x / CGFloat(points.count), y: sum.y / CGFloat(points.count))
    }

    private static func indicativeAngle(_ points: [CGPoint]) -> CGFloat {
        let c = centroid(points)
        return atan2(c.y - points[0].y, c.x - points[0].x)
    }

    private static func rotate(_ points: [CGPoint], by radians: CGFloat) -> [CGPoint] {
        let c = centroid(points)
        let cosine = cos(radians), sine = sin(radians)
        return points.map { p in
            CGPoint(x: (p.x - c.x) * cosine - (p.y - c.y) * sine + c.x,
                    y: (p.x - c.x) * sine + (p.y - c.y) * cosine + c.y)
        }
    }

    private static func scaleToSquare(_ points: [CGPoint]) -> [CGPoint] {
        let xs = points.map(\.x), ys = points.map(\.y)
        let width = max(xs.max()! - xs.min()!, 0.0001)
        let height = max(ys.max()! - ys.min()!, 0.0001)
        // Stretching a bounding box to a square blows a straight line's own
        // wobble up to the full height of the square. Anything this thin gets
        // scaled uniformly instead — the paper's own caveat for 1-D gestures.
        let thinness = min(width, height) / max(width, height)
        if thinness < 0.3 {
            let factor = squareSize / max(width, height)
            return points.map { CGPoint(x: $0.x * factor, y: $0.y * factor) }
        }
        return points.map { CGPoint(x: $0.x * squareSize / width, y: $0.y * squareSize / height) }
    }

    private static func translateToOrigin(_ points: [CGPoint]) -> [CGPoint] {
        let c = centroid(points)
        return points.map { CGPoint(x: $0.x - c.x, y: $0.y - c.y) }
    }

    private static func pathDistance(_ a: [CGPoint], _ b: [CGPoint]) -> CGFloat {
        var total: CGFloat = 0
        for i in 0..<min(a.count, b.count) { total += hypot(a[i].x - b[i].x, a[i].y - b[i].y) }
        return total / CGFloat(min(a.count, b.count))
    }

    private static func distanceAtAngle(_ points: [CGPoint], _ template: [CGPoint], _ radians: CGFloat) -> CGFloat {
        pathDistance(rotate(points, by: radians), template)
    }

    /// Golden section search over the residual rotation, as in the paper.
    private static func distanceAtBestAngle(_ points: [CGPoint], _ template: [CGPoint]) -> CGFloat {
        var low = -angleRange, high = angleRange
        var x1 = phi * low + (1 - phi) * high
        var f1 = distanceAtAngle(points, template, x1)
        var x2 = (1 - phi) * low + phi * high
        var f2 = distanceAtAngle(points, template, x2)
        while abs(high - low) > anglePrecision {
            if f1 < f2 {
                high = x2; x2 = x1; f2 = f1
                x1 = phi * low + (1 - phi) * high
                f1 = distanceAtAngle(points, template, x1)
            } else {
                low = x1; x1 = x2; f1 = f2
                x2 = (1 - phi) * low + phi * high
                f2 = distanceAtAngle(points, template, x2)
            }
        }
        return min(f1, f2)
    }
}
