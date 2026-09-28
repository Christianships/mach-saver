// Draws the app icon: the afterburner jet in deep purple dots on a dark violet
// background, with a soft glow and a highlight catching the wing.
// Usage: make icon  (renders Icon/AppIcon.iconset, then iconutil builds AppIcon.icns)
import AppKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)    // run from the repo root
let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Icon/AppIcon.iconset")

// The jet's dots, from the same braille file the screensaver uses.
let bits: [(bit: UInt32, dx: Int, dy: Int)] = [(0x01, 0, 0), (0x02, 0, 1), (0x04, 0, 2), (0x08, 1, 0),
                                               (0x10, 1, 1), (0x20, 1, 2), (0x40, 0, 3), (0x80, 1, 3)]
let text = try! String(contentsOf: root.appendingPathComponent("screensavers/afterburner/jet.txt"), encoding: .utf8)
var dots: [(x: Int, y: Int)] = []
for (row, line) in text.components(separatedBy: .newlines).enumerated() {
    for (col, s) in line.unicodeScalars.enumerated() where (0x2800...0x28FF).contains(s.value) {
        for b in bits where (s.value - 0x2800) & b.bit != 0 { dots.append((col * 2 + b.dx, row * 4 + b.dy)) }
    }
}
let minX = dots.map(\.x).min()!, minY = dots.map(\.y).min()!
dots = dots.map { ($0.x - minX, $0.y - minY) }
let jetW = dots.map(\.x).max()! + 1, jetH = dots.map(\.y).max()! + 1

func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}
// Deep purple, light at the top of the jet to saturated violet at the bottom.
let accent: [(Double, Double, Double)] = [(192, 132, 252), (168, 85, 247), (147, 51, 234), (126, 34, 206)]
func ramp(_ t: Double) -> CGColor {
    let t = min(1, max(0, t)) * Double(accent.count - 1)
    let i = min(accent.count - 2, Int(t)), f = t - Double(i)
    let a = accent[i], b = accent[i + 1]
    return rgb(a.0 + (b.0 - a.0) * f, a.1 + (b.1 - a.1) * f, a.2 + (b.2 - a.2) * f)
}

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // Drawn top-down in a 1024 grid.
    ctx.translateBy(x: 0, y: s); ctx.scaleBy(x: s / 1024, y: -s / 1024)

    // macOS icon grid: 824pt body inset 100pt.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 12), blur: 28, color: CGColor(gray: 0, alpha: 0.35))
    ctx.addPath(shape); ctx.setFillColor(rgb(18, 6, 43)); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape); ctx.clip()
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let bg = CGGradient(colorsSpace: space, colors: [rgb(46, 16, 101), rgb(18, 6, 43)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])
    let glow = CGGradient(colorsSpace: space, colors: [rgb(124, 58, 237, 0.55), rgb(124, 58, 237, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 520), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: 520), endRadius: 420, options: [])

    // The jet, as big as fits with a margin. Small icons get fewer, fatter
    // dots per pixel, so grow them a little to stay solid.
    let area: CGFloat = 660
    let pitch = min(area / CGFloat(jetW), area / CGFloat(jetH))
    let ox = 512 - CGFloat(jetW) * pitch / 2, oy = 512 - CGFloat(jetH) * pitch / 2 + 8
    let size = pitch * (px <= 64 ? 1.0 : 0.8)
    let sweep = { (x: Int, y: Int) -> Double in abs(Double(x) + Double(y) * 0.6 - Double(jetW) * 0.55) }
    for d in dots {
        let shine = max(0, 1 - sweep(d.x, d.y) / 9) * 0.75
        var c = ramp(Double(d.y) / Double(jetH))
        if shine > 0, let comps = c.components {
            c = CGColor(srgbRed: comps[0] + (1 - comps[0]) * shine, green: comps[1] + (1 - comps[1]) * shine,
                        blue: comps[2] + (1 - comps[2]) * shine, alpha: 1)
        }
        ctx.setFillColor(c)
        ctx.fill(CGRect(x: ox + CGFloat(d.x) * pitch, y: oy + CGFloat(d.y) * pitch, width: size, height: size))
    }
    ctx.restoreGState()

    // A thin inner rim so the dark icon doesn't vanish on dark backgrounds.
    ctx.addPath(CGPath(roundedRect: body.insetBy(dx: 3, dy: 3), cornerWidth: 182, cornerHeight: 182, transform: nil))
    ctx.setStrokeColor(rgb(147, 51, 234, 0.45)); ctx.setLineWidth(6); ctx.strokePath()

    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                   ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! render(px).write(to: out.appendingPathComponent("icon_\(name).png"))
}
