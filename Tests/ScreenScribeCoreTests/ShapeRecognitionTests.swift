import XCTest
import AppKit
@testable import ScreenScribeCore

final class ShapeRecognitionTests: XCTestCase {
    private func stroke(_ points: [NSPoint]) -> Annotation { Annotation(tool: .pen, points: points, color: .systemBlue, strokeWidth: 7) }
    private func edges(_ vertices: [NSPoint], steps: Int = 15) -> [NSPoint] {
        var points: [NSPoint] = []
        for i in vertices.indices {
            let a = vertices[i], b = vertices[(i + 1) % vertices.count]
            for step in 0..<steps {
                let t = CGFloat(step) / CGFloat(steps)
                points.append(NSPoint(x: a.x + (b.x - a.x) * t + sin(t * .pi) * 1.2,
                                      y: a.y + (b.y - a.y) * t + cos(t * .pi) * 0.8))
            }
        }
        points.append(vertices[0])
        return points
    }

    func testWobblyLineBecomesStraightAndPreservesStyleAndIdentity() throws {
        let original = stroke((0...30).map { NSPoint(x: 20 + CGFloat($0) * 6, y: 40 + sin(CGFloat($0)) * 2) })
        let result = try XCTUnwrap(ShapeRecognizer.recognize(original))
        XCTAssertEqual(result.tool, .line)
        XCTAssertEqual(result.points.count, 2)
        XCTAssertEqual(result.points[0].y, result.points[1].y, accuracy: 0.001)
        XCTAssertEqual(result.id, original.id); XCTAssertEqual(result.color, original.color)
        XCTAssertEqual(result.strokeWidth, 7)
    }

    func testTriangleStartingMidEdgeBecomesEquilateralInEitherDirection() throws {
        let corners = [NSPoint(x: 55, y: 12), NSPoint(x: 145, y: 158), NSPoint(x: 12, y: 150)]
        let points = Array(edges(corners).dropLast())
        let rotatedStart = Array(points[8...]) + Array(points[..<8]) + [points[8]]
        for input in [rotatedStart, Array(rotatedStart.reversed())] {
            let result = try XCTUnwrap(ShapeRecognizer.recognize(stroke(input)))
            XCTAssertEqual(result.tool, .triangle)
            XCTAssertEqual(result.points.count, 3)
            let lengths = result.points.indices.map { i in
                let a = result.points[i], b = result.points[(i + 1) % 3]
                return hypot(a.x - b.x, a.y - b.y)
            }
            XCTAssertEqual(lengths[0], lengths[1], accuracy: 0.001)
            XCTAssertEqual(lengths[1], lengths[2], accuracy: 0.001)
        }
    }

    func testRotatedRectangleKeepsRotationAndHasRightAngles() throws {
        let corners = [NSPoint(x: 65, y: 20), NSPoint(x: 205, y: 90), NSPoint(x: 170, y: 160), NSPoint(x: 30, y: 90)]
        let result = try XCTUnwrap(ShapeRecognizer.recognize(stroke(edges(corners))))
        XCTAssertEqual(result.tool, .rectangle)
        XCTAssertEqual(result.points.count, 4)
        let a = result.points[0], b = result.points[1], c = result.points[2]
        XCTAssertEqual((b.x - a.x) * (c.x - b.x) + (b.y - a.y) * (c.y - b.y), 0, accuracy: 0.001)
        XCTAssertGreaterThan(abs(b.y - a.y), 30)
    }

    func testRoughCircleBecomesCircleButOvalKeepsItsAspectRatio() throws {
        for radiusY in [58.0, 32.0] {
            let points = (0...80).map { i -> NSPoint in
                let angle = CGFloat(i) * 2 * .pi / 80
                return NSPoint(x: 100 + 60 * cos(angle) + sin(angle * 5), y: 90 + radiusY * sin(angle) + cos(angle * 3))
            }
            let result = try XCTUnwrap(ShapeRecognizer.recognize(stroke(points)))
            XCTAssertEqual(result.tool, .ellipse)
            if radiusY > 50 { XCTAssertEqual(result.bounds.width, result.bounds.height, accuracy: 0.001) }
            else { XCTAssertGreaterThan(result.bounds.width / result.bounds.height, 1.6) }
        }
    }

    func testScribblesAndTinyMarksStayFreehand() {
        XCTAssertNil(ShapeRecognizer.recognize(stroke([.zero, NSPoint(x: 3, y: 2)])))
        let scribble = (0...90).map { i in NSPoint(x: CGFloat(i) * 2, y: 80 + sin(CGFloat(i) * 0.6) * 55) }
        XCTAssertNil(ShapeRecognizer.recognize(stroke(scribble)))
        let spiral = (0...150).map { i -> NSPoint in
            let angle = CGFloat(i) / 10, radius = CGFloat(i) / 2
            return NSPoint(x: 100 + cos(angle) * radius, y: 100 + sin(angle) * radius)
        }
        XCTAssertNil(ShapeRecognizer.recognize(stroke(spiral)))
    }

    func testTriangleHitTestingUsesEdgesAndFilledInterior() {
        var triangle = Annotation(tool: .triangle, points: [NSPoint(x: 50, y: 10), NSPoint(x: 90, y: 90), NSPoint(x: 10, y: 90)])
        XCTAssertTrue(triangle.contains(NSPoint(x: 70, y: 50)))
        XCTAssertFalse(triangle.contains(NSPoint(x: 50, y: 55)))
        XCTAssertFalse(triangle.contains(NSPoint(x: 12, y: 12)))
        triangle.fillShapes = true
        XCTAssertTrue(triangle.contains(NSPoint(x: 50, y: 55)))
        XCTAssertFalse(triangle.contains(NSPoint(x: 12, y: 12)))
    }
}
