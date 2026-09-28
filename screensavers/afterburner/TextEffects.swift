import CoreGraphics
import Foundation

/// MACH animated the way Omarchy's screensaver animates its logo: it runs
/// terminaltexteffects (via ttfx) with `--random-effect` in a loop, so each
/// pass brings the text in with a different effect. These are Swift takes on
/// TTE's effects, driven by time instead of frame steps.
///
/// Coordinates are in text cells: x right, y down, the text at 0..<cols,
/// 0..<rows. `screen` is the whole screen in the same units, so characters can
/// fly in from anywhere, like TTE's full-terminal canvas.
struct TextEffects {
    enum Kind: String, CaseIterable {
        case decrypt, beams, rain, slide, expand, scattered, middleOut, print,
             unstable, burn, waves, matrix, spray, crumble, sweep
    }

    /// One character to draw. `light` is 0 (background) to 1 (white); the text
    /// rests at `rest`. `hot` draws it in the fire colours instead.
    struct Draw {
        var x, y: Double
        var ch: Character
        var light: Double
        var hot = false
    }

    struct Cell {
        let x, y: Int
        let ch: Character
        let order: Int              // reading order
        let r: [Double]             // per-character random numbers
    }

    static let rest = 0.85
    let cells: [Cell]
    let cols: Int, rows: Int
    var screen = CGRect(x: -20, y: -10, width: 80, height: 40)

    init(lines: [String], seed: inout Rng) {
        var cells: [Cell] = []
        for (y, line) in lines.enumerated() {
            for (x, ch) in line.enumerated() where ch != " " {
                cells.append(Cell(x: x, y: y, ch: ch, order: cells.count,
                                  r: (0..<4).map { _ in seed.unit() }))
            }
        }
        self.cells = cells
        rows = lines.count
        cols = lines.map(\.count).max() ?? 0
    }

    // MARK: helpers

    private static func clamp(_ u: Double) -> Double { min(1, max(0, u)) }
    private static func outCubic(_ u: Double) -> Double { let v = 1 - clamp(u); return 1 - v * v * v }
    private static func inOutCubic(_ u: Double) -> Double {
        let v = clamp(u)
        return v < 0.5 ? 4 * v * v * v : 1 - pow(-2 * v + 2, 3) / 2
    }
    private static func lerp(_ a: Double, _ b: Double, _ u: Double) -> Double { a + (b - a) * u }

    /// White flash on arrival fading to the resting colour.
    private static func settle(_ age: Double, fade: Double = 0.5) -> Double {
        rest + (1 - rest) * max(0, 1 - age / fade)
    }

    /// Stable pseudo-random 0..<1, for flicker that changes every `slot`.
    private static func hash(_ a: Int, _ b: Int, _ c: Int = 0) -> Double {
        var h = UInt64(truncatingIfNeeded: a) &* 0x9E37_79B9 ^ UInt64(truncatingIfNeeded: b) &* 0x85EB_CA6B
            ^ UInt64(truncatingIfNeeded: c) &* 0xC2B2_AE35
        h ^= h >> 15; h = h &* 0x2C1B_3C6D; h ^= h >> 12
        return Double(h % 10_000) / 10_000
    }

    private static let symbols = Array("!#$%&*+-/<=>?@[]^_{|}~0123456789ABCDEFXYZ")
    private static func symbol(_ i: Int, _ t: Double, rate: Double = 18) -> Character {
        symbols[Int(hash(i, Int(t * rate)) * Double(symbols.count))]
    }

    // MARK: effects

    func duration(_ k: Kind) -> Double {
        switch k {
        case .decrypt: 3.3
        case .beams: 2.8
        case .rain: 2.6
        case .slide: 2.1
        case .expand: 1.9
        case .scattered: 2.3
        case .middleOut: 2.1
        case .print: Double(rows * cols) / 90 + 0.7
        case .unstable: 3.2
        case .burn: 3.0
        case .waves: 2.7
        case .matrix: 3.6
        case .spray: 2.4
        case .crumble: 3.6
        case .sweep: 2.8
        }
    }

    /// Everything to draw `t` seconds into an effect.
    func frame(_ k: Kind, t: Double, emit: (Draw) -> Void) {
        let cx = Double(cols) / 2, cy = Double(rows) / 2
        let n = Double(max(1, cells.count))
        switch k {

        case .decrypt:
            // Typed in as noise, then each character cracks at its own moment.
            for c in cells {
                let appear = Double(c.order) / n * 0.7
                guard t >= appear else { continue }
                let lock = 1.0 + c.r[0] * 2.0
                if t < lock {
                    emit(Draw(x: Double(c.x), y: Double(c.y), ch: Self.symbol(c.order, t), light: 0.35 + 0.2 * c.r[1]))
                } else {
                    emit(Draw(x: Double(c.x), y: Double(c.y), ch: c.ch, light: Self.settle(t - lock)))
                }
            }

        case .beams:
            // A beam runs along each row (alternating directions), lighting the text as it passes.
            let speed = 55.0
            for y in 0..<rows {
                let delay = Self.hash(y, 7) * 1.1, dir = y % 2 == 0 ? 1.0 : -1.0
                let travel = (t - delay) * speed
                let head = dir > 0 ? screen.minX + travel : screen.maxX - travel
                for k in 0..<14 where travel > 0 {
                    let x = head - dir * Double(k)
                    guard x >= screen.minX, x < screen.maxX else { continue }
                    emit(Draw(x: x.rounded(), y: Double(y), ch: k == 0 ? "█" : k < 5 ? "▓" : "░",
                              light: 1 - Double(k) / 16))
                }
            }
            for c in cells {
                let delay = Self.hash(c.y, 7) * 1.1, dir = c.y % 2 == 0 ? 1.0 : -1.0
                let reach = dir > 0 ? Double(c.x) - screen.minX : screen.maxX - Double(c.x)
                let lit = delay + reach / speed
                guard t >= lit else { continue }
                emit(Draw(x: Double(c.x), y: Double(c.y), ch: c.ch, light: Self.settle(t - lit, fade: 0.8)))
            }

        case .rain:
            for c in cells {
                let delay = c.r[0] * 1.5, fall = 0.35 + c.r[1] * 0.35
                let u = (t - delay) / fall
                guard u >= 0 else { continue }
                if u < 1 {
                    let y0 = screen.minY - 1 - c.r[2] * 4
                    emit(Draw(x: Double(c.x), y: Self.lerp(y0, Double(c.y), u * u), ch: c.r[3] < 0.5 ? "|" : ":", light: 0.6))
                } else {
                    emit(Draw(x: Double(c.x), y: Double(c.y), ch: c.ch, light: Self.settle(t - delay - fall)))
                }
            }

        case .slide:
            for c in cells {
                let dir = c.y % 2 == 0 ? 1.0 : -1.0
                let delay = Double(c.y) * 0.12 + (dir > 0 ? Double(cols - c.x) : Double(c.x)) * 0.006
                let u = (t - delay) / 0.9
                guard u >= 0 else { continue }
                let from = dir > 0 ? screen.minX - Double(cols - c.x) : screen.maxX + Double(c.x)
                let x = Self.lerp(from, Double(c.x), Self.outCubic(u))
                emit(Draw(x: x, y: Double(c.y), ch: c.ch, light: u < 1 ? 0.7 : Self.settle(t - delay - 0.9)))
            }

        case .expand:
            for c in cells {
                let delay = c.r[0] * 0.25
                let u = (t - delay) / 1.2
                guard u >= 0 else { continue }
                let e = Self.outCubic(u)
                emit(Draw(x: Self.lerp(cx, Double(c.x), e), y: Self.lerp(cy, Double(c.y), e), ch: c.ch,
                          light: u < 1 ? 0.5 + 0.4 * e : Self.settle(t - delay - 1.2)))
            }

        case .scattered:
            for c in cells {
                let delay = c.r[2] * 0.4
                let u = (t - delay) / 1.4
                let x0 = screen.minX + c.r[0] * screen.width, y0 = screen.minY + c.r[1] * screen.height
                let e = Self.inOutCubic(u)
                emit(Draw(x: Self.lerp(x0, Double(c.x), e), y: Self.lerp(y0, Double(c.y), e), ch: c.ch,
                          light: u < 1 ? 0.55 : Self.settle(t - delay - 1.4)))
            }

        case .middleOut:
            // Out from the middle along one line, then open up to full height.
            for c in cells {
                let appear = abs(Double(c.x) + 0.5 - cx) / cx * 0.6
                guard t >= appear else { continue }
                let u = (t - 0.9) / 0.6
                let y = Self.lerp(cy - 0.5, Double(c.y), Self.outCubic(u))
                emit(Draw(x: Double(c.x), y: y, ch: c.ch, light: u < 1 ? 0.95 : Self.settle(t - 1.5)))
            }

        case .print:
            // Typed row by row behind a print head.
            let rate = 90.0
            let head = t * rate
            for c in cells {
                let at = Double(c.y * cols + c.x)
                guard head >= at else { continue }
                emit(Draw(x: Double(c.x), y: Double(c.y), ch: c.ch, light: Self.settle((head - at) / rate, fade: 0.4)))
            }
            let h = Int(head)
            if h < rows * cols {
                emit(Draw(x: Double(h % cols), y: Double(h / cols), ch: "█", light: 1))
            }

        case .unstable:
            // Shakes apart, scatters, then snaps back together.
            for c in cells {
                var x = Double(c.x), y = Double(c.y), light = Self.rest, ch = c.ch
                let xr = screen.minX + c.r[0] * screen.width, yr = screen.minY + c.r[1] * screen.height
                if t < 1.3 {
                    let amp = t / 1.3 * 0.9, slot = Int(t * 20)
                    x += (Self.hash(c.order, slot, 1) - 0.5) * amp
                    y += (Self.hash(c.order, slot, 2) - 0.5) * amp * 0.5
                } else if t < 2.1 {
                    let e = Self.outCubic((t - 1.3) / 0.4)
                    x = Self.lerp(x, xr, e); y = Self.lerp(y, yr, e)
                    light = 0.5; ch = Self.symbol(c.order, t, rate: 8)
                } else {
                    let u = (t - 2.1 - c.r[2] * 0.2) / 0.8
                    let e = Self.inOutCubic(u)
                    x = Self.lerp(xr, x, e); y = Self.lerp(yr, y, e)
                    light = u < 1 ? 0.6 : Self.settle(t - 2.1 - c.r[2] * 0.2 - 0.8)
                }
                emit(Draw(x: x, y: y, ch: ch, light: light))
            }

        case .burn:
            // Shown dim, then fire spreads from one spot and leaves the text lit.
            let ox = Self.hash(3, 3) * Double(cols), oy = Double(rows)
            for c in cells {
                let d = hypot(Double(c.x) - ox, (Double(c.y) - oy) * 2)
                let ignite = 0.3 + d / 22 + c.r[0] * 0.3
                if t < ignite {
                    emit(Draw(x: Double(c.x), y: Double(c.y), ch: c.ch, light: 0.25))
                } else if t < ignite + 0.5 {
                    let heat = 1 - (t - ignite) / 0.5
                    let flames: [Character] = ["^", "*", "'", "\"", "."]
                    emit(Draw(x: Double(c.x), y: Double(c.y), ch: flames[Int(Self.hash(c.order, Int(t * 20)) * 5)],
                              light: 0.4 + 0.6 * heat, hot: true))
                    emit(Draw(x: Double(c.x), y: Double(c.y) - (t - ignite) * 5 - 1, ch: ".", light: 0.3 * heat, hot: true))
                } else {
                    emit(Draw(x: Double(c.x), y: Double(c.y), ch: c.ch, light: Self.settle(t - ignite - 0.5)))
                }
            }

        case .waves:
            let wave = Array("▁▂▃▄▅▆▇█▇▆▅▄▃▂▁")
            for c in cells {
                let start = Double(c.x) * 0.035 + Double(c.y) * 0.03
                let u = (t - start) / 0.7
                guard u >= 0 else { continue }
                if u < 1 {
                    let i = min(wave.count - 1, Int(u * Double(wave.count)))
                    emit(Draw(x: Double(c.x), y: Double(c.y), ch: wave[i], light: 0.6 + 0.4 * sin(u * .pi)))
                } else {
                    emit(Draw(x: Double(c.x), y: Double(c.y), ch: c.ch, light: Self.settle(t - start - 0.7)))
                }
            }

        case .matrix:
            // Streams of code rain; each character locks in once a stream has passed it.
            let speed = 20.0, trail = 9
            let top = screen.minY, stop = 3.0
            for x in 0..<cols {
                let delay = Self.hash(x, 5) * 1.3
                let head = top + (t - delay) * speed
                guard t > delay, t < stop + Double(trail) / speed else { continue }
                for k in 0..<trail {
                    let y = (head - Double(k)).rounded()
                    guard y >= top, y < Double(rows) + 3, t - Double(k) / speed < stop else { continue }
                    emit(Draw(x: Double(x), y: y, ch: Self.symbol(x * 97 + Int(y), t, rate: 12),
                              light: k == 0 ? 1 : 0.65 - Double(k) / Double(trail) * 0.5))
                }
            }
            for c in cells {
                let passed = Self.hash(c.x, 5) * 1.3 + (Double(c.y) - top) / speed
                let lock = max(passed, 1.1 + c.r[0] * 1.6)
                guard t >= passed else { continue }
                if t < lock {
                    emit(Draw(x: Double(c.x), y: Double(c.y), ch: Self.symbol(c.order, t, rate: 10), light: 0.45))
                } else {
                    emit(Draw(x: Double(c.x), y: Double(c.y), ch: c.ch, light: Self.settle(t - lock)))
                }
            }

        case .spray:
            // Sprayed in from the bottom right corner of the screen.
            let ox = screen.maxX - 2, oy = screen.maxY - 2
            for c in cells {
                let delay = c.r[0] * 1.0
                let u = (t - delay) / 0.75
                guard u >= 0 else { continue }
                let e = Self.outCubic(u)
                let arc = sin(e * .pi) * (c.r[1] - 0.5) * 8
                emit(Draw(x: Self.lerp(ox, Double(c.x), e), y: Self.lerp(oy, Double(c.y), e) + arc, ch: c.ch,
                          light: u < 1 ? 0.8 : Self.settle(t - delay - 0.75)))
            }

        case .crumble:
            // Crumbles to the bottom of the screen, then gets pulled back up.
            let floor = screen.maxY - 1
            for c in cells {
                let drop = 0.3 + c.r[0] * 0.9, fall = 0.7
                let back = 2.2 + c.r[1] * 0.3, rise = 0.8
                if t < drop {
                    emit(Draw(x: Double(c.x), y: Double(c.y), ch: c.ch, light: Self.rest - 0.25 * Self.hash(c.order, Int(t * 15))))
                } else if t < back {
                    let u = Self.clamp((t - drop) / fall)
                    emit(Draw(x: Double(c.x), y: Self.lerp(Double(c.y), floor, u * u), ch: u < 1 ? c.ch : ".", light: 0.4))
                } else {
                    let u = (t - back) / rise
                    emit(Draw(x: Double(c.x), y: Self.lerp(floor, Double(c.y), Self.inOutCubic(u)), ch: c.ch,
                              light: u < 1 ? 0.6 : Self.settle(t - back - rise)))
                }
            }

        case .sweep:
            // One sweep lays the text down dim, a second one back lights it up.
            let speed = 45.0
            let s1 = screen.minX + t * speed, s2 = screen.maxX - (t - 1.0) * speed
            for y in 0..<rows {
                if s1 < screen.maxX { emit(Draw(x: s1.rounded(), y: Double(y), ch: "▌", light: 0.9)) }
                if t > 1.0, s2 > screen.minX { emit(Draw(x: s2.rounded(), y: Double(y), ch: "▐", light: 1)) }
            }
            for c in cells where Double(c.x) <= s1 {
                if t > 1.0, Double(c.x) >= s2 {
                    let lit = 1.0 + (screen.maxX - Double(c.x)) / speed
                    emit(Draw(x: Double(c.x), y: Double(c.y), ch: c.ch, light: Self.settle(t - lit)))
                } else {
                    emit(Draw(x: Double(c.x), y: Double(c.y), ch: c.ch, light: 0.3))
                }
            }
        }
    }

    /// The finished text, held between effects.
    func rested(emit: (Draw) -> Void) {
        for c in cells { emit(Draw(x: Double(c.x), y: Double(c.y), ch: c.ch, light: Self.rest)) }
    }
}
