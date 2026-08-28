import AppKit
import Foundation

// SafariSelector's icon is the same glyph as the menu bar item: a trunk diverging
// into two arrows. Rendered on a transparent background so it reads at 16px, where
// a detailed illustration turns to mush.
func render(size: Int, symbol: String) -> Data {
    let S = CGFloat(size)
    let config = NSImage.SymbolConfiguration(pointSize: S * 0.82, weight: .semibold)
    guard let base = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
        .withSymbolConfiguration(config) else {
        fatalError("symbol \(symbol) unavailable")
    }

    let canvas = NSImage(size: NSSize(width: S, height: S))
    canvas.lockFocus()
    NSGraphicsContext.current?.imageInterpolation = .high

    // Centre the glyph on the transparent canvas.
    let g = base.size
    let scale = min(S * 0.86 / g.width, S * 0.86 / g.height)
    let w = g.width * scale, h = g.height * scale
    let rect = NSRect(x: (S - w) / 2, y: (S - h) / 2, width: w, height: h)
    base.draw(in: rect)

    // Tint: a blue that holds up against both light and dark backgrounds, since a
    // static PNG cannot adapt the way a template menu bar image does.
    NSColor(srgbRed: 0.19, green: 0.51, blue: 0.96, alpha: 1).set()
    rect.fill(using: .sourceAtop)
    canvas.unlockFocus()

    guard let tiff = canvas.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        fatalError("encode failed")
    }
    return png
}

let out = CommandLine.arguments[1]
let symbol = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "arrow.triangle.branch"
for size in [16, 32, 48, 64, 96, 128, 256, 512, 1024] {
    try! render(size: size, symbol: symbol).write(to: URL(fileURLWithPath: "\(out)/icon_\(size).png"))
}
print("rendered \(symbol)")
