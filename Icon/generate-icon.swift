import AppKit
import Foundation

// Renders the SafariSelector icon: a link arriving from the left and branching
// into a choice of three windows on the right.
func render(size: Int) -> Data {
    let S = CGFloat(size)
    let scale = S / 1024.0
    let cs = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                        bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: scale, y: scale)
    ctx.setShouldAntialias(true)

    // Rounded-square background with a vertical gradient.
    let inset: CGFloat = 76
    let rect = CGRect(x: inset, y: inset, width: 1024 - inset * 2, height: 1024 - inset * 2)
    let bg = CGPath(roundedRect: rect, cornerWidth: 200, cornerHeight: 200, transform: nil)
    ctx.saveGState()
    ctx.addPath(bg)
    ctx.clip()
    let grad = CGGradient(colorsSpace: cs, colors: [
        CGColor(red: 0.32, green: 0.60, blue: 0.99, alpha: 1),
        CGColor(red: 0.10, green: 0.29, blue: 0.82, alpha: 1),
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: 1024), end: CGPoint(x: 0, y: 0), options: [])
    ctx.restoreGState()

    ctx.setFillColor(.white)
    ctx.setStrokeColor(.white)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)

    // Three candidate windows on the right, the middle one selected. A single
    // arrow points into it: a link arriving, and a choice being made.
    let wx: CGFloat = 560, ww: CGFloat = 300, wh: CGFloat = 168
    let ys: [CGFloat] = [654, 428, 202]
    for (i, y) in ys.enumerated() {
        let r = CGRect(x: wx, y: y, width: ww, height: wh)
        let p = CGPath(roundedRect: r, cornerWidth: 38, cornerHeight: 38, transform: nil)
        if i == 1 {
            ctx.addPath(p)
            ctx.fillPath()
        } else {
            ctx.addPath(p)
            ctx.setLineWidth(34)
            ctx.setAlpha(0.62)
            ctx.strokePath()
            ctx.setAlpha(1.0)
        }
    }

    // Arrow into the selected window.
    let midY: CGFloat = 428 + wh / 2
    ctx.setLineWidth(58)
    ctx.move(to: CGPoint(x: 172, y: midY))
    ctx.addLine(to: CGPoint(x: 452, y: midY))
    ctx.strokePath()
    ctx.move(to: CGPoint(x: 396, y: midY + 84))
    ctx.addLine(to: CGPoint(x: 492, y: midY))
    ctx.addLine(to: CGPoint(x: 396, y: midY - 84))
    ctx.strokePath()

    let image = ctx.makeImage()!
    let rep = NSBitmapImageRep(cgImage: image)
    return rep.representation(using: .png, properties: [:])!
}

let out = CommandLine.arguments[1]
for size in [16, 32, 48, 64, 96, 128, 256, 512, 1024] {
    let data = render(size: size)
    try! data.write(to: URL(fileURLWithPath: "\(out)/icon_\(size).png"))
}
print("rendered")
