import AppKit

/// Fits geometry only to deliberate strokes; unrelated handwriting stays freehand.
public enum ShapeRecognizer {
    public static func recognize(_ stroke: Annotation) -> Annotation? {
        guard stroke.tool == .pen, stroke.points.count >= 2 else { return nil }
        let points = resample(stroke.points, limit: 160)
        guard let first = points.first, let last = points.last else { return nil }
        let length = pathLength(points)
        let chord = distance(first, last)
        let bounds = stroke.bounds
        let diagonal = hypot(bounds.width, bounds.height)
        guard length >= 18, diagonal >= 14 else { return nil }
        var result = stroke
        if chord >= 14, length <= chord * 1.18,
           points.allSatisfy({ Annotation.distance($0, to: first, and: last) <= max(3, chord * 0.055) }) {
            result.tool = .line
            // Preserve deliberate diagonals, while cleaning up almost-horizontal/vertical strokes.
            var endpoint = last
            let angle = atan2(last.y - first.y, last.x - first.x)
            let snapped = (angle / (.pi / 4)).rounded() * (.pi / 4)
            if abs(angle - snapped) < 0.12 {
                endpoint = NSPoint(x: first.x + chord * cos(snapped), y: first.y + chord * sin(snapped))
            }
            result.points = [first, endpoint]
            return result
        }
        guard bounds.width >= 14, bounds.height >= 14,
              chord <= max(14, diagonal * 0.22) else { return nil }
        let tolerance = max(3, diagonal * 0.035)
        let corners = polygonCorners(points, tolerance: tolerance)
        if corners.count == 3, abs(signedArea(corners)) > bounds.width * bounds.height * 0.22,
           followsBoundary(points, vertices: corners, tolerance: tolerance * 1.8) {
            result.tool = .triangle
            result.points = equilateralTriangle(corners)
            return result
        }
        if corners.count == 4, let rectangle = fittedRectangle(corners),
           followsBoundary(points, vertices: rectangle, tolerance: tolerance * 2) {
            result.tool = .rectangle; result.points = rectangle
            return result
        }
        let rx = bounds.width / 2, ry = bounds.height / 2
        let errors = points.map { abs(hypot(($0.x - bounds.midX) / rx, ($0.y - bounds.midY) / ry) - 1) }
        let perimeter = .pi * (3 * (rx + ry) - sqrt((3 * rx + ry) * (rx + 3 * ry)))
        if errors.reduce(0, +) / CGFloat(errors.count) <= 0.09,
           (errors.max() ?? 1) <= 0.24, length >= perimeter * 0.75, length <= perimeter * 1.3 {
            var size = bounds.size
            if min(rx, ry) / max(rx, ry) >= 0.84 {
                let diameter = (bounds.width + bounds.height) / 2
                size = NSSize(width: diameter, height: diameter)
            }
            result.tool = .ellipse
            result.points = [NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2),
                             NSPoint(x: bounds.midX + size.width / 2, y: bounds.midY + size.height / 2)]
            return result
        }
        return nil
    }

    private static func distance(_ a: NSPoint, _ b: NSPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
    private static func pathLength(_ points: [NSPoint]) -> CGFloat {
        zip(points, points.dropFirst()).reduce(0) { $0 + distance($1.0, $1.1) }
    }
    private static func resample(_ points: [NSPoint], limit: Int) -> [NSPoint] {
        guard points.count > limit else { return points }
        let step = pathLength(points) / CGFloat(limit - 1)
        guard step > 0 else { return [points[0]] }
        var result = [points[0]], traversed: CGFloat = 0, next = step
        for (a, b) in zip(points, points.dropFirst()) {
            let segment = distance(a, b)
            while segment > 0, next <= traversed + segment {
                let t = (next - traversed) / segment
                result.append(NSPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
                next += step
            }
            traversed += segment
        }
        if result.last != points.last { result.append(points.last!) }
        return result
    }
    private static func simplify(_ points: [NSPoint], tolerance: CGFloat) -> [NSPoint] {
        guard points.count > 2 else { return points }
        var maximum: CGFloat = 0, split = 0
        for index in 1..<(points.count - 1) {
            let value = Annotation.distance(points[index], to: points[0], and: points.last!)
            if value > maximum { maximum = value; split = index }
        }
        guard maximum > tolerance else { return [points[0], points.last!] }
        return simplify(Array(points[...split]), tolerance: tolerance).dropLast()
            + simplify(Array(points[split...]), tolerance: tolerance)
    }
    private static func polygonCorners(_ points: [NSPoint], tolerance: CGFloat) -> [NSPoint] {
        let first = points[0]
        let split = points.indices.max { distance(points[$0], first) < distance(points[$1], first) } ?? 0
        guard split > 0 else { return [] }
        let closed = points + [first]
        var corners = Array(simplify(Array(closed[...split]), tolerance: tolerance).dropLast())
            + Array(simplify(Array(closed[split...]), tolerance: tolerance).dropLast())
        // The stroke may start halfway along an edge, rather than at a corner.
        var removed = true
        while removed, corners.count > 3 {
            removed = false
            for index in corners.indices {
                let previous = corners[(index + corners.count - 1) % corners.count]
                let next = corners[(index + 1) % corners.count]
                if Annotation.distance(corners[index], to: previous, and: next) <= tolerance {
                    corners.remove(at: index); removed = true; break
                }
            }
        }
        return corners
    }
    private static func followsBoundary(_ points: [NSPoint], vertices: [NSPoint], tolerance: CGFloat) -> Bool {
        let perimeter = pathLength(vertices + [vertices[0]])
        guard pathLength(points) >= perimeter * 0.72, pathLength(points) <= perimeter * 1.35 else { return false }
        return points.allSatisfy { point in
            vertices.indices.map { Annotation.distance(point, to: vertices[$0], and: vertices[($0 + 1) % vertices.count]) }.min()! <= tolerance
        }
    }
    private static func signedArea(_ vertices: [NSPoint]) -> CGFloat {
        vertices.indices.reduce(0) { value, i in
            let a = vertices[i], b = vertices[(i + 1) % vertices.count]
            return value + (a.x * b.y - b.x * a.y) / 2
        }
    }
    private static func equilateralTriangle(_ vertices: [NSPoint]) -> [NSPoint] {
        let center = NSPoint(x: vertices.map(\.x).reduce(0, +) / 3, y: vertices.map(\.y).reduce(0, +) / 3)
        let direction: CGFloat = signedArea(vertices) >= 0 ? 1 : -1
        var a: CGFloat = 0, b: CGFloat = 0
        for index in 0..<3 {
            let angle = direction * CGFloat(index) * 2 * .pi / 3
            let x = vertices[index].x - center.x, y = vertices[index].y - center.y
            a += (x * cos(angle) + y * sin(angle)) / 3
            b += (y * cos(angle) - x * sin(angle)) / 3
        }
        return (0..<3).map { index in
            let angle = direction * CGFloat(index) * 2 * .pi / 3
            return NSPoint(x: center.x + a * cos(angle) - b * sin(angle), y: center.y + b * cos(angle) + a * sin(angle))
        }
    }
    private static func fittedRectangle(_ vertices: [NSPoint]) -> [NSPoint]? {
        let edges = vertices.indices.map { i in NSPoint(x: vertices[(i + 1) % 4].x - vertices[i].x, y: vertices[(i + 1) % 4].y - vertices[i].y) }
        let lengths = edges.map { hypot($0.x, $0.y) }
        guard lengths.allSatisfy({ $0 >= 12 }) else { return nil }
        for index in 0..<4 {
            let next = (index + 1) % 4
            let cosine = abs(edges[index].x * edges[next].x + edges[index].y * edges[next].y) / (lengths[index] * lengths[next])
            guard cosine < 0.32 else { return nil }
        }
        let center = NSPoint(x: vertices.map(\.x).reduce(0, +) / 4, y: vertices.map(\.y).reduce(0, +) / 4)
        let u = NSPoint(x: edges[0].x / lengths[0], y: edges[0].y / lengths[0])
        let sign: CGFloat = signedArea(vertices) >= 0 ? 1 : -1
        let v = NSPoint(x: -u.y * sign, y: u.x * sign)
        var width = (lengths[0] + lengths[2]) / 2, height = (lengths[1] + lengths[3]) / 2
        if min(width, height) / max(width, height) > 0.88 { width = (width + height) / 2; height = width }
        return [(-1.0, -1.0), (1, -1), (1, 1), (-1, 1)].map { x, y in
            NSPoint(x: center.x + CGFloat(x) * u.x * width / 2 + CGFloat(y) * v.x * height / 2,
                    y: center.y + CGFloat(x) * u.y * width / 2 + CGFloat(y) * v.y * height / 2)
        }
    }
}
