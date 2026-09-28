import CoreGraphics

struct RGB {
    var r, g, b: Double

    init(_ r: Double, _ g: Double, _ b: Double) { self.r = r; self.g = g; self.b = b }

    func mix(_ other: RGB, _ t: Double) -> RGB {
        RGB(r + (other.r - r) * t, g + (other.g - g) * t, b + (other.b - b) * t)
    }

    func cg(_ alpha: Double = 1) -> CGColor {
        CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: alpha)
    }
}

struct Palette {
    let name: String
    let title: String
    let background: RGB
    let fire: [RGB]     // cold -> hot
    let accent: [RGB]   // logo gradient, top -> bottom
    var text: [RGB]? = nil  // MACH gradient, left -> right; nil uses `accent`
    var camo = false        // MACH painted in camo bands of `text` instead of a gradient

    static func ramp(_ stops: [RGB], _ t: Double) -> RGB {
        let t = min(1, max(0, t)) * Double(stops.count - 1)
        let i = min(stops.count - 2, Int(t))
        return stops[i].mix(stops[i + 1], t - Double(i))
    }

    // Matches the fastfetch logo gradient and the Ghostty/Zed #0b0713 background.
    static let purple = Palette(
        name: "purple", title: "Purple",
        background: RGB(11, 7, 19),
        fire: [RGB(43, 32, 64), RGB(61, 47, 92), RGB(92, 52, 140), RGB(128, 70, 196), RGB(146, 76, 222),
               RGB(168, 85, 247), RGB(182, 112, 244), RGB(200, 138, 252), RGB(218, 166, 255),
               RGB(236, 196, 255), RGB(246, 228, 255), RGB(255, 255, 255)],
        accent: [RGB(236, 196, 255), RGB(218, 166, 255), RGB(200, 138, 252),
                 RGB(182, 112, 244), RGB(164, 92, 234), RGB(146, 76, 222)],
        // Deeper than the jet, so MACH reads as solid violet over it.
        text: [RGB(168, 85, 247), RGB(147, 51, 234), RGB(126, 34, 206), RGB(107, 33, 168)])

    static let classic = Palette(
        name: "classic", title: "Classic Fire",
        background: RGB(10, 6, 4),
        fire: [RGB(50, 12, 6), RGB(90, 18, 6), RGB(130, 28, 6), RGB(170, 42, 8), RGB(205, 62, 10),
               RGB(232, 92, 16), RGB(245, 122, 22), RGB(250, 152, 34), RGB(255, 182, 56),
               RGB(255, 210, 96), RGB(255, 235, 160), RGB(255, 255, 235)],
        accent: [RGB(255, 235, 160), RGB(255, 205, 90), RGB(255, 165, 45),
                 RGB(245, 125, 30), RGB(225, 90, 25), RGB(200, 62, 20)])

    // Closest to the white-on-black clip.
    static let mono = Palette(
        name: "mono", title: "Mono",
        background: RGB(0, 0, 0),
        fire: (0..<12).map { i in let v = 45 + Double(i) * 19; return RGB(v, v, v) },
        accent: [RGB(250, 250, 250), RGB(232, 232, 232), RGB(214, 214, 214),
                 RGB(196, 196, 196), RGB(178, 178, 178), RGB(160, 160, 160)])

    // mach-boot's strike screen: camo grays, a gunmetal jet, orange fire.
    static let military = Palette(
        name: "military", title: "Military",
        background: RGB(20, 20, 20),
        fire: [RGB(62, 62, 62), RGB(107, 70, 54), RGB(184, 70, 26), RGB(240, 106, 28),
               RGB(255, 154, 51), RGB(255, 200, 107), RGB(255, 241, 201), RGB(255, 255, 255)],
        accent: [RGB(233, 236, 239), RGB(183, 189, 198), RGB(142, 145, 150), RGB(107, 110, 115), RGB(75, 77, 80)],
        // mach-boot's CAMO grays, each lifted a step so every band stands off the background.
        text: [RGB(88, 91, 96), RGB(120, 123, 128), RGB(160, 163, 168), RGB(230, 231, 233)],
        camo: true)

    static let builtIn = [purple, military, classic, mono]

    /// Built-in palettes, then the colourways saved in the library.
    static var all: [Palette] { builtIn + Library.load().colorways.map(\.palette) }

    static func named(_ name: String) -> Palette {
        builtIn.first { $0.name == name } ?? Library.load().colorways.first { $0.id == name }?.palette ?? purple
    }
}
