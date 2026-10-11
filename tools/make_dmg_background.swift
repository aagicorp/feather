// Draws the picture behind the DMG window: Resources/dmg/background.tiff, 660×400 points with a 2× rep for
// Retina. Finder shows Feather.app on the left and the Applications link on the right; the picture carries the
// arrow and the one line of instruction between them.
//   swift tools/make_dmg_background.swift
import AppKit

let size = NSSize(width: 660, height: 400)

func draw(scale: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let bounds = NSRect(origin: .zero, size: size)
    // A quiet light ground; Finder's icon labels are dark on it in both appearances.
    NSGradient(colors: [NSColor(srgbRed: 0.97, green: 0.97, blue: 0.98, alpha: 1), NSColor(srgbRed: 0.91, green: 0.92, blue: 0.95, alpha: 1)])!
        .draw(in: bounds, angle: -90)
    // The arrow, between the two icons (centres at x 165 and 495, y 190 from the top → 210 from the bottom).
    let y: CGFloat = 210
    let arrow = NSBezierPath()
    arrow.lineWidth = 6
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    arrow.move(to: NSPoint(x: 262, y: y))
    arrow.line(to: NSPoint(x: 392, y: y))
    arrow.move(to: NSPoint(x: 366, y: y + 26))
    arrow.line(to: NSPoint(x: 394, y: y))
    arrow.line(to: NSPoint(x: 366, y: y - 26))
    NSColor(srgbRed: 0.42, green: 0.26, blue: 0.70, alpha: 1).setStroke()       // Feather's purple
    arrow.stroke()
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    let title = NSAttributedString(string: "Drag Feather to Applications to install", attributes: [
        .font: NSFont.systemFont(ofSize: 15, weight: .medium), .foregroundColor: NSColor(white: 0.25, alpha: 1), .paragraphStyle: paragraph])
    title.draw(in: NSRect(x: 40, y: 72, width: size.width - 80, height: 24))
    let note = NSAttributedString(string: "Then open it from Launchpad or Spotlight. Feather keeps itself up to date.", attributes: [
        .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor(white: 0.45, alpha: 1), .paragraphStyle: paragraph])
    note.draw(in: NSRect(x: 40, y: 50, width: size.width - 80, height: 20))
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let image = NSImage(size: size)
image.addRepresentation(draw(scale: 1))
image.addRepresentation(draw(scale: 2))
let tiff = NSBitmapImageRep.representationOfImageReps(in: image.representations as! [NSBitmapImageRep], using: .tiff,
                                                      properties: [.compressionMethod: NSBitmapImageRep.TIFFCompression.lzw.rawValue])!
let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources/dmg/background.tiff")
try! tiff.write(to: out)
print("wrote \(out.path)")
