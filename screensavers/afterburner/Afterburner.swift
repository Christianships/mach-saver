import AppKit
import QuartzCore
import UniformTypeIdentifiers

struct Rng: RandomNumberGenerator {
    private var s: UInt64
    init(seed: UInt64) { s = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed }
    mutating func next() -> UInt64 { s ^= s << 13; s ^= s >> 7; s ^= s << 17; return s }
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
    mutating func int(_ r: ClosedRange<Int>) -> Int { r.lowerBound + Int(next() % UInt64(r.count)) }
    mutating func range(_ a: Double, _ b: Double) -> Double { a + (b - a) * unit() }
}

/// A monospaced font plus a glyph cache, so the scene can draw thousands of
/// characters a frame straight to exact grid positions.
final class GlyphFont {
    let font: CTFont
    let advance: CGFloat, ascent: CGFloat, descent: CGFloat
    var lineHeight: CGFloat { ascent + descent }
    private var cache: [UInt16: CGGlyph] = [:]

    init(size: CGFloat) {
        font = (NSFont(name: "GohuFontUni14NFM", size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)) as CTFont
        ascent = CTFontGetAscent(font)
        descent = CTFontGetDescent(font)
        var g = CGGlyph(0), c: UniChar = 0x4D
        CTFontGetGlyphsForCharacters(font, &c, &g, 1)
        var adv = CGSize.zero
        CTFontGetAdvancesForGlyphs(font, .horizontal, &g, &adv, 1)
        advance = adv.width
    }

    func glyph(_ c: Character) -> CGGlyph {
        var u = c.utf16.first ?? 32
        if let g = cache[u] { return g }
        var g = CGGlyph(0)
        CTFontGetGlyphsForCharacters(font, &u, &g, 1)
        cache[u] = g
        return g
    }
}

/// Glyphs grouped by colour so each colour is one draw call.
private struct Batches {
    var glyphs: [[CGGlyph]], points: [[CGPoint]]
    init(_ n: Int) { glyphs = Array(repeating: [], count: n); points = Array(repeating: [], count: n) }
    mutating func add(_ bucket: Int, _ g: CGGlyph, _ p: CGPoint) { glyphs[bucket].append(g); points[bucket].append(p) }
    func draw(_ ctx: CGContext, _ font: CTFont, _ colors: [CGColor]) {
        for i in glyphs.indices where !glyphs[i].isEmpty {
            ctx.setFillColor(colors[i])
            CTFontDrawGlyphs(font, glyphs[i], points[i], glyphs[i].count, ctx)
        }
    }
}

/// Afterburner: MACH in large letters over the jet, which fills most of the
/// screen. MACH plays one text effect after another, picked at random, the
/// way Omarchy's screensaver does (see TextEffects).
final class Afterburner: ScreensaverView {
    /// Shows whichever saved screensaver is active in the library.
    static let screensaver = Screensaver(
        id: "afterburner", title: "Afterburner",
        make: { frame in
            let s = Library.load().activeSaver
            return Afterburner(frame: frame, palette: Palette.named(s.palette), logo: s.logo, title: s.title)
        },
        options: {
            let lib = Library.load()
            return [
                Menus.submenu("Use", lib.savers.map { s in
                    Menus.item(s.name, checked: s.id == lib.active) {
                        var l = Library.load(); l.active = s.id; l.save()
                    }
                }),
                Menus.submenu("Color", Palette.all.map { p in
                    Menus.item(p.title, checked: lib.activeSaver.palette == p.name) {
                        var l = Library.load()
                        if let i = l.savers.firstIndex(where: { $0.id == l.active }) { l.savers[i].palette = p.name; l.save() }
                    }
                }),
            ]
        })

    /// A logo file as dots: braille/ASCII text (like ~/.config/fastfetch/txt)
    /// or an image. nil, or anything unreadable, is the bundled jet.
    static func logo(at path: String?) -> DotArt {
        if let path {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            let art = ["txt", "text", ""].contains(url.pathExtension.lowercased())
                ? DotArt(text: (try? String(contentsOf: url, encoding: .utf8)) ?? "")
                : DotArt(image: url)
            if !art.points.isEmpty { return art }
        }
        if let url = Bundle.main.url(forResource: "jet", withExtension: "txt", subdirectory: "afterburner"),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            let art = DotArt(text: text)
            if !art.points.isEmpty { return art }
        }
        return DotArt(text: "⣿")
    }

    private let palette: Palette
    private let logo: DotArt
    private let title: [String]              // the big word, as rows of █ (MACH by default)
    private var rng = Rng(seed: UInt64(CACurrentMediaTime() * 1_000_000))
    private var clock = 0.0
    private var frameIndex = 0
    private var laidOutFor = CGSize.zero

    private var titleFont: GlyphFont!
    private var titleOrigin = CGPoint.zero   // bottom-left of MACH
    private var effects: TextEffects!
    private var effect = TextEffects.Kind.decrypt
    private var effectStart = 0.0
    private static let hold = 2.5            // seconds the finished text stays before the next effect
    private var logoOrigin = CGPoint.zero    // top-left of the logo
    private var logoSize = CGSize.zero
    private var pitch: CGFloat = 4
    private var gap: CGFloat = 0
    private var dotReveal: [Double] = []

    private struct Particle {
        var x, y, vx, vy: Double
        var born, life: Double
        var length = 0.0
    }
    private var streaks: [Particle] = []

    private let shades: [[CGColor]]          // [brightness][gradient]
    private let titleColors: [CGColor]       // [gradient * titleLevels + level]
    private static let gradientSteps = 16, brightSteps = 5, titleLevels = 8
    private let hotColors: [CGColor]

    init(frame: NSRect, palette: Palette, logo: DotArt, title: [String] = Art.mach) {
        self.palette = palette
        self.logo = logo
        self.title = title
        shades = (0..<Self.brightSteps).map { b in
            (0..<Self.gradientSteps).map { g in
                Palette.ramp(palette.accent, Double(g) / Double(Self.gradientSteps - 1))
                    .mix(RGB(255, 255, 255), Double(b) / Double(Self.brightSteps - 1) * 0.85).cg()
            }
        }
        hotColors = (0..<12).map { Palette.ramp(palette.fire, Double($0) / 11).cg() }
        titleColors = (0..<Self.gradientSteps).flatMap { g in
            (0..<Self.titleLevels).map { l in
                let v = Double(l) / Double(Self.titleLevels - 1)
                let base = Palette.ramp(palette.text ?? palette.accent, Double(g) / Double(Self.gradientSteps - 1))
                // Full colour at rest; only the top level (flashes) goes white.
                return base.mix(palette.background, (1 - v) * 0.7).mix(RGB(255, 255, 255), max(0, v - 0.86) / 0.14).cg()
            }
        }
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Layout

    private func layoutScene() {
        let W = bounds.width, H = bounds.height
        laidOutFor = bounds.size

        // The jet as big as the screen allows, centred, with MACH large across its middle.
        pitch = min(W * 0.94 / CGFloat(max(1, logo.width)), H * 0.9 / CGFloat(max(1, logo.height)))
        gap = 0
        logoSize = CGSize(width: CGFloat(logo.width) * pitch, height: CGFloat(logo.height) * pitch)
        logoOrigin = CGPoint(x: (W - logoSize.width) / 2, y: (H + logoSize.height) / 2)
        let machCols = CGFloat(title.map(\.count).max() ?? 1), machRows = CGFloat(title.count)
        let probe = GlyphFont(size: 20)
        let k = min(W * 0.4 / (machCols * probe.advance), H * 0.14 / (machRows * probe.lineHeight))
        titleFont = GlyphFont(size: max(4, (20 * k).rounded()))
        let machW = machCols * titleFont.advance, machH = machRows * titleFont.lineHeight
        // MACH tucked into the bottom-right corner, the jet alone in the middle.
        let margin = min(W, H) * 0.04
        titleOrigin = CGPoint(x: W - machW - margin, y: margin)

        // Effects can use the whole screen, measured in title characters.
        let textTop = titleOrigin.y + machH
        if effects == nil {
            effects = TextEffects(lines: title, seed: &rng)
            effect = TextEffects.Kind.allCases.randomElement(using: &rng)!
            // AFTERBURNER_EFFECT=beams (etc.) starts on a given effect, for previews.
            if let name = ProcessInfo.processInfo.environment["AFTERBURNER_EFFECT"],
               let k = TextEffects.Kind(rawValue: name) { effect = k }
        }
        effects.screen = CGRect(x: -titleOrigin.x / titleFont.advance, y: -(H - textTop) / titleFont.lineHeight,
                                width: W / titleFont.advance, height: H / titleFont.lineHeight)
        dotReveal = logo.points.map { p in 0.3 + Double(p.x) / Double(max(1, logo.width)) * 1.1 + rng.range(0, 0.25) }
    }

    // MARK: - Simulation

    override func advance(_ dt: Double) {
        if laidOutFor != bounds.size { layoutScene() }
        clock += dt
        frameIndex += 1
        let t = clock
        // Next effect once this one has finished and held for a moment.
        if t - effectStart > effects.duration(effect) + Self.hold {
            let last = effect
            while effect == last { effect = TextEffects.Kind.allCases.randomElement(using: &rng)! }
            effectStart = t
        }

        // Speed lines streaming back from the jet, fading out behind it.
        if rng.unit() < dt * 10 {
            let x = Double(logoOrigin.x + logoSize.width * rng.range(0.1, 0.45))
            let vx = -rng.range(260, 460)
            let stopX = Double(logoOrigin.x - bounds.width * 0.12)
            streaks.append(Particle(x: x, y: Double(logoOrigin.y - logoSize.height * rng.range(0.3, 0.72)),
                                    vx: vx, vy: 0, born: t, life: max(0.05, (x - stopX) / -vx),
                                    length: rng.range(18, 60)))
        }

        for i in streaks.indices { streaks[i].x += streaks[i].vx * dt }
        streaks.removeAll { t - $0.born > $0.life }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        if laidOutFor != bounds.size { layoutScene() }
        let t = clock
        ctx.setFillColor(palette.background.cg())
        ctx.fill(bounds)
        ctx.textMatrix = .identity

        drawStreaks(ctx, t: t)
        drawLogo(ctx, t: t)
        drawTitle(ctx, t: t)
    }

    private func drawStreaks(_ ctx: CGContext, t: Double) {
        ctx.setLineWidth(max(1, pitch * 0.35))
        for s in streaks {
            let age = (t - s.born) / s.life
            ctx.setStrokeColor(Palette.ramp(palette.accent, 0.4).cg(0.55 * (1 - age)))
            ctx.strokeLineSegments(between: [CGPoint(x: s.x, y: s.y), CGPoint(x: s.x + s.length, y: s.y)])
        }
    }

    private func drawLogo(_ ctx: CGContext, t: Double) {
        let bob = CGFloat(sin(t * 0.9)) * pitch * 1.2, sway = CGFloat(sin(t * 0.45)) * pitch * 1.5
        let size = pitch * 0.78
        let sweepPeriod = 5.0
        let span = Double(logo.width + logo.height) + 20
        let sweep = (t.truncatingRemainder(dividingBy: sweepPeriod) / sweepPeriod) * span - 10
        let paths = (0..<Self.brightSteps).map { _ in (0..<Self.gradientSteps).map { _ in CGMutablePath() } }

        for (i, d) in logo.points.enumerated() {
            let shown = t - dotReveal[i]
            guard shown >= 0 else { continue }
            let g = min(Self.gradientSteps - 1, d.y * Self.gradientSteps / max(1, logo.height))
            // White flash when a dot appears, then a highlight that sweeps across now and then.
            let flash = max(0, 1 - shown / 0.35)
            let dist = abs(Double(d.x) + Double(d.y) * 0.6 - sweep)
            let shine = dist < 5 ? (1 - dist / 5) * 0.8 : 0
            let b = min(Self.brightSteps - 1, Int((max(flash, shine) * Double(Self.brightSteps - 1)).rounded()))
            let x = logoOrigin.x + CGFloat(d.x) * pitch + sway
            let y = logoOrigin.y - CGFloat(d.y + 1) * pitch + bob
            paths[b][g].addRect(CGRect(x: x, y: y, width: size, height: size))
        }
        for b in paths.indices {
            for g in paths[b].indices where !paths[b][g].isEmpty {
                ctx.setFillColor(shades[b][g])
                ctx.addPath(paths[b][g])
                ctx.fillPath()
            }
        }
    }

    // MARK: - Title

    /// Smooth 0…1 value noise over character cells: two octaves, stretched
    /// wide because characters are taller than they are wide.
    private static func camoNoise(_ x: Double, _ y: Double) -> Double {
        func lattice(_ i: Int, _ j: Int, _ o: Int) -> Double {
            var h = UInt64(truncatingIfNeeded: i) &* 0x9E37_79B9 ^ UInt64(truncatingIfNeeded: j) &* 0x85EB_CA6B
                ^ UInt64(truncatingIfNeeded: o) &* 0xC2B2_AE35
            h ^= h >> 15; h = h &* 0x2C1B_3C6D; h ^= h >> 12
            return Double(h % 10_000) / 10_000
        }
        func octave(_ x: Double, _ y: Double, _ o: Int) -> Double {
            let xi = Int(floor(x)), yi = Int(floor(y))
            let fx = x - floor(x), fy = y - floor(y)
            let sx = fx * fx * (3 - 2 * fx), sy = fy * fy * (3 - 2 * fy)
            let a = lattice(xi, yi, o), b = lattice(xi + 1, yi, o), c = lattice(xi, yi + 1, o), d = lattice(xi + 1, yi + 1, o)
            return (a + (b - a) * sx) * (1 - sy) + (c + (d - c) * sx) * sy
        }
        return octave(x / 5, y / 2.5, 0) * 0.7 + octave(x / 2.2, y / 1.1, 1) * 0.3
    }

    private func drawTitle(_ ctx: CGContext, t: Double) {
        let f = titleFont!
        let textTop = titleOrigin.y + CGFloat(effects.rows) * f.lineHeight
        var batches = Batches(Self.gradientSteps * Self.titleLevels)
        var hot = Batches(hotColors.count)
        var cells: [CGRect] = []
        let screen = effects.screen
        let cols = Double(effects.cols), rows = Double(effects.rows)
        let draw = { (d: TextEffects.Draw) in
            guard d.x >= screen.minX - 1, d.x < screen.maxX, d.y >= screen.minY - 1, d.y < screen.maxY else { return }
            let p = CGPoint(x: self.titleOrigin.x + CGFloat(d.x) * f.advance,
                            y: textTop - CGFloat(d.y + 1) * f.lineHeight + f.descent)
            if d.light > 0.2 { cells.append(CGRect(x: p.x, y: p.y - f.descent, width: f.advance, height: f.lineHeight)) }
            if d.hot {
                hot.add(min(self.hotColors.count - 1, max(0, Int(d.light * Double(self.hotColors.count - 1)))), f.glyph(d.ch), p)
                return
            }
            // Gradient across the text, diagonally, wherever the character is
            // now; or camo bands, like mach-boot's strike screen.
            let g: Int
            if self.palette.camo {
                let n = Self.camoNoise(d.x.rounded(), d.y.rounded())
                let band = n < 0.38 ? 0 : n < 0.52 ? 1 : n < 0.66 ? 2 : 3
                g = band * (Self.gradientSteps - 1) / 3
            } else {
                let u = min(1, max(0, d.x / cols * 0.75 + d.y / rows * 0.25))
                g = Int(u * Double(Self.gradientSteps - 1))
            }
            let level = min(Self.titleLevels - 1, max(0, Int((d.light * Double(Self.titleLevels - 1)).rounded())))
            batches.add(g * Self.titleLevels + level, f.glyph(d.ch), p)
        }
        let local = t - effectStart
        if local < effects.duration(effect) { effects.frame(effect, t: local, emit: draw) } else { effects.rested(emit: draw) }
        // MACH sits on the jet: clear a cell behind each character so the
        // jet's dots don't show through the letters.
        ctx.setFillColor(palette.background.cg(0.9))
        ctx.fill(cells)
        hot.draw(ctx, f.font, hotColors)
        batches.draw(ctx, f.font, titleColors)
    }
}
