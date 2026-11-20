// Draws the disk image window background: an arrow from the app to Applications, and a hint.
// Run: swift assets/dmg/background.swift assets/dmg   (writes background.tiff, 1x and 2x)
import AppKit

let out = CommandLine.arguments[1]
let (w, h) = (640.0, 400.0)

func render(scale: Double) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(w * scale), pixelsHigh: Int(h * scale), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: w, height: h)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    // A soft light gradient, so icon labels stay readable.
    NSGradient(starting: NSColor(white: 0.97, alpha: 1), ending: NSColor(white: 0.90, alpha: 1))!.draw(in: NSRect(x: 0, y: 0, width: w, height: h), angle: -90)
    // Arrow between the two icons (centred at x 170 and 470, y 190 from the top).
    let y = h - 190
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 262, y: y)); arrow.line(to: NSPoint(x: 370, y: y))
    arrow.move(to: NSPoint(x: 354, y: y + 14)); arrow.line(to: NSPoint(x: 372, y: y)); arrow.line(to: NSPoint(x: 354, y: y - 14))
    arrow.lineWidth = 5; arrow.lineCapStyle = .round; arrow.lineJoinStyle = .round
    NSColor(white: 0.55, alpha: 1).setStroke(); arrow.stroke()
    let p = NSMutableParagraphStyle(); p.alignment = .center
    NSAttributedString(string: "Drag picoTranslator into Applications", attributes: [
        .font: NSFont.systemFont(ofSize: 15, weight: .medium), .foregroundColor: NSColor(white: 0.45, alpha: 1), .paragraphStyle: p,
    ]).draw(in: NSRect(x: 0, y: 70, width: w, height: 24))
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let tiff = NSBitmapImageRep.tiffRepresentationOfImageReps(in: [render(scale: 1), render(scale: 2)], using: .lzw, factor: 0)!
try! tiff.write(to: URL(fileURLWithPath: out + "/background.tiff"))
