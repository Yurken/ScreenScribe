import AppKit

final class CursorEffectsView: NSView {
    var pointer = NSPoint.zero
    var spotlight = false
    var highlight = false
    var lens = false
    var radius: CGFloat = 140
    var dim: CGFloat = 0.6
    var zoom: CGFloat = 2
    var image: NSImage?
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        if spotlight {
            let path = NSBezierPath(rect: bounds)
            let hole = NSRect(x: pointer.x-radius, y: pointer.y-radius, width: radius*2, height: radius*2)
            path.appendOval(in: hole)
            path.windingRule = .evenOdd
            NSColor.black.withAlphaComponent(dim).setFill(); path.fill()
            let glow = NSShadow(); glow.shadowColor = NSColor.white.withAlphaComponent(0.25); glow.shadowBlurRadius = 18
            NSGraphicsContext.saveGraphicsState(); glow.set()
            NSColor.white.withAlphaComponent(0.12).setStroke()
            NSBezierPath(ovalIn: hole).stroke(); NSGraphicsContext.restoreGraphicsState()
        }
        if highlight {
            let ring = NSBezierPath(ovalIn: NSRect(x: pointer.x-23, y: pointer.y-23, width: 46, height: 46))
            NSColor.systemYellow.withAlphaComponent(0.24).setFill(); ring.fill()
            ring.lineWidth = 2; NSColor.systemYellow.withAlphaComponent(0.9).setStroke(); ring.stroke()
        }
        if lens, let image {
            let diameter: CGFloat = 270
            let center = NSPoint(x: min(max(diameter/2+12,pointer.x+120),bounds.width-diameter/2-12), y: min(max(diameter/2+12,pointer.y-110),bounds.height-diameter/2-12))
            let rect = NSRect(x: center.x-diameter/2,y:center.y-diameter/2,width:diameter,height:diameter)
            let path = NSBezierPath(roundedRect: rect, xRadius: 40, yRadius: 40)
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.35); shadow.shadowBlurRadius = 20; shadow.set()
            NSColor.black.setFill(); path.fill(); NSGraphicsContext.restoreGraphicsState()
            NSGraphicsContext.saveGraphicsState(); path.addClip()
            let sourceSize = diameter / zoom
            let source = NSRect(x: pointer.x-sourceSize/2, y:image.size.height-pointer.y-sourceSize/2,width:sourceSize,height:sourceSize)
            image.draw(in: rect, from: source, operation: .copy, fraction: 1, respectFlipped: true, hints: [.interpolation:NSImageInterpolation.high])
            NSGraphicsContext.restoreGraphicsState()
            path.lineWidth = 3; NSColor.white.withAlphaComponent(0.75).setStroke(); path.stroke()
            let label = "\(String(format: "%.1f", zoom))×"
            label.draw(at: NSPoint(x: rect.minX+18,y:rect.maxY-30), withAttributes: [.font:NSFont.monospacedDigitSystemFont(ofSize:14,weight:.bold),.foregroundColor:NSColor.white,.strokeColor:NSColor.black,.strokeWidth: -2])
        }
    }
}

final class SnipSelectionView: NSView {
    var onComplete: ((NSRect?) -> Void)?
    private var anchor: NSPoint?
    private var endpoint: NSPoint?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    private var selection: NSRect? {
        guard let a = anchor, let b = endpoint else { return nil }
        return NSRect(x:min(a.x,b.x),y:min(a.y,b.y),width:abs(b.x-a.x),height:abs(b.y-a.y)).intersection(bounds)
    }
    override func mouseDown(with event: NSEvent) { anchor = convert(event.locationInWindow,from:nil); endpoint = anchor; needsDisplay = true }
    override func mouseDragged(with event: NSEvent) { endpoint = convert(event.locationInWindow,from:nil); needsDisplay = true }
    override func mouseUp(with event: NSEvent) { endpoint = convert(event.locationInWindow,from:nil); let rect = selection; onComplete?(rect.flatMap { $0.width >= 3 && $0.height >= 3 ? $0 : nil }) }
    override func keyDown(with event: NSEvent) { if event.keyCode == 53 { onComplete?(nil) } }
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(rect:bounds)
        if let rect = selection { path.appendRect(rect); path.windingRule = .evenOdd }
        NSColor.black.withAlphaComponent(0.4).setFill(); path.fill()
        if let rect = selection {
            NSColor.white.setStroke(); let border = NSBezierPath(rect:rect); border.lineWidth = 1.5; border.stroke()
            let label = "\(Int(rect.width)) × \(Int(rect.height)) pt"
            label.draw(at: NSPoint(x:rect.minX+8,y:max(8,rect.minY-26)), withAttributes: [.font:NSFont.monospacedDigitSystemFont(ofSize:13,weight:.medium),.foregroundColor:NSColor.white])
        } else {
            "拖动选择截图区域 · Esc 取消".draw(at:NSPoint(x:bounds.midX-110,y:36),withAttributes:[.font:NSFont.systemFont(ofSize:15,weight:.medium),.foregroundColor:NSColor.white])
        }
    }
}
