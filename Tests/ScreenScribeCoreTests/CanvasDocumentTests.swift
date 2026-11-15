import XCTest
import AppKit
@testable import ScreenScribeCore

final class CanvasDocumentTests: XCTestCase {
    func testUndoRedoPreservesAnnotationIdentity() async {
        await MainActor.run {
            let document = CanvasDocument()
            let annotation = document.makeAnnotation(tool: .arrow, points: [NSPoint(x: 10, y: 20), NSPoint(x: 90, y: 80)])
            document.add(annotation)
            XCTAssertTrue(document.canUndo)
            document.undo()
            XCTAssertTrue(document.annotations.isEmpty)
            XCTAssertTrue(document.canRedo)
            document.redo()
            XCTAssertEqual(document.annotations, [annotation])
        }
    }

    func testDragIsOneHistoryTransactionAndNewEditInvalidatesRedo() async {
        await MainActor.run {
            let document = CanvasDocument()
            let original = document.makeAnnotation(tool: .rectangle, points: [NSPoint(x: 10, y: 10), NSPoint(x: 60, y: 60)])
            document.add(original)
            document.beginTransaction()
            for delta in 1...20 { document.update(original.translated(by: NSSize(width: delta, height: delta))) }
            document.commitTransaction()
            XCTAssertEqual(document.annotations[0].bounds.origin, NSPoint(x: 30, y: 30))
            document.undo()
            XCTAssertEqual(document.annotations, [original])
            document.undo()
            XCTAssertTrue(document.annotations.isEmpty)
            document.add(document.makeAnnotation(tool: .pen, points: [.zero]))
            XCTAssertFalse(document.canRedo)
        }
    }

    func testEraserCanUndoEntireGestureAndClearCanUndo() async {
        await MainActor.run {
            let document = CanvasDocument()
            let first = document.makeAnnotation(tool: .text, points: [.zero], text: "中文批注")
            let second = document.makeAnnotation(tool: .ellipse, points: [NSPoint(x: 90, y: 90), NSPoint(x: 120, y: 120)])
            document.add(first); document.add(second)
            document.beginTransaction(); document.remove(id: first.id); document.remove(id: second.id); document.commitTransaction()
            XCTAssertTrue(document.annotations.isEmpty)
            document.undo()
            XCTAssertEqual(document.annotations, [first, second])
            document.clear(); document.undo()
            XCTAssertEqual(document.annotations, [first, second])
        }
    }

    func testSelectionStylesMoveResizeAndDuplicateKeepHistory() async {
        await MainActor.run {
            let document = CanvasDocument()
            let original = document.makeAnnotation(tool: .text, points: [NSPoint(x: 10, y: 20)], text: "可编辑文字")
            document.add(original); document.selectedID = original.id
            document.color = .systemBlue; document.fontSize = 40; document.textBold = true
            document.applyStyleToSelection()
            XCTAssertEqual(document.selectedAnnotation?.fontSize, 40)
            XCTAssertEqual(document.selectedAnnotation?.textBold, true)
            XCTAssertEqual(document.selectedAnnotation?.text, "可编辑文字")
            document.duplicateSelection()
            XCTAssertEqual(document.annotations.count, 2)
            XCTAssertNotEqual(document.annotations[0].id, document.annotations[1].id)
            XCTAssertEqual(document.annotations[1].points[0], NSPoint(x: 26, y: 36))
            document.undo()
            XCTAssertEqual(document.annotations.count, 1)
            document.undo()
            XCTAssertEqual(document.annotations, [original])
        }
    }

    func testStrokeHitTestingDoesNotSelectEmptyBoundingBox() {
        let stroke = Annotation(tool: .line, points: [.zero, NSPoint(x: 100, y: 100)], strokeWidth: 4)
        XCTAssertTrue(stroke.contains(NSPoint(x: 50, y: 52)))
        XCTAssertFalse(stroke.contains(NSPoint(x: 5, y: 90)))
        let rectangle = Annotation(tool: .rectangle, points: [.zero, NSPoint(x: 100, y: 100)])
        XCTAssertTrue(rectangle.contains(NSPoint(x: 1, y: 50)))
        XCTAssertFalse(rectangle.contains(NSPoint(x: 50, y: 50)))
        var filled = rectangle; filled.fillShapes = true
        XCTAssertTrue(filled.contains(NSPoint(x: 50, y: 50)))
    }

    func testTopmostAnnotationHitAndReverseDrawnRectangleGeometry() async {
        await MainActor.run {
            let document = CanvasDocument()
            let first = document.makeAnnotation(tool: .rectangle, points: [NSPoint(x: 100,y: 100), NSPoint(x: 20,y: 20)])
            let second = document.makeAnnotation(tool: .line, points: [NSPoint(x: 20,y: 20), NSPoint(x: 100,y: 100)])
            document.add(first); document.add(second)
            XCTAssertEqual(first.bounds, NSRect(x: 20, y: 20, width: 80, height: 80))
            XCTAssertEqual(document.annotation(at: NSPoint(x: 20,y: 20))?.id, second.id)
            XCTAssertEqual(first.scaled(from: first.bounds, to: NSRect(x: 10, y: 10, width: 40, height: 40)).bounds,
                           NSRect(x: 10, y: 10, width: 40, height: 40))
        }
    }

    func testRetinaExportUsesFullCanvasAndTopLeftCropCoordinates() async {
        await MainActor.run {
            let document = CanvasDocument()
            let view = AnnotationCanvasView(document: document)
            view.frame = NSRect(x: 0, y: 0, width: 100, height: 100)
            view.boardColor = .white
            document.add(Annotation(tool: .rectangle, points: [NSPoint(x: 60,y: 10),NSPoint(x: 90,y: 40)], color: .red, strokeWidth: 4, fillShapes: true))
            guard let image = view.renderedImage(), let rep = image.representations.first as? NSBitmapImageRep else { XCTFail("Missing raster export"); return }
            XCTAssertEqual(image.size, NSSize(width: 100, height: 100))
            XCTAssertGreaterThanOrEqual(rep.pixelsWide, 100)
            let scale = CGFloat(rep.pixelsWide) / 100
            let white = rep.colorAt(x: Int(10*scale), y: Int(80*scale))?.usingColorSpace(.deviceRGB)
            let red = rep.colorAt(x: Int(60*scale), y: Int(20*scale))?.usingColorSpace(.deviceRGB)
            XCTAssertGreaterThan(white?.greenComponent ?? 0, 0.95)
            XCTAssertLessThan(red?.greenComponent ?? 1, 0.2)
            guard let crop = view.renderedImage(in: NSRect(x: 55,y: 5,width: 40,height: 40)),
                  let cropRep = crop.representations.first as? NSBitmapImageRep else { XCTFail("Missing crop export"); return }
            XCTAssertEqual(crop.size, NSSize(width: 40,height: 40))
            let cropScale = CGFloat(cropRep.pixelsWide) / 40
            let cropRed = cropRep.colorAt(x: Int(5*cropScale), y: Int(15*cropScale))?.usingColorSpace(.deviceRGB)
            XCTAssertLessThan(cropRed?.greenComponent ?? 1, 0.2)
        }
    }

    func testFrozenBackgroundAndPixelationKeepSourceOrientation() async {
        await MainActor.run {
            let document = CanvasDocument()
            let view = AnnotationCanvasView(document: document)
            view.frame = NSRect(x: 0,y: 0,width: 80,height: 80)
            let source = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 80, pixelsHigh: 80,
                                          bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                          colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            let red = NSColor(deviceRed: 1, green: 0, blue: 0, alpha: 1)
            let blue = NSColor(deviceRed: 0, green: 0, blue: 1, alpha: 1)
            for y in 0..<80 { for x in 0..<80 { source.setColor(y < 40 ? red : blue, atX: x, y: y) } }
            let background = NSImage(size: NSSize(width: 80,height: 80)); background.addRepresentation(source)
            view.backgroundImage = background
            document.add(Annotation(tool: .blur, points: [NSPoint(x: 10,y: 5),NSPoint(x: 70,y: 25)]))
            guard let image = view.renderedImage(), let output = image.representations.first as? NSBitmapImageRep else { XCTFail("Missing frozen image export"); return }
            let scale = CGFloat(output.pixelsWide) / 80
            let top = output.colorAt(x: Int(30*scale), y: Int(15*scale))?.usingColorSpace(.deviceRGB)
            let bottom = output.colorAt(x: Int(30*scale), y: Int(60*scale))?.usingColorSpace(.deviceRGB)
            XCTAssertGreaterThan(top?.redComponent ?? 0, 0.95, "Pixelation must sample the top of the screenshot")
            XCTAssertLessThan(top?.blueComponent ?? 1, 0.05)
            XCTAssertGreaterThan(bottom?.blueComponent ?? 0, 0.95, "The screenshot must retain its vertical orientation")
        }
    }
}
