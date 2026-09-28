import AppKit

/// The menu bar icon: the screensaver's jet in silhouette, from the same
/// jet.txt dots. Solid while Mach Saver is keeping the Mac awake, faded when
/// it isn't. Rendered up front into 1x and 2x bitmaps and marked as a
/// template, so the menu bar tints it (white on a dark bar) and reliably
/// shows it.
enum MenuIcon {
    static let awake = make(alpha: 1)
    static let resting = make(alpha: 0.45)

    private static let size = NSSize(width: 22, height: 16)

    private static func make(alpha: CGFloat) -> NSImage {
        let img = NSImage(size: size)
        let logo = Afterburner.logo(at: nil)      // always the built-in jet
        for scale in [1, 2] {
            let w = Int(size.width) * scale, h = Int(size.height) * scale
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
            // Fit the dot grid into the box, keeping its shape, y down.
            let pitch = min(CGFloat(w) / CGFloat(max(1, logo.width)), CGFloat(h) / CGFloat(max(1, logo.height)))
            let ox = (CGFloat(w) - CGFloat(logo.width) * pitch) / 2
            let oy = (CGFloat(h) - CGFloat(logo.height) * pitch) / 2
            ctx.setFillColor(CGColor(gray: 0, alpha: alpha))
            // Dots slightly larger than their pitch so the shape reads solid at this size.
            for d in logo.points {
                ctx.fill(CGRect(x: ox + CGFloat(d.x) * pitch, y: CGFloat(h) - oy - CGFloat(d.y + 1) * pitch,
                                width: pitch * 1.25, height: pitch * 1.25))
            }
            guard let cg = ctx.makeImage() else { continue }
            let rep = NSBitmapImageRep(cgImage: cg)
            rep.size = size
            img.addRepresentation(rep)
        }
        img.isTemplate = true
        img.accessibilityDescription = "Mach Saver"
        return img
    }
}
