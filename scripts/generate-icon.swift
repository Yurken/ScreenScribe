import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    fputs("Usage: swift generate-icon.swift OUTPUT.iconset\n", stderr)
    exit(2)
}
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func icon(size: Int) throws -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                  isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let context = NSGraphicsContext.current!.cgContext
    context.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)

    let tile = NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896), xRadius: 206, yRadius: 206)
    NSGradient(starting: NSColor(calibratedRed: 0.10, green: 0.18, blue: 0.27, alpha: 1),
               ending: NSColor(calibratedRed: 0.04, green: 0.10, blue: 0.17, alpha: 1))!.draw(in: tile, angle: -45)
    let teal = NSColor(calibratedRed: 0.38, green: 0.88, blue: 0.82, alpha: 1)
    let paper = NSColor(calibratedRed: 0.92, green: 0.97, blue: 0.99, alpha: 1)

    // Open annotation corners suggest a screen without reproducing another app's artwork.
    teal.withAlphaComponent(0.88).setStroke()
    let corners = NSBezierPath()
    corners.lineWidth = 35
    corners.lineCapStyle = .round
    corners.lineJoinStyle = .round
    corners.move(to: NSPoint(x: 388, y: 758)); corners.line(to: NSPoint(x: 276, y: 758)); corners.line(to: NSPoint(x: 276, y: 644))
    corners.move(to: NSPoint(x: 748, y: 386)); corners.line(to: NSPoint(x: 748, y: 276)); corners.line(to: NSPoint(x: 634, y: 276))
    corners.stroke()

    let mark = NSBezierPath()
    mark.move(to: NSPoint(x: 280, y: 336))
    mark.curve(to: NSPoint(x: 470, y: 382), controlPoint1: NSPoint(x: 360, y: 298), controlPoint2: NSPoint(x: 410, y: 400))
    mark.lineWidth = 35
    mark.lineCapStyle = .round
    teal.setStroke(); mark.stroke()

    context.saveGState()
    context.translateBy(x: 505, y: 500)
    context.rotate(by: -.pi / 4)
    paper.setFill()
    NSBezierPath(roundedRect: NSRect(x: -56, y: -125, width: 112, height: 374), xRadius: 24, yRadius: 24).fill()
    let nib = NSBezierPath()
    nib.move(to: NSPoint(x: -56, y: -115)); nib.line(to: NSPoint(x: 56, y: -115)); nib.line(to: NSPoint(x: 0, y: -219)); nib.close()
    paper.setFill(); nib.fill()
    let tip = NSBezierPath()
    tip.move(to: NSPoint(x: -20, y: -181)); tip.line(to: NSPoint(x: 20, y: -181)); tip.line(to: NSPoint(x: 0, y: -219)); tip.close()
    teal.setFill(); tip.fill()
    teal.setFill()
    NSBezierPath(roundedRect: NSRect(x: -56, y: 160, width: 112, height: 42), xRadius: 8, yRadius: 8).fill()
    context.restoreGState()

    // A small six-spoke crystal is the freeze-frame cue.
    let crystal = NSBezierPath()
    let center = NSPoint(x: 727, y: 730)
    for step in 0..<3 {
        let angle = CGFloat(step) * .pi / 3
        let delta = NSPoint(x: cos(angle) * 62, y: sin(angle) * 62)
        crystal.move(to: NSPoint(x: center.x - delta.x, y: center.y - delta.y))
        crystal.line(to: NSPoint(x: center.x + delta.x, y: center.y + delta.y))
    }
    crystal.lineWidth = 15; crystal.lineCapStyle = .round
    teal.setStroke(); crystal.stroke()
    NSGraphicsContext.restoreGraphicsState()
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "ScreenScribe.Icon", code: 1)
    }
    return png
}

func uint32(_ number: Int) -> Data {
    var bigEndian = UInt32(number).bigEndian
    return withUnsafeBytes(of: &bigEndian) { Data($0) }
}
// Modern ICNS entries contain lossless PNGs. Writing the container directly
// keeps packaging independent of iconutil's ImageIO/XPC availability.
let types = [(16, "icp4", "ic11"), (32, "icp5", "ic12"),
             (128, "ic07", "ic13"), (256, "ic08", "ic14"), (512, "ic09", "ic10")]
var payload = Data()
for (size, regularType, retinaType) in types {
    for (scale, type) in [(1, regularType), (2, retinaType)] {
        let png = try icon(size: size * scale)
        let suffix = scale == 2 ? "@2x" : ""
        try png.write(to: output.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
        payload.append(type.data(using: .ascii)!)
        payload.append(uint32(png.count + 8))
        payload.append(png)
    }
}
var container = "icns".data(using: .ascii)!
container.append(uint32(payload.count + 8))
container.append(payload)
try container.write(to: output.deletingPathExtension().appendingPathExtension("icns"))
