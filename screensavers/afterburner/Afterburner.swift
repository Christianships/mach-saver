import AppKit
import QuartzCore
import UniformTypeIdentifiers

struct Rng {
    private var s: UInt64
    init(seed: UInt64) { s = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed }
    mutating func next() -> UInt64 { s ^= s << 13; s ^= s >> 7; s ^= s << 17; return s }
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
    mutating func int(_ r: ClosedRange<Int>) -> Int { r.lowerBound + Int(next() % UInt64(r.count)) }
    mutating func range(_ a: Double, _ b: Double) -> Double { a + (b - a) * unit() }
}

/// Classic Doom-style fire: heat spreads up one row per frame, drifting sideways and cooling.
struct Fire {
    static let maxHeat = 36
    let cols: Int, rows: Int
    private(set) var heat: [UInt8]
    private(set) var drift: [Int8]
    private let decayMax: Int

    init(cols: Int, rows: Int, flameRows: Int) {
        self.cols = cols
        self.rows = rows
        heat = [UInt8](repeating: 0, count: cols * rows)
        drift = [Int8](repeating: 0, count: cols * rows)
        decayMax = max(1, Int((2 * Double(Self.maxHeat) * 0.8 / Double(max(1, flameRows))).rounded()))
    }

    mutating func step(wind: Double, time: Double, rng: inout Rng) {
        // Uneven source so the flames form peaks instead of a flat wall.
        for x in 0..<cols {
            let n = sin(Double(x) * 0.09 + time * 0.7) * 0.5 + sin(Double(x) * 0.031 - time * 0.4) * 0.5
            let base = Double(Self.maxHeat) * (0.8 + 0.2 * n) - Double(rng.int(0...4))
            heat[x] = UInt8(max(0, min(Double(Self.maxHeat), base)))
        }
        // Top down, so each row reads last frame's row below it.
        for y in stride(from: rows - 1, through: 1, by: -1) {
            let row = y * cols, below = (y - 1) * cols
            for x in 0..<cols {
                let h = Int(heat[below + x])
                heat[row + x] = UInt8(max(0, h - decayMax - 1))
            }
            for x in 0..<cols {
                let h = Int(heat[below + x])
                guard h > 0 else { continue }
                var shift = rng.int(-1...1)
                if rng.unit() < abs(wind) * 0.6 { shift += wind > 0 ? 1 : -1 }
                let dx = min(cols - 1, max(0, x + shift))
                let v = UInt8(max(0, h - rng.int(0...decayMax)))
                if v > heat[row + dx] {
                    heat[row + dx] = v
                    drift[row + dx] = Int8(shift.signum())
                }
            }
        }
    }
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

private struct TitleCell {
    let col: Int, row: Int
}

/// Afterburner: MACH drawn in animated ASCII patterns next to the jet, above a
/// field of ASCII fire with embers blowing in the wind.
final class Afterburner: ScreensaverView {
    static let screensaver = Screensaver(
        id: "afterburner", title: "Afterburner",
        make: { frame in Afterburner(frame: frame, palette: Palette.named(Settings.palette), logo: Settings.loadLogo()) },
        options: {
            let logoName = Settings.logoPath.map { ($0 as NSString).lastPathComponent } ?? "jet.txt (built in)"
            return [
                Menus.submenu("Fire Color", Palette.all.map { p in
                    Menus.item(p.title, checked: Settings.palette == p.name) { Settings.palette = p.name }
                }),
                Menus.submenu("Logo", [
                    Menus.disabled(logoName),
                    Menus.item("Choose Logo File…") { Settings.chooseLogo() },
                    Menus.item("Use Built-in Jet", checked: Settings.logoPath == nil) { Settings.logoPath = nil },
                ]),
            ]
        })

    enum Settings {
        private static let d = UserDefaults.standard

        static var palette: String {
            get { d.string(forKey: "afterburner.palette") ?? Palette.purple.name }
            set { d.set(newValue, forKey: "afterburner.palette") }
        }

        /// A braille/ASCII logo file, like the ones in ~/.config/fastfetch/txt. nil uses the bundled jet.
        static var logoPath: String? {
            get { d.string(forKey: "afterburner.logoPath") }
            set { d.set(newValue, forKey: "afterburner.logoPath") }
        }

        static func loadLogo() -> DotArt {
            let bundled = Bundle.main.url(forResource: "jet", withExtension: "txt", subdirectory: "afterburner")
            for url in [logoPath.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }, bundled] {
                if let url, let text = try? String(contentsOf: url, encoding: .utf8) {
                    let art = DotArt(text: text)
                    if !art.points.isEmpty { return art }
                }
            }
            return DotArt(text: "⣿")
        }

        static func chooseLogo() {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.plainText, .text]
            panel.directoryURL = URL(fileURLWithPath: ("~/.config/fastfetch/txt" as NSString).expandingTildeInPath)
            NSApp.activate(ignoringOtherApps: true)
            if panel.runModal() == .OK, let url = panel.url { logoPath = url.path }
        }
    }

    private let palette: Palette
    private let logo: DotArt
    private var rng = Rng(seed: UInt64(CACurrentMediaTime() * 1_000_000))
    private var clock = 0.0
    private var frameIndex = 0
    private var laidOutFor = CGSize.zero

    private var fireFont: GlyphFont!, titleFont: GlyphFont!
    private var fire = Fire(cols: 1, rows: 1, flameRows: 1)
    private var flameTop: CGFloat = 0
    private var titleOrigin = CGPoint.zero   // bottom-left of MACH
    private var titleCell = CGSize.zero      // one character of the pattern grid
    private var titleCells: [TitleCell] = []
    private var logoOrigin = CGPoint.zero    // top-left of the logo
    private var logoSize = CGSize.zero
    private var pitch: CGFloat = 4
    private var gap: CGFloat = 0
    private var titleReveal: [Double] = []
    private var dotReveal: [Double] = []

    private struct Particle {
        var x, y, vx, vy: Double
        var born, life: Double
        var glyph: Character = "."
        var phase = 0.0
        var length = 0.0
    }
    private var embers: [Particle] = [], streaks: [Particle] = []

    private let fireColors: [CGColor]
    private let shades: [[CGColor]]          // [brightness][gradient]
    private let titleColors: [CGColor]       // [gradient * titleLevels + level]
    private static let gradientSteps = 16, brightSteps = 5, titleLevels = 8
    private var patternFont: GlyphFont!

    init(frame: NSRect, palette: Palette, logo: DotArt) {
        self.palette = palette
        self.logo = logo
        fireColors = (0..<24).map { Palette.ramp(palette.fire, Double($0) / 23).cg() }
        shades = (0..<Self.brightSteps).map { b in
            (0..<Self.gradientSteps).map { g in
                Palette.ramp(palette.accent, Double(g) / Double(Self.gradientSteps - 1))
                    .mix(RGB(255, 255, 255), Double(b) / Double(Self.brightSteps - 1) * 0.85).cg()
            }
        }
        titleColors = (0..<Self.gradientSteps).flatMap { g in
            (0..<Self.titleLevels).map { l in
                let v = Double(l) / Double(Self.titleLevels - 1)
                let base = Palette.ramp(palette.accent, Double(g) / Double(Self.gradientSteps - 1))
                return base.mix(palette.background, (1 - v) * 0.7).mix(RGB(255, 255, 255), max(0, v - 0.7) * 1.5).cg()
            }
        }
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Layout

    private func layoutScene() {
        let W = bounds.width, H = bounds.height
        laidOutFor = bounds.size

        fireFont = GlyphFont(size: max(10, (H / 64).rounded()))
        let cols = Int(W / fireFont.advance) + 1, rows = Int(H / fireFont.lineHeight) + 1
        let flameRows = max(6, Int(Double(rows) * 0.3))
        fire = Fire(cols: cols, rows: rows, flameRows: flameRows)
        flameTop = CGFloat(flameRows) * fireFont.lineHeight

        // Size MACH and the logo together so the pair fills ~3/4 of the width.
        func measure(_ font: GlyphFont) -> (machW: CGFloat, machH: CGFloat, pitch: CGFloat, gap: CGFloat) {
            let machW = CGFloat(Art.mach[0].count) * font.advance
            let machH = CGFloat(Art.mach.count) * font.lineHeight
            var p = machH * 1.9 / CGFloat(max(1, logo.height))
            p = min(p, machW * 1.4 / CGFloat(max(1, logo.width)))
            return (machW, machH, p, font.advance * 3)
        }
        let probe = measure(GlyphFont(size: 20))
        let probeW = probe.machW + probe.gap + CGFloat(logo.width) * probe.pitch
        let probeH = max(probe.machH, CGFloat(logo.height) * probe.pitch)
        let scale = min(W * 0.74 / probeW, H * 0.4 / probeH)
        titleFont = GlyphFont(size: (20 * scale).rounded())
        let m = measure(titleFont)
        pitch = m.pitch
        gap = m.gap
        logoSize = CGSize(width: CGFloat(logo.width) * pitch, height: CGFloat(logo.height) * pitch)
        let centerY = (flameTop + H) / 2 + H * 0.03
        let x0 = (W - (m.machW + gap + logoSize.width)) / 2
        titleOrigin = CGPoint(x: x0, y: centerY - m.machH / 2)
        logoOrigin = CGPoint(x: x0 + m.machW + gap, y: centerY + logoSize.height / 2)

        // Each figlet character becomes a 2x2 block of smaller characters,
        // so the patterns have enough resolution to read.
        titleCell = CGSize(width: titleFont.advance / 2, height: titleFont.lineHeight / 2)
        patternFont = GlyphFont(size: (CTFontGetSize(titleFont.font) / 2).rounded())
        titleCells = []
        for (r, line) in Art.mach.enumerated() {
            // Only the █ strokes; the figlet's outline just muddies the letters here.
            for (c, char) in line.enumerated() where char == "█" {
                for dy in 0..<2 { for dx in 0..<2 {
                    titleCells.append(TitleCell(col: c * 2 + dx, row: r * 2 + dy))
                }}
            }
        }
        titleReveal = titleCells.map { _ in rng.range(0.15, 1.4) }
        dotReveal = logo.points.map { p in 0.3 + Double(p.x) / Double(max(1, logo.width)) * 1.1 + rng.range(0, 0.25) }
    }

    // MARK: - Simulation

    /// Gusts that lean the flames and push the embers.
    private func wind(_ t: Double) -> Double {
        0.65 * sin(t * 0.9) + 0.25 * sin(t * 2.1 + 1.3) + 0.1 * sin(t * 4.7 + 0.4)
    }

    override func advance(_ dt: Double) {
        if laidOutFor != bounds.size { layoutScene() }
        clock += dt
        frameIndex += 1
        let t = clock, w = wind(t)
        fire.step(wind: w, time: t, rng: &rng)

        // Embers off the top of the flames.
        for _ in 0..<Int(rng.range(0, 2.2)) {
            embers.append(Particle(x: rng.range(0, Double(bounds.width)), y: Double(flameTop) * rng.range(0.55, 1),
                                   vx: rng.range(-12, 12), vy: rng.range(35, 95), born: t, life: rng.range(1.5, 3.5),
                                   glyph: [".", "'", "*", "."][rng.int(0...3)], phase: rng.range(0, 6)))
        }
        // Speed lines behind the jet, gone before they reach MACH.
        if rng.unit() < dt * 10 {
            let x = Double(logoOrigin.x + logoSize.width * rng.range(0.1, 0.45))
            let vx = -rng.range(260, 460)
            let stopX = Double(logoOrigin.x - gap * 0.7)
            streaks.append(Particle(x: x, y: Double(logoOrigin.y - logoSize.height * rng.range(0.3, 0.72)),
                                    vx: vx, vy: 0, born: t, life: max(0.05, (x - stopX) / -vx),
                                    length: rng.range(18, 60)))
        }

        for i in embers.indices {
            embers[i].x += (embers[i].vx + w * 45 + sin(t * 3 + embers[i].phase) * 10) * dt
            embers[i].y += embers[i].vy * dt
        }
        for i in streaks.indices { streaks[i].x += streaks[i].vx * dt }
        embers.removeAll { t - $0.born > $0.life }
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

        drawFire(ctx)
        drawParticles(ctx, embers, font: fireFont, t: t) { age in Palette.ramp(self.palette.fire, 1 - age * 0.7) }
        drawStreaks(ctx, t: t)
        drawLogo(ctx, t: t)
        drawTitle(ctx, t: t)
    }

    private func fireChar(_ heat: Double, drift: Int8, _ x: Int, _ y: Int) -> Character {
        var h = UInt64(x) &* 73_856_093 ^ UInt64(y) &* 19_349_663 ^ UInt64(frameIndex / 2) &* 83_492_791
        h ^= h >> 13
        let pick = Int(h % 5)
        switch heat {
        case ..<0.12: return pick < 3 ? " " : "."
        case ..<0.25: return [".", ":", "'", ".", ":"][pick]
        case ..<0.42: return drift > 0 ? "/" : drift < 0 ? "\\" : [":", "+", ".", ":", "|"][pick]
        case ..<0.58: return drift > 0 ? "/" : drift < 0 ? "\\" : ["+", "=", "*", "+", "="][pick]
        case ..<0.72: return ["*", "=", "S", "+", "L"][pick]
        case ..<0.86: return ["S", "D", "R", "L", "W"][pick]
        default: return ["#", "W", "#", "D", "#"][pick]
        }
    }

    private func drawFire(_ ctx: CGContext) {
        let f = fireFont!, cw = f.advance, ch = f.lineHeight
        var batches = Batches(fireColors.count)
        for y in 0..<fire.rows {
            for x in 0..<fire.cols {
                let i = y * fire.cols + x
                let h = fire.heat[i]
                guard h > 0 else { continue }
                let heat = Double(h) / Double(Fire.maxHeat)
                let c = fireChar(heat, drift: fire.drift[i], x, y)
                guard c != " " else { continue }
                let bucket = min(fireColors.count - 1, Int(heat * Double(fireColors.count - 1) + 0.5))
                batches.add(bucket, f.glyph(c), CGPoint(x: CGFloat(x) * cw, y: CGFloat(y) * ch + f.descent))
            }
        }
        batches.draw(ctx, f.font, fireColors)
    }

    private func drawParticles(_ ctx: CGContext, _ items: [Particle], font: GlyphFont, t: Double, color: (Double) -> RGB) {
        for p in items {
            let age = (t - p.born) / p.life
            let alpha = min(1, (1 - age) * 1.6)
            ctx.setFillColor(color(age).cg(alpha))
            var g = font.glyph(p.glyph)
            var pt = CGPoint(x: p.x, y: p.y)
            CTFontDrawGlyphs(font.font, &g, &pt, 1, ctx)
        }
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

    // MARK: - Title patterns

    /// Patterns MACH cycles through. `value` is brightness 0...1 at a grid cell;
    /// `glyph` picks the character. Coordinates: x 0..<70 left to right, y 0..<12 top down.
    private struct Pattern {
        var value: (_ x: Double, _ y: Double, _ t: Double) -> Double
        var glyph: (_ x: Int, _ y: Int, _ t: Double, _ v: Double) -> Character = { _, _, _, v in rampChar(v) }
    }

    private static let ramp: [Character] = [".", ":", "-", "=", "+", "*", "x", "#", "%", "@"]
    private static func rampChar(_ v: Double) -> Character { ramp[min(ramp.count - 1, max(0, Int(v * Double(ramp.count))))] }

    private static func hash(_ a: Int, _ b: Int, _ c: Int = 0) -> Double {
        var h = UInt64(truncatingIfNeeded: a) &* 0x9E37_79B9 ^ UInt64(truncatingIfNeeded: b) &* 0x85EB_CA6B ^ UInt64(truncatingIfNeeded: c) &* 0xC2B2_AE35
        h ^= h >> 15; h = h &* 0x2C1B_3C6D; h ^= h >> 12
        return Double(h % 10_000) / 10_000
    }

    private static let patterns: [Pattern] = [
        // Wave rolling left to right.
        Pattern(value: { x, y, t in 0.5 + 0.5 * sin(x * 0.28 - t * 3.5 + y * 0.45) }),
        // The word itself, typed out in rows that scroll in alternating directions.
        Pattern(value: { x, y, t in 0.55 + 0.45 * sin(x * 0.18 - t * 2.2) },
                glyph: { x, y, t, _ in
                    let word = Array("MACH")
                    let dir = y % 2 == 0 ? 1 : -1
                    return word[((x + dir * Int(t * 9) + y * 2) % word.count + word.count) % word.count]
                }),
        // Ripple out from the middle.
        Pattern(value: { x, y, t in
            let d = hypot(x - 35, (y - 5.5) * 2.4)
            return 0.5 + 0.5 * sin(d * 0.42 - t * 5)
        }),
        // Digital rain falling down each column.
        Pattern(value: { x, y, t in
            let col = Int(x)
            let speed = 7 + hash(col, 1) * 8
            let head = (t * speed + hash(col, 2) * 30).truncatingRemainder(dividingBy: 22) - 5
            let d = head - y
            return d >= 0 && d < 7 ? 1 - d / 7 : 0
        }, glyph: { x, y, t, v in
            let set = Array(v < 0.5 ? "+=:-" : "01MACH<>/\\|")
            return set[Int(hash(x, y, Int(t * 12)) * Double(set.count))]
        }),
        // Plasma.
        Pattern(value: { x, y, t in
            let a = sin(x * 0.16 + t) + sin(y * 0.55 - t * 1.3)
            let b = sin((x + y * 2) * 0.11 + t * 0.7) + sin(hypot(x - 35, y * 3 - 16) * 0.22 - t * 2)
            return 0.5 + (a + b) / 8
        }),
        // Diagonal scan with a trail, over flickering bits.
        Pattern(value: { x, y, t in
            let head = (t / 2.4).truncatingRemainder(dividingBy: 1) * 110 - 15
            let d = head - (x + y * 2)
            return d >= 0 ? max(0.12, 1 - d / 26) : 0.12
        }, glyph: { x, y, t, v in
            v > 0.85 ? "@" : hash(x, y, Int(t * 8)) > 0.5 ? "1" : "0"
        }),
    ]

    private func drawTitle(_ ctx: CGContext, t: Double) {
        let f = patternFont!
        let rows = Art.mach.count * 2
        let period = 7.0, fade = 1.2
        let k = Int(t / period)
        let a = Self.patterns[k % Self.patterns.count], b = Self.patterns[(k + 1) % Self.patterns.count]
        let blend = max(0, (t - Double(k) * period - (period - fade)) / fade)
        let scramble: [Character] = ["!", "<", ">", "-", "_", "/", "\\", "[", "]", "=", "+", "*", "^", "?", "#"]
        var batches = Batches(Self.gradientSteps * Self.titleLevels)

        for (i, cell) in titleCells.enumerated() {
            let x = titleOrigin.x + CGFloat(cell.col) * titleCell.width
            let y = titleOrigin.y + CGFloat(rows - 1 - cell.row) * titleCell.height + f.descent
            let g = min(Self.gradientSteps - 1, cell.row * Self.gradientSteps / rows)
            let shown = t - titleReveal[i]
            if shown < 0 {
                // Decrypt-in: random symbols until each character lands.
                let s = scramble[(cell.col * 31 + cell.row * 17 + Int(t / 0.06)) % scramble.count]
                batches.add(g * Self.titleLevels + 1, f.glyph(s), CGPoint(x: x, y: y))
                continue
            }
            let fx = Double(cell.col), fy = Double(cell.row)
            var v = a.value(fx, fy, t) * (1 - blend) + b.value(fx, fy, t) * blend
            // Never below mid brightness, so MACH stays readable in every pattern.
            v = 0.4 + max(v, 1 - shown / 0.3) * 0.6
            let glyph = (blend < 0.5 ? a : b).glyph(cell.col, cell.row, t, v)
            let level = min(Self.titleLevels - 1, Int(v * Double(Self.titleLevels)))
            batches.add(g * Self.titleLevels + level, f.glyph(glyph), CGPoint(x: x, y: y))
        }
        batches.draw(ctx, f.font, titleColors)
    }
}
