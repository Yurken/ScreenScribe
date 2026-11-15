import AppKit
import Combine

public enum AnnotationTool: String, CaseIterable, Identifiable {
    case select, pen, highlighter, line, arrow, rectangle, ellipse, text, eraser, blur

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .select: return "选择"
        case .pen: return "画笔"
        case .highlighter: return "荧光笔"
        case .line: return "直线"
        case .arrow: return "箭头"
        case .rectangle: return "矩形"
        case .ellipse: return "椭圆"
        case .text: return "文字"
        case .eraser: return "橡皮擦"
        case .blur: return "像素遮挡"
        }
    }
    public var symbol: String {
        switch self {
        case .select: return "cursorarrow"
        case .pen: return "pencil.tip"
        case .highlighter: return "highlighter"
        case .line: return "line.diagonal"
        case .arrow: return "arrow.up.right"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .text: return "textformat"
        case .eraser: return "eraser"
        case .blur: return "square.grid.3x3.fill"
        }
    }
    public var shortcut: String {
        switch self {
        case .select: return "V"
        case .pen: return "P"
        case .highlighter: return "H"
        case .line: return "L"
        case .arrow: return "A"
        case .rectangle: return "R"
        case .ellipse: return "O"
        case .text: return "T"
        case .eraser: return "E"
        case .blur: return "B"
        }
    }
}

public struct Annotation: Identifiable, Equatable {
    public let id: UUID
    public var tool: AnnotationTool
    public var points: [NSPoint]
    public var color: NSColor
    public var strokeWidth: CGFloat
    public var text: String
    public var fontSize: CGFloat
    public var fontFamily: String
    public var textBold: Bool
    public var textItalic: Bool
    public var textUnderline: Bool
    public var textBackground: Bool
    public var fillShapes: Bool

    public init(id: UUID = UUID(), tool: AnnotationTool, points: [NSPoint], color: NSColor = .systemRed,
                strokeWidth: CGFloat = 4, text: String = "", fontSize: CGFloat = 28,
                fontFamily: String = "Sans", textBold: Bool = false, textItalic: Bool = false,
                textUnderline: Bool = false, textBackground: Bool = false, fillShapes: Bool = false) {
        self.id = id; self.tool = tool; self.points = points; self.color = color
        self.strokeWidth = strokeWidth; self.text = text; self.fontSize = fontSize
        self.fontFamily = fontFamily; self.textBold = textBold; self.textItalic = textItalic
        self.textUnderline = textUnderline; self.textBackground = textBackground; self.fillShapes = fillShapes
    }

    public var font: NSFont {
        let weight: NSFont.Weight = textBold ? .bold : .regular
        var value: NSFont
        switch fontFamily {
        case "Serif": value = NSFont(name: textBold ? "TimesNewRomanPS-BoldMT" : "TimesNewRomanPSMT", size: fontSize) ?? .systemFont(ofSize: fontSize, weight: weight)
        case "Mono": value = .monospacedSystemFont(ofSize: fontSize, weight: weight)
        case "Rounded": value = NSFont(descriptor: NSFont.systemFont(ofSize: fontSize, weight: weight).fontDescriptor.withDesign(.rounded) ?? NSFont.systemFont(ofSize: fontSize).fontDescriptor, size: fontSize) ?? .systemFont(ofSize: fontSize, weight: weight)
        case "Handwriting": value = NSFont(name: "ChalkboardSE-Regular", size: fontSize) ?? .systemFont(ofSize: fontSize, weight: weight)
        default: value = .systemFont(ofSize: fontSize, weight: weight)
        }
        if textItalic { value = NSFontManager.shared.convert(value, toHaveTrait: .italicFontMask) }
        return value
    }

    public var textAttributes: [NSAttributedString.Key: Any] {
        var values: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        if textUnderline { values[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        return values
    }

    public var bounds: NSRect {
        guard let first = points.first else { return .zero }
        if tool == .text {
            let size = ((text.isEmpty ? " " : text) as NSString).size(withAttributes: textAttributes)
            return NSRect(origin: first, size: NSSize(width: max(12, ceil(size.width) + 8), height: max(fontSize * 1.25, ceil(size.height) + 4)))
        }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in points.dropFirst() { minX = min(minX, p.x); maxX = max(maxX, p.x); minY = min(minY, p.y); maxY = max(maxY, p.y) }
        return NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    public func translated(by delta: NSSize) -> Annotation {
        var copy = self
        copy.points = points.map { NSPoint(x: $0.x + delta.width, y: $0.y + delta.height) }
        return copy
    }

    public func scaled(from original: NSRect, to target: NSRect) -> Annotation {
        var copy = self
        let sx = target.width / max(1, original.width), sy = target.height / max(1, original.height)
        copy.points = points.map { NSPoint(x: target.minX + ($0.x - original.minX) * sx, y: target.minY + ($0.y - original.minY) * sy) }
        if tool == .text { copy.fontSize = max(8, min(240, fontSize * max(sx, sy))) }
        return copy
    }

    public func contains(_ point: NSPoint, tolerance: CGFloat = 7) -> Bool {
        let rect = bounds
        let padding = max(tolerance, tool == .highlighter ? max(12, strokeWidth * 4) / 2 : strokeWidth / 2)
        guard rect.insetBy(dx: -padding, dy: -padding).contains(point) else { return false }
        switch tool {
        case .text, .blur: return true
        case .rectangle:
            return fillShapes || !rect.insetBy(dx: padding, dy: padding).contains(point)
        case .ellipse:
            let a = max(rect.width / 2, 0.5), b = max(rect.height / 2, 0.5)
            let radial = pow((point.x - rect.midX) / a, 2) + pow((point.y - rect.midY) / b, 2)
            return fillShapes ? radial <= 1 + padding / min(a, b) : abs(sqrt(radial) - 1) <= padding / min(a, b)
        default:
            if points.count == 1 { return hypot(point.x - points[0].x, point.y - points[0].y) <= padding }
            for i in 1..<points.count where Self.distance(point, to: points[i-1], and: points[i]) <= padding { return true }
            return false
        }
    }

    public static func distance(_ p: NSPoint, to a: NSPoint, and b: NSPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }
}

@MainActor public final class CanvasDocument: ObservableObject {
    @Published public var tool: AnnotationTool = .pen
    @Published public var color: NSColor = NSColor(srgbRed: 1, green: 0.31, blue: 0.36, alpha: 1)
    @Published public var strokeWidth: CGFloat = 4
    @Published public var fontSize: CGFloat = 28
    @Published public var fontFamily: String = "Sans"
    @Published public var textBold = false
    @Published public var textItalic = false
    @Published public var textUnderline = false
    @Published public var textBackground = false
    @Published public var fillShapes = false
    @Published public var selectedID: UUID?
    @Published public private(set) var annotations: [Annotation] = []
    @Published public private(set) var revision = 0
    private var undoStack: [[Annotation]] = []
    private var redoStack: [[Annotation]] = []
    private var transactionBefore: [Annotation]?

    public init() {}
    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }
    public var selectedAnnotation: Annotation? { annotations.first { $0.id == selectedID } }

    public func makeAnnotation(tool: AnnotationTool? = nil, points: [NSPoint], text: String = "") -> Annotation {
        Annotation(tool: tool ?? self.tool, points: points, color: color, strokeWidth: strokeWidth, text: text,
                   fontSize: fontSize, fontFamily: fontFamily, textBold: textBold, textItalic: textItalic,
                   textUnderline: textUnderline, textBackground: textBackground, fillShapes: fillShapes)
    }

    public func add(_ annotation: Annotation) { mutate { $0.append(annotation) } }
    public func remove(id: UUID) {
        guard annotations.contains(where: { $0.id == id }) else { return }
        mutate { $0.removeAll { $0.id == id } }
        if selectedID == id { selectedID = nil }
    }
    public func update(_ annotation: Annotation) {
        guard let index = annotations.firstIndex(where: { $0.id == annotation.id }), annotations[index] != annotation else { return }
        mutate { $0[index] = annotation }
    }
    public func annotation(at point: NSPoint, tolerance: CGFloat = 7) -> Annotation? {
        annotations.reversed().first { $0.contains(point, tolerance: tolerance) }
    }
    public func beginTransaction() { if transactionBefore == nil { transactionBefore = annotations } }
    public func commitTransaction() {
        if let before = transactionBefore, before != annotations { remember(before) }
        transactionBefore = nil
        revision += 1
    }
    public func undo() {
        commitTransaction()
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(annotations); annotations = previous; selectedID = nil; revision += 1
    }
    public func redo() {
        commitTransaction()
        guard let next = redoStack.popLast() else { return }
        undoStack.append(annotations); annotations = next; selectedID = nil; revision += 1
    }
    public func clear() {
        guard !annotations.isEmpty else { return }
        mutate { $0.removeAll() }; selectedID = nil
    }
    public func deleteSelection() { if let selectedID { remove(id: selectedID) } }
    public func duplicateSelection() {
        guard let original = selectedAnnotation else { return }
        var duplicate = Annotation(tool: original.tool, points: original.points, color: original.color,
                                   strokeWidth: original.strokeWidth, text: original.text, fontSize: original.fontSize,
                                   fontFamily: original.fontFamily, textBold: original.textBold, textItalic: original.textItalic,
                                   textUnderline: original.textUnderline, textBackground: original.textBackground,
                                   fillShapes: original.fillShapes)
        duplicate = duplicate.translated(by: NSSize(width: 16, height: 16)); add(duplicate); selectedID = duplicate.id
    }
    public func applyStyleToSelection() {
        guard var annotation = selectedAnnotation else { return }
        annotation.color = color; annotation.strokeWidth = strokeWidth; annotation.fontSize = fontSize
        annotation.fontFamily = fontFamily; annotation.textBold = textBold; annotation.textItalic = textItalic
        annotation.textUnderline = textUnderline; annotation.textBackground = textBackground; annotation.fillShapes = fillShapes
        update(annotation)
    }
    public func adoptStyle(from annotation: Annotation) {
        color = annotation.color; strokeWidth = annotation.strokeWidth; fontSize = annotation.fontSize
        fontFamily = annotation.fontFamily; textBold = annotation.textBold; textItalic = annotation.textItalic
        textUnderline = annotation.textUnderline; textBackground = annotation.textBackground; fillShapes = annotation.fillShapes
    }
    private func mutate(_ mutation: (inout [Annotation]) -> Void) {
        let before = annotations
        mutation(&annotations)
        guard before != annotations else { return }
        if transactionBefore == nil { remember(before) }
        revision += 1
    }
    private func remember(_ snapshot: [Annotation]) {
        undoStack.append(snapshot)
        if undoStack.count > 100 { undoStack.removeFirst() }
        redoStack.removeAll()
    }
}
