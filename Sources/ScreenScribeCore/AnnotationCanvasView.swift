import AppKit
import Combine

@MainActor public final class AnnotationCanvasView: NSView, NSTextViewDelegate {
    public let document: CanvasDocument
    public var backgroundImage: NSImage? { didSet { pixelationCache.removeAll(); needsDisplay = true } }
    public var boardColor: NSColor? { didSet { needsDisplay = true } }
    public var onEscape: (() -> Void)?
    public var onToolShortcut: ((String) -> Void)?
    public var onCrop: ((NSRect) -> Void)?
    public var isCropping = false { didSet { cropStart = nil; cropRect = nil; needsDisplay = true; window?.invalidateCursorRects(for: self) } }

    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }
    public override var isOpaque: Bool { boardColor != nil || backgroundImage != nil }

    private var subscription: AnyCancellable?
    private var draft: Annotation?
    private var dragStart: NSPoint?
    private var originalSelection: Annotation?
    private var resizing = false
    private var textEditor: CanvasTextView?
    private var editingID: UUID?
    private var editingAnchor: NSPoint = .zero
    private var suppressEditorCallback = false
    private var cropStart: NSPoint?
    private var cropRect: NSRect?
    private var pixelationCache: [UUID: (NSRect, CGFloat, NSImage)] = [:]

    public init(document: CanvasDocument) {
        self.document = document
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        subscription = document.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if self.textEditor != nil && self.document.tool != .text { self.finishEditing() }
                self.updateEditorStyle()
                self.needsDisplay = true
                self.window?.invalidateCursorRects(for: self)
            }
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func resetCursorRects() {
        addCursorRect(bounds, cursor: isCropping ? .crosshair : (document.tool == .text ? .iBeam : (document.tool == .select ? .arrow : .crosshair)))
    }

    public override func draw(_ dirtyRect: NSRect) { paint(includingSelection: true) }

    private func paint(includingSelection: Bool) {
        NSGraphicsContext.current?.shouldAntialias = true
        if let boardColor { boardColor.setFill(); bounds.fill() }
        else if let backgroundImage {
            backgroundImage.draw(in: bounds, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        }
        for annotation in document.annotations where annotation.id != editingID { draw(annotation) }
        if let draft { draw(draft) }
        if includingSelection, let selected = document.selectedAnnotation, selected.id != editingID { drawSelection(selected) }
        if includingSelection, isCropping { drawCropSelection() }
    }

    private func draw(_ annotation: Annotation) {
        guard let first = annotation.points.first else { return }
        let last = annotation.points.last ?? first
        let rect = annotation.bounds
        let color = annotation.tool == .highlighter ? annotation.color.withAlphaComponent(0.30) : annotation.color
        color.setStroke(); color.setFill()
        let path = NSBezierPath()
        path.lineWidth = annotation.tool == .highlighter ? max(12, annotation.strokeWidth * 4) : annotation.strokeWidth
        path.lineCapStyle = .round; path.lineJoinStyle = .round
        switch annotation.tool {
        case .pen, .highlighter:
            if annotation.points.count == 1 {
                NSBezierPath(ovalIn: NSRect(x: first.x-path.lineWidth/2, y: first.y-path.lineWidth/2, width: path.lineWidth, height: path.lineWidth)).fill()
            } else {
                path.move(to: first)
                if annotation.points.count > 2 {
                    for i in 1..<annotation.points.count {
                        let p = annotation.points[i], prev = annotation.points[i - 1]
                        let mid = NSPoint(x: (p.x + prev.x)/2, y: (p.y + prev.y)/2)
                        path.curve(to: mid, controlPoint1: prev, controlPoint2: prev)
                    }
                }
                path.line(to: last); path.stroke()
            }
        case .line, .arrow:
            path.move(to: first); path.line(to: last); path.stroke()
            if annotation.tool == .arrow {
                let angle = atan2(last.y-first.y, last.x-first.x), size = max(13, annotation.strokeWidth * 3.5)
                let head = NSBezierPath(); head.move(to: last)
                head.line(to: NSPoint(x: last.x-size*cos(angle-0.43), y: last.y-size*sin(angle-0.43)))
                head.line(to: NSPoint(x: last.x-size*cos(angle+0.43), y: last.y-size*sin(angle+0.43)))
                head.close(); head.fill()
            }
        case .rectangle, .ellipse:
            let shape = annotation.tool == .rectangle ? NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3) : NSBezierPath(ovalIn: rect)
            shape.lineWidth = annotation.strokeWidth
            if annotation.fillShapes { annotation.color.withAlphaComponent(0.22).setFill(); shape.fill() }
            annotation.color.setStroke(); shape.stroke()
        case .text:
            if annotation.textBackground {
                annotation.color.withAlphaComponent(0.18).setFill()
                NSBezierPath(roundedRect: rect.insetBy(dx: -5, dy: -2), xRadius: 5, yRadius: 5).fill()
            }
            (annotation.text as NSString).draw(in: rect, withAttributes: annotation.textAttributes)
        case .blur:
            guard rect.width >= 1, rect.height >= 1 else { return }
            if let pixelated = pixelatedImage(for: annotation) {
                pixelated.draw(in: rect.intersection(bounds), from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.none])
            } else {
                NSColor(white: 0.10, alpha: 1).setFill(); rect.fill()
            }
        case .select, .eraser: break
        }
    }

    private func pixelatedImage(for annotation: Annotation) -> NSImage? {
        let rect = annotation.bounds.intersection(bounds)
        if let cached = pixelationCache[annotation.id], cached.0 == rect, cached.1 == annotation.strokeWidth { return cached.2 }
        guard let source = backgroundImage, let cg = source.cgImage(forProposedRect: nil, context: nil, hints: nil), bounds.width > 0, bounds.height > 0 else { return nil }
        let sx = CGFloat(cg.width) / bounds.width, sy = CGFloat(cg.height) / bounds.height
        let pixelRect = CGRect(x: rect.minX*sx, y: rect.minY*sy, width: rect.width*sx, height: rect.height*sy).integral
        guard let cropped = cg.cropping(to: pixelRect) else { return nil }
        let blockSize = max(12, annotation.strokeWidth * 4)
        let columns = max(1, Int(ceil(rect.width / blockSize))), rows = max(1, Int(ceil(rect.height / blockSize)))
        guard let context = CGContext(data: nil, width: columns, height: rows, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .low
        context.draw(cropped, in: CGRect(x: 0,y: 0,width: columns,height: rows))
        guard let output = context.makeImage() else { return nil }
        let image = NSImage(cgImage: output, size: rect.size)
        pixelationCache[annotation.id] = (rect, annotation.strokeWidth, image)
        return image
    }

    private func drawSelection(_ annotation: Annotation) {
        let rect = annotation.bounds.insetBy(dx: -6, dy: -6)
        NSColor.controlAccentColor.setStroke()
        let outline = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
        outline.lineWidth = 1; outline.setLineDash([4, 3], count: 2, phase: 0); outline.stroke()
        let handle = handleRect(for: annotation)
        NSColor.controlAccentColor.setFill(); NSBezierPath(roundedRect: handle, xRadius: 2, yRadius: 2).fill()
        NSColor.white.setStroke(); let border = NSBezierPath(roundedRect: handle, xRadius: 2, yRadius: 2); border.lineWidth = 1; border.stroke()
    }
    private func handleRect(for annotation: Annotation) -> NSRect {
        let rect = annotation.bounds
        return NSRect(x: rect.maxX + 1, y: rect.maxY + 1, width: 10, height: 10)
    }

    public override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if isCropping { finishEditing(); cropStart = point; cropRect = NSRect(origin: point, size: .zero); needsDisplay = true; return }
        if let selected = document.selectedAnnotation, handleRect(for: selected).insetBy(dx: -4, dy: -4).contains(point), document.tool == .select || document.tool == .text {
            finishEditing(); originalSelection = selected; dragStart = point; resizing = true; document.beginTransaction(); return
        }
        finishEditing()
        window?.makeFirstResponder(self)
        dragStart = point
        switch document.tool {
        case .select:
            if let hit = document.annotation(at: point) {
                document.selectedID = hit.id; document.adoptStyle(from: hit)
                if event.clickCount >= 2 && hit.tool == .text { document.tool = .text; beginEditing(hit, at: hit.points[0]); return }
                originalSelection = hit; document.beginTransaction()
            } else { document.selectedID = nil }
        case .text:
            if let hit = document.annotation(at: point), hit.tool == .text {
                document.selectedID = hit.id; document.adoptStyle(from: hit)
                if event.clickCount >= 2 { beginEditing(hit, at: hit.points[0]) }
                else { originalSelection = hit; document.beginTransaction() }
            } else { document.selectedID = nil; beginEditing(nil, at: point) }
        case .eraser:
            document.selectedID = nil; document.beginTransaction(); erase(at: point)
        default:
            document.selectedID = nil
            draft = document.makeAnnotation(points: [point, point])
            if document.tool == .pen || document.tool == .highlighter { draft?.points = [point] }
        }
        needsDisplay = true
    }

    public override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if isCropping, let cropStart { cropRect = normalizedRect(cropStart, point); needsDisplay = true; return }
        guard let start = dragStart else { return }
        if let originalSelection {
            if resizing {
                var target = originalSelection.bounds
                target.size.width = max(12, originalSelection.bounds.width + point.x-start.x)
                target.size.height = max(12, originalSelection.bounds.height + point.y-start.y)
                document.update(originalSelection.scaled(from: originalSelection.bounds, to: target))
            } else { document.update(originalSelection.translated(by: NSSize(width: point.x-start.x, height: point.y-start.y))) }
        } else if document.tool == .eraser { erase(at: point) }
        else if var value = draft {
            if value.tool == .pen || value.tool == .highlighter {
                if let last = value.points.last, hypot(point.x-last.x, point.y-last.y) >= 0.5 { value.points.append(point) }
            } else { value.points = [start, constrained(point, from: start, tool: value.tool, shift: event.modifierFlags.contains(.shift))] }
            draft = value
        }
        needsDisplay = true
    }

    public override func mouseUp(with event: NSEvent) {
        if isCropping {
            let result = cropRect?.intersection(bounds)
            isCropping = false
            if let result, result.width > 2, result.height > 2 { onCrop?(result) }
            return
        }
        if let value = draft {
            if value.tool == .pen || value.tool == .highlighter || value.bounds.width > 2 || value.bounds.height > 2 { document.add(value) }
            draft = nil
        }
        if originalSelection != nil || document.tool == .eraser { document.commitTransaction() }
        originalSelection = nil; dragStart = nil; resizing = false; needsDisplay = true
    }

    private func erase(at point: NSPoint) {
        if let hit = document.annotation(at: point, tolerance: max(8, document.strokeWidth*2)) { document.remove(id: hit.id) }
    }
    private func normalizedRect(_ a: NSPoint, _ b: NSPoint) -> NSRect {
        NSRect(x: min(a.x,b.x), y: min(a.y,b.y), width: abs(b.x-a.x), height: abs(b.y-a.y))
    }
    private func constrained(_ point: NSPoint, from start: NSPoint, tool: AnnotationTool, shift: Bool) -> NSPoint {
        guard shift else { return point }
        let dx = point.x-start.x, dy = point.y-start.y
        if tool == .line || tool == .arrow {
            let angle = (atan2(dy, dx) / (.pi/4)).rounded() * (.pi/4), length = hypot(dx, dy)
            return NSPoint(x: start.x+length*cos(angle), y: start.y+length*sin(angle))
        }
        let side = max(abs(dx), abs(dy))
        return NSPoint(x: start.x + (dx < 0 ? -side : side), y: start.y + (dy < 0 ? -side : side))
    }

    public override func keyDown(with event: NSEvent) {
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if event.keyCode == 53 {
            if isCropping { isCropping = false; return }
            if document.selectedID != nil { document.selectedID = nil; return }
            onEscape?(); return
        }
        if event.modifierFlags.contains(.command) {
            switch key {
            case "z": event.modifierFlags.contains(.shift) ? document.redo() : document.undo()
            case "d": document.duplicateSelection()
            case "a": if let last = document.annotations.last { document.selectedID = last.id; document.tool = .select }
            case "\u{7f}": document.clear()
            default: super.keyDown(with: event)
            }
            return
        }
        if event.keyCode == 51 || event.keyCode == 117 { document.deleteSelection(); return }
        if [123,124,125,126].contains(Int(event.keyCode)), let selected = document.selectedAnnotation {
            let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
            let delta: NSSize
            switch event.keyCode {
            case 123: delta = NSSize(width: -step, height: 0)
            case 124: delta = NSSize(width: step, height: 0)
            case 125: delta = NSSize(width: 0, height: step)
            default: delta = NSSize(width: 0, height: -step)
            }
            document.update(selected.translated(by: delta)); return
        }
        if let tool = AnnotationTool.allCases.first(where: { $0.shortcut.lowercased() == key }) { document.tool = tool; return }
        onToolShortcut?(key)
    }

    private func beginEditing(_ annotation: Annotation?, at point: NSPoint) {
        editingID = annotation?.id; editingAnchor = point
        let style = annotation ?? document.makeAnnotation(tool: .text, points: [point])
        let editor = CanvasTextView(frame: NSRect(x: point.x, y: point.y, width: max(180, style.bounds.width + 20), height: max(48, style.bounds.height)))
        editor.delegate = self; editor.isRichText = false; editor.drawsBackground = false; editor.allowsUndo = true
        editor.isContinuousSpellCheckingEnabled = false; editor.isAutomaticSpellingCorrectionEnabled = false
        editor.font = style.font; editor.textColor = style.color; editor.insertionPointColor = style.color
        editor.textContainerInset = .zero; editor.textContainer?.lineFragmentPadding = 0
        editor.isHorizontallyResizable = true; editor.isVerticallyResizable = true
        editor.autoresizingMask = []; editor.maxSize = NSSize(width: max(100, bounds.maxX-point.x), height: max(60, bounds.maxY-point.y))
        editor.textContainer?.containerSize = NSSize(width: editor.maxSize.width, height: .greatestFiniteMagnitude)
        editor.textContainer?.widthTracksTextView = false
        editor.typingAttributes = style.textAttributes
        editor.string = style.text
        editor.onCommit = { [weak self] in self?.finishEditing() }
        textEditor = editor; addSubview(editor); window?.makeFirstResponder(editor)
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        resizeEditor(); needsDisplay = true
    }
    public func textDidChange(_ notification: Notification) { if !suppressEditorCallback { resizeEditor() } }
    private func updateEditorStyle() {
        guard let editor = textEditor, !editor.hasMarkedText() else { return }
        let style = document.makeAnnotation(tool: .text, points: [editingAnchor])
        guard editor.font != style.font || editor.textColor != style.color || editor.typingAttributes[.underlineStyle] as? Int != style.textAttributes[.underlineStyle] as? Int else { return }
        suppressEditorCallback = true
        editor.font = style.font; editor.textColor = style.color; editor.insertionPointColor = style.color
        editor.typingAttributes = style.textAttributes
        editor.textStorage?.setAttributes(style.textAttributes, range: NSRange(location: 0, length: (editor.string as NSString).length))
        suppressEditorCallback = false
        resizeEditor()
    }
    private func resizeEditor() {
        guard let editor = textEditor, let container = editor.textContainer, let layout = editor.layoutManager else { return }
        layout.ensureLayout(for: container)
        let size = layout.usedRect(for: container).size
        editor.setFrameSize(NSSize(width: min(editor.maxSize.width, max(100, ceil(size.width)+18)), height: min(editor.maxSize.height, max(48, ceil(size.height)+8))))
    }
    public var isEditingText: Bool { textEditor != nil }
    public func focusInput() {
        if let textEditor {
            if window?.firstResponder !== textEditor { window?.makeFirstResponder(textEditor) }
        } else if window?.firstResponder !== self { window?.makeFirstResponder(self) }
    }
    public func cancelEditing() {
        guard let editor = textEditor else { return }
        textEditor = nil; editingID = nil
        editor.removeFromSuperview()
        window?.makeFirstResponder(self); needsDisplay = true
    }
    public func finishEditing() {
        guard let editor = textEditor else { return }
        editor.unmarkText()
        let content = editor.string
        let originalID = editingID
        textEditor = nil; editingID = nil
        editor.removeFromSuperview()
        if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let originalID { document.remove(id: originalID) }
        } else if let originalID, var annotation = document.annotations.first(where: { $0.id == originalID }) {
            annotation.text = content; document.update(annotation); document.selectedID = originalID
        } else {
            let annotation = document.makeAnnotation(tool: .text, points: [editingAnchor], text: content)
            document.add(annotation); document.selectedID = annotation.id
        }
        window?.makeFirstResponder(self); needsDisplay = true
    }

    public func renderedImage() -> NSImage? { renderedImage(in: bounds) }
    public func renderedImage(in requestedRect: NSRect) -> NSImage? {
        finishEditing()
        let rect = requestedRect.intersection(bounds)
        guard rect.width >= 1, rect.height >= 1 else { return nil }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let width = Int(ceil(rect.width*scale)), height = Int(ceil(rect.height*scale))
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                          bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                          colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        rep.size = rect.size
        NSGraphicsContext.saveGraphicsState()
        context.cgContext.scaleBy(x: scale, y: scale)
        context.cgContext.translateBy(x: -rect.minX, y: rect.height + rect.minY)
        context.cgContext.scaleBy(x: 1, y: -1)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context.cgContext, flipped: true)
        paint(includingSelection: false)
        context.flushGraphics(); NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: rect.size); image.addRepresentation(rep)
        return image
    }

    private func drawCropSelection() {
        let mask = NSBezierPath(rect: bounds)
        if let cropRect { mask.appendRect(cropRect); mask.windingRule = .evenOdd }
        NSColor.black.withAlphaComponent(0.42).setFill(); mask.fill()
        if let cropRect {
            NSColor.white.setStroke(); let outline = NSBezierPath(rect: cropRect); outline.lineWidth = 1; outline.stroke()
            let label = "\(Int(cropRect.width)) × \(Int(cropRect.height))"
            let attributes: [NSAttributedString.Key:Any] = [.font:NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium), .foregroundColor:NSColor.white]
            (label as NSString).draw(at: NSPoint(x: cropRect.minX+6, y: max(4,cropRect.minY-24)), withAttributes: attributes)
        }
    }
}

@MainActor private final class CanvasTextView: NSTextView {
    var onCommit: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 && !hasMarkedText() { onCommit?(); return }
        if event.keyCode == 36 && event.modifierFlags.contains(.command) { onCommit?(); return }
        super.keyDown(with: event)
    }
}
