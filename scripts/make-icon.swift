// Renders the CoShare app icon as a 1024×1024 PNG.
// Usage: swift scripts/make-icon.swift <output.png> [--mac]
//   --mac adds the transparent margin macOS icons use; without it the square is full-bleed (iOS).
import AppKit

let args = CommandLine.arguments
guard args.count >= 2 else { fatalError("usage: make-icon.swift <output.png> [--mac]") }
let output = URL(fileURLWithPath: args[1])
let isMac = args.contains("--mac")

let size: CGFloat = 1024
guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { fatalError() }
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let inset: CGFloat = isMac ? 100 : 0
let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let shape = isMac ? NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225) : NSBezierPath(rect: rect)

if isMac {
    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowBlurRadius = 24
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.set()
    NSColor.black.setFill()
    shape.fill()
    NSGraphicsContext.current?.restoreGraphicsState()
}

let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.20, green: 0.55, blue: 1.00, alpha: 1),
    NSColor(calibratedRed: 0.42, green: 0.25, blue: 0.95, alpha: 1),
])!
gradient.draw(in: shape, angle: -60)

func symbol(_ name: String, pointSize: CGFloat) -> NSImage {
    let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
        .applying(.init(paletteColors: [.white]))
    return NSImage(systemSymbolName: name, accessibilityDescription: nil)!.withSymbolConfiguration(config)!
}

let clipboard = symbol("doc.on.clipboard.fill", pointSize: rect.width * 0.42)
let clipSize = clipboard.size
clipboard.draw(in: NSRect(x: rect.midX - clipSize.width / 2, y: rect.midY - clipSize.height / 2 - rect.width * 0.02,
                          width: clipSize.width, height: clipSize.height))

let arrows = symbol("arrow.triangle.2.circlepath", pointSize: rect.width * 0.13)
let arrowSize = arrows.size
arrows.draw(in: NSRect(x: rect.maxX - arrowSize.width - rect.width * 0.11, y: rect.minY + rect.width * 0.10,
                       width: arrowSize.width, height: arrowSize.height))

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: output)
print("wrote \(output.path)")
