import XCTest
import AppKit
@testable import ScreenScribeCore

final class CanvasInteractionTests: XCTestCase {
    @MainActor private func canvas() -> (CanvasDocument, AnnotationCanvasView, NSWindow) {
        _ = NSApplication.shared
        let document = CanvasDocument()
        let view = AnnotationCanvasView(document: document)
        let window = NSWindow(contentRect: NSRect(x: 0,y: 0,width: 300,height: 200), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.frame = NSRect(x: 0,y: 0,width: 300,height: 200)
        return (document, view, window)
    }
    @MainActor private func event(_ type: NSEvent.EventType, _ point: NSPoint, on view: NSView, shift: Bool = false, clicks: Int = 1) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: shift ? [.shift] : [],
                           timestamp: 0, windowNumber: view.window?.windowNumber ?? 0, context: nil,
                           eventNumber: 1, clickCount: clicks, pressure: 1)!
    }

    func testPenGestureRecordsOneAnnotationAndOneUndoStep() async {
        await MainActor.run {
            let (document, canvas, window) = canvas()
            defer { window.close() }
            document.tool = .pen
            canvas.mouseDown(with: event(.leftMouseDown, NSPoint(x: 10,y: 10), on: canvas))
            for p in [NSPoint(x: 30,y: 35), NSPoint(x: 55,y: 30), NSPoint(x: 90,y: 65)] {
                canvas.mouseDragged(with: event(.leftMouseDragged, p, on: canvas))
            }
            XCTAssertTrue(document.annotations.isEmpty, "A drawing gesture should stay a preview until mouse-up")
            canvas.mouseUp(with: event(.leftMouseUp, NSPoint(x: 90,y: 65), on: canvas))
            XCTAssertEqual(document.annotations.count, 1)
            XCTAssertEqual(document.annotations[0].points.count, 4)
            XCTAssertEqual(document.annotations[0].points.last, NSPoint(x: 90,y: 65))
            document.undo()
            XCTAssertTrue(document.annotations.isEmpty)
            XCTAssertFalse(document.canUndo)
        }
    }

    func testShiftRectangleConstrainsSquareAndDragResizeCanUndo() async {
        await MainActor.run {
            let (document, canvas, window) = canvas()
            defer { window.close() }
            document.tool = .rectangle
            canvas.mouseDown(with: event(.leftMouseDown, NSPoint(x: 10,y: 10), on: canvas))
            canvas.mouseDragged(with: event(.leftMouseDragged, NSPoint(x: 50,y: 30), on: canvas, shift: true))
            canvas.mouseUp(with: event(.leftMouseUp, NSPoint(x: 50,y: 30), on: canvas, shift: true))
            XCTAssertEqual(document.annotations[0].bounds, NSRect(x: 10,y: 10,width: 40,height: 40))
            let original = document.annotations[0]
            document.tool = .select; document.selectedID = original.id
            canvas.mouseDown(with: event(.leftMouseDown, NSPoint(x: 56,y: 56), on: canvas))
            canvas.mouseDragged(with: event(.leftMouseDragged, NSPoint(x: 76,y: 86), on: canvas))
            canvas.mouseUp(with: event(.leftMouseUp, NSPoint(x: 76,y: 86), on: canvas))
            XCTAssertEqual(document.annotations[0].bounds, NSRect(x: 10,y: 10,width: 60,height: 70))
            document.undo()
            XCTAssertEqual(document.annotations, [original])
        }
    }

    func testNativeTextFocusCommitAndCancelPreserveExistingContent() async {
        await MainActor.run {
            let (document, canvas, window) = canvas()
            defer { window.close() }
            document.tool = .text
            canvas.mouseDown(with: event(.leftMouseDown, NSPoint(x: 25,y: 35), on: canvas))
            guard let editor = window.firstResponder as? NSTextView else { XCTFail("Text tool must use native NSTextView"); return }
            editor.string = "中文讲课批注"
            canvas.focusInput()
            XCTAssertTrue(window.firstResponder === editor)
            XCTAssertTrue(canvas.isEditingText)
            canvas.finishEditing()
            XCTAssertFalse(canvas.isEditingText)
            XCTAssertEqual(document.annotations.count, 1)
            XCTAssertEqual(document.annotations[0].text, "中文讲课批注")
            XCTAssertEqual(document.annotations[0].points[0], NSPoint(x: 25,y: 35))
            canvas.mouseDown(with: event(.leftMouseDown, NSPoint(x: 30,y: 40), on: canvas, clicks: 2))
            guard let existingEditor = window.firstResponder as? NSTextView else { XCTFail("Double click must reopen text"); return }
            existingEditor.string = "取消的修改"
            canvas.cancelEditing()
            XCTAssertEqual(document.annotations[0].text, "中文讲课批注")
            XCTAssertFalse(canvas.isEditingText)
        }
    }
}
