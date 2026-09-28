import Foundation
import CoreGraphics
import simd

/// A low-poly fighter (F-22-like) rendered as shaded ASCII. MACH is painted on
/// the top of the wings in wing space, so the letters sit in the wing's plane
/// and follow the jet's perspective as it banks.
///
/// Model space: x forward (nose at +10), y to port (left wing), z up.
/// Screen space: X right, Y up, Z towards the viewer.
struct Jet3D {
    enum Part: UInt8 { case none, hull, canopy, wing, tail, nozzle, intake }

    private struct Tri {
        var m: [SIMD3<Double>]          // model-space corners
        var n: [SIMD3<Double>]          // model-space normals (equal for flat panels)
        var part: Part
        var wingTop = false             // MACH and panel lines live here
    }

    private var tris: [Tri] = []

    // MARK: wing + letters

    /// Port wing planform (y > 0); the starboard one is its mirror.
    static let rootY = 1.5, tipY = 7.6
    static let rootLE = 2.0, tipLE = -4.6, rootTE = -7.0, tipTE = -7.4
    static func leadingEdge(_ y: Double) -> Double { rootLE + (tipLE - rootLE) * (abs(y) - rootY) / (tipY - rootY) }
    static func trailingEdge(_ y: Double) -> Double { rootTE + (tipTE - rootTE) * (abs(y) - rootY) / (tipY - rootY) }

    /// Squared-off "tech" letters, 10×12, top row first, with heavy strokes
    /// so they still read as characters on screen.
    static let glyphs: [Character: [String]] = [
        "M": ["###....###", "####..####", "##########", "###.##.###"] + Array(repeating: "###....###", count: 8),
        "A": ["..######..", ".########.", "###....###", "###....###", "###....###", "##########", "##########"]
            + Array(repeating: "###....###", count: 5),
        "C": ["..########", ".#########"] + Array(repeating: "###.......", count: 8) + [".#########", "..########"],
        "H": Array(repeating: "###....###", count: 5) + ["##########", "##########"] + Array(repeating: "###....###", count: 5),
    ]
    /// A word painted on the top of a wing, in wing coordinates: `base` is
    /// the bottom-left corner, the baseline runs forward along x for `width`,
    /// and the letters rise `height` in +y while leaning forward by `lean`.
    /// Leaning forward cancels most of the jet's yaw, so the letters stand
    /// nearly upright on screen; both words sit where they fit inside the
    /// swept wing.
    struct Decal {
        var word: String
        var base: SIMD2<Double>
        var width = 4.5, height = 3.4, lean = 0.4, gap = 0.4
    }
    static let decals = [
        Decal(word: "MA", base: SIMD2(-7.0, 1.9)),      // port wing, glyph bottom near the root
        Decal(word: "CH", base: SIMD2(-6.9, -5.3)),     // starboard wing, glyph bottom near the tip
    ]

    /// Is this point on the top of a wing part of a letter?
    static func isLetter(x: Double, y: Double) -> Bool {
        let d = decals[y > 0 ? 0 : 1]
        let up = (y - d.base.y) / d.height                  // 0 at the baseline, 1 at the top
        guard up >= 0, up < 1 else { return false }
        let along = x - d.base.x - up * d.lean
        let letterW = (d.width - d.gap) / 2
        let i = along < letterW ? 0 : along >= letterW + d.gap ? 1 : -1
        guard i >= 0, along >= 0, along < d.width, let rows = glyphs[Array(d.word)[i]] else { return false }
        let lx = (along - Double(i) * (letterW + d.gap)) / letterW
        let r = min(11, max(0, Int((1 - up) * 12))), c = min(9, max(0, Int(lx * 10)))
        return Array(rows[r])[c] == "#"
    }

    /// Flap/aileron hinge lines, the gap between them, and the slat line.
    static func isPanelLine(x: Double, y: Double) -> Bool {
        let span = abs(y), le = leadingEdge(y), te = trailingEdge(y)
        let u = (span - rootY) / (tipY - rootY)
        let hinge = te + 1.25
        if u > 0.06, u < 0.95, abs(x - hinge) < 0.09 { return true }
        if abs(u - 0.56) < 0.012, x < hinge { return true }
        if u > 0.1, u < 0.97, abs(x - (le - 0.7)) < 0.07 { return true }
        return false
    }

    // MARK: building

    init() {
        buildFuselage()
        buildCanopy()
        for side in [1.0, -1.0] {
            buildWing(side)
            buildStabiliser(side)
            buildTail(side)
            buildIntake(side)
            buildNozzle(side)
        }
    }

    private mutating func quad(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ c: SIMD3<Double>, _ d: SIMD3<Double>,
                               _ part: Part, wingTop: Bool = false) {
        let n = simd_normalize(simd_cross(b - a, c - a))
        tris.append(Tri(m: [a, b, c], n: [n, n, n], part: part, wingTop: wingTop))
        tris.append(Tri(m: [a, c, d], n: [n, n, n], part: part, wingTop: wingTop))
    }

    /// Lofted body: stations of (x, half-width, half-height, centre z), with a
    /// flattened superellipse cross-section like the F-22's chined fuselage.
    private mutating func buildFuselage() {
        let stations: [(x: Double, w: Double, h: Double, z: Double)] = [
            (11.0, 0.02, 0.02, 0.05), (10.2, 0.32, 0.26, 0.05), (8.8, 0.66, 0.5, 0.08), (7.0, 0.95, 0.66, 0.12),
            (5.0, 1.25, 0.74, 0.14), (3.0, 1.75, 0.76, 0.12), (0.5, 2.05, 0.74, 0.1), (-2.5, 2.1, 0.7, 0.06),
            (-5.5, 1.95, 0.64, 0.03), (-8.0, 1.6, 0.56, 0.0), (-10.0, 1.3, 0.48, 0.0),
        ]
        let seg = 24
        func ring(_ s: (x: Double, w: Double, h: Double, z: Double)) -> [(SIMD3<Double>, SIMD3<Double>)] {
            (0..<seg).map { k in
                let a = Double(k) / Double(seg) * 2 * .pi
                let c = cos(a), sn = sin(a)
                // Superellipse (exponent 2.6) gives flat sides with rounded chines.
                let e = 2 / 2.6
                let y = s.w * copysign(pow(abs(c), e), c), z = s.h * copysign(pow(abs(sn), e), sn)
                let n = simd_normalize(SIMD3(0, y / max(s.w * s.w, 1e-4), z / max(s.h * s.h, 1e-4)))
                return (SIMD3(s.x, y, s.z + z), n)
            }
        }
        let rings = stations.map(ring)
        for i in 0..<(rings.count - 1) {
            for k in 0..<seg {
                let k2 = (k + 1) % seg
                let a = rings[i][k], b = rings[i + 1][k], c = rings[i + 1][k2], d = rings[i][k2]
                tris.append(Tri(m: [a.0, b.0, c.0], n: [a.1, b.1, c.1], part: .hull))
                tris.append(Tri(m: [a.0, c.0, d.0], n: [a.1, c.1, d.1], part: .hull))
            }
        }
        // Tail cap.
        let last = rings[rings.count - 1], cap = SIMD3(stations.last!.x, 0, stations.last!.z)
        for k in 0..<seg {
            let n = SIMD3(-1.0, 0, 0)
            tris.append(Tri(m: [cap, last[(k + 1) % seg].0, last[k].0], n: [n, n, n], part: .hull))
        }
    }

    private mutating func buildCanopy() {
        let cx = 5.6, rx = 2.3, ry = 0.55, rz = 0.62, z0 = 0.8
        let lat = 6, lon = 16
        func p(_ i: Int, _ j: Int) -> (SIMD3<Double>, SIMD3<Double>) {
            let th = Double(i) / Double(lat) * .pi / 2        // 0 at the rim, π/2 at the top
            let ph = Double(j) / Double(lon) * 2 * .pi
            let u = SIMD3(cos(th) * cos(ph), cos(th) * sin(ph), sin(th))
            return (SIMD3(cx + rx * u.x, ry * u.y, z0 + rz * u.z),
                    simd_normalize(SIMD3(u.x / rx, u.y / ry, u.z / rz)))
        }
        for i in 0..<lat {
            for j in 0..<lon {
                let a = p(i, j), b = p(i, j + 1), c = p(i + 1, j + 1), d = p(i + 1, j)
                tris.append(Tri(m: [a.0, b.0, c.0], n: [a.1, b.1, c.1], part: .canopy))
                tris.append(Tri(m: [a.0, c.0, d.0], n: [a.1, c.1, d.1], part: .canopy))
            }
        }
    }

    private mutating func buildWing(_ s: Double) {
        let t = 0.07
        let rl = SIMD2(Self.rootLE, Self.rootY * s), tl = SIMD2(Self.tipLE, Self.tipY * s)
        let tt = SIMD2(Self.tipTE, Self.tipY * s), rt = SIMD2(Self.rootTE, Self.rootY * s)
        func v(_ p: SIMD2<Double>, _ z: Double) -> SIMD3<Double> { SIMD3(p.x, p.y, z) }
        // Winding so the top faces +z on both sides.
        if s > 0 {
            quad(v(rl, t), v(rt, t), v(tt, t), v(tl, t), .wing, wingTop: true)
            quad(v(rl, -t), v(tl, -t), v(tt, -t), v(rt, -t), .wing)
        } else {
            quad(v(rl, t), v(tl, t), v(tt, t), v(rt, t), .wing, wingTop: true)
            quad(v(rl, -t), v(rt, -t), v(tt, -t), v(tl, -t), .wing)
        }
        quad(v(rl, -t), v(rl, t), v(tl, t), v(tl, -t), .wing)     // leading edge
        quad(v(tl, -t), v(tl, t), v(tt, t), v(tt, -t), .wing)     // tip
    }

    private mutating func buildStabiliser(_ s: Double) {
        let pts = [SIMD3(-7.6, 1.3 * s, 0.0), SIMD3(-9.7, 4.4 * s, 0.0), SIMD3(-10.9, 4.4 * s, 0.0), SIMD3(-10.7, 1.3 * s, 0.0)]
        if s > 0 { quad(pts[0], pts[3], pts[2], pts[1], .wing) } else { quad(pts[0], pts[1], pts[2], pts[3], .wing) }
    }

    private mutating func buildTail(_ s: Double) {
        let cant = 26.0 * .pi / 180, h = 3.3
        let base = 1.35 * s, z0 = 0.5
        let top = SIMD2(base + h * sin(cant) * s, z0 + h * cos(cant))
        let a = SIMD3(-5.6, base, z0), b = SIMD3(-9.7, base, z0)
        let c = SIMD3(-10.0, top.x, top.y), d = SIMD3(-8.5, top.x, top.y)
        if s > 0 { quad(a, d, c, b, .tail) } else { quad(a, b, c, d, .tail) }
        // A rudder hinge line would be nice; the edge pass outlines the fin instead.
    }

    private mutating func buildIntake(_ s: Double) {
        // A wedge along each side of the body, open at the front.
        let y0 = 1.6 * s, y1 = 2.35 * s
        let f = 3.6, r = -1.5
        let top = 0.35, bot = -0.45
        let p = [SIMD3(f, y1, top), SIMD3(f, y1, bot), SIMD3(r, y1 * 0.95, top * 0.9), SIMD3(r, y1 * 0.95, bot * 0.8),
                 SIMD3(f - 0.5, y0, top), SIMD3(f - 0.5, y0, bot)]
        if s > 0 {
            quad(p[0], p[1], p[3], p[2], .intake)             // outer side
            quad(p[4], p[0], p[2], SIMD3(r, y0, top), .intake) // top
            quad(p[1], p[5], SIMD3(r, y0, bot), p[3], .intake) // bottom
        } else {
            quad(p[0], p[2], p[3], p[1], .intake)
            quad(p[4], SIMD3(r, y0, top), p[2], p[0], .intake)
            quad(p[1], p[3], SIMD3(r, y0, bot), p[5], .intake)
        }
        // The dark mouth.
        quad(p[4], p[5], p[1], p[0], .nozzle)
    }

    private mutating func buildNozzle(_ s: Double) {
        let cy = 0.58 * s, r = 0.42, x0 = -9.6, x1 = -10.9, seg = 14
        for k in 0..<seg {
            let a0 = Double(k) / Double(seg) * 2 * .pi, a1 = Double(k + 1) / Double(seg) * 2 * .pi
            let n0 = SIMD3(0, cos(a0), sin(a0)), n1 = SIMD3(0, cos(a1), sin(a1))
            let p0 = SIMD3(x0, cy + r * cos(a0), r * sin(a0)), p1 = SIMD3(x0, cy + r * cos(a1), r * sin(a1))
            let q0 = SIMD3(x1, cy + r * 0.9 * cos(a0), r * 0.9 * sin(a0)), q1 = SIMD3(x1, cy + r * 0.9 * cos(a1), r * 0.9 * sin(a1))
            tris.append(Tri(m: [p0, q0, q1], n: [n0, n0, n1], part: .nozzle))
            tris.append(Tri(m: [p0, q1, p1], n: [n0, n1, n1], part: .nozzle))
        }
    }

    // MARK: rendering

    struct Pose {
        var yaw, pitch, roll: Double    // degrees
    }

    /// One rendered frame on a character grid (row 0 at the top).
    struct Frame {
        var cols = 0, rows = 0
        var part: [Part] = []
        var light: [Float] = []         // 0…1
        var letter: [Bool] = []
        var panel: [Bool] = []
        var depth: [Float] = []
        func index(_ c: Int, _ r: Int) -> Int { r * cols + c }
    }

    /// World-space rotation for a pose: roll about the fuselage, then pitch,
    /// then yaw in the screen plane, applied to a top-down view.
    static func rotation(_ p: Pose) -> simd_double3x3 {
        func rx(_ a: Double) -> simd_double3x3 {
            simd_double3x3(rows: [SIMD3(1, 0, 0), SIMD3(0, cos(a), -sin(a)), SIMD3(0, sin(a), cos(a))])
        }
        func ry(_ a: Double) -> simd_double3x3 {
            simd_double3x3(rows: [SIMD3(cos(a), 0, sin(a)), SIMD3(0, 1, 0), SIMD3(-sin(a), 0, cos(a))])
        }
        func rz(_ a: Double) -> simd_double3x3 {
            simd_double3x3(rows: [SIMD3(cos(a), -sin(a), 0), SIMD3(sin(a), cos(a), 0), SIMD3(0, 0, 1)])
        }
        let d = Double.pi / 180
        return rz(p.yaw * d) * ry(p.pitch * d) * rx(p.roll * d)
    }

    static let focal = 70.0

    /// Screen position (model units) of a model-space point under a rotation.
    static func project(_ p: SIMD3<Double>, _ rot: simd_double3x3) -> SIMD3<Double> {
        let w = rot * p
        let k = focal / (focal - w.z)
        return SIMD3(w.x * k, w.y * k, w.z)
    }

    /// Bounds of the projected model, for layout.
    func bounds(_ pose: Pose) -> CGRect {
        let rot = Self.rotation(pose)
        var minX = Double.infinity, minY = Double.infinity, maxX = -Double.infinity, maxY = -Double.infinity
        for t in tris { for p in t.m {
            let s = Self.project(p, rot)
            minX = min(minX, s.x); maxX = max(maxX, s.x); minY = min(minY, s.y); maxY = max(maxY, s.y)
        }}
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Rasterises into a `cols`×`rows` grid of cells `cell` model units... well,
    /// `cellW`×`cellH` model units each, with model (0,0) at grid point `centre`.
    func render(_ pose: Pose, cols: Int, rows: Int, cellW: Double, cellH: Double, centre: SIMD2<Double>) -> Frame {
        var f = Frame(cols: cols, rows: rows)
        let n = cols * rows
        f.part = Array(repeating: .none, count: n)
        f.light = Array(repeating: 0, count: n)
        f.letter = Array(repeating: false, count: n)
        f.panel = Array(repeating: false, count: n)
        f.depth = Array(repeating: -.infinity, count: n)
        let rot = Self.rotation(pose)
        let lightDir = simd_normalize(SIMD3(-0.3, 0.45, 0.85))
        let view = SIMD3(0.0, 0, 1)

        for t in tris {
            let s = t.m.map { Self.project($0, rot) }
            // Grid coordinates: columns right, rows down.
            let g = s.map { SIMD2(centre.x + $0.x / cellW, centre.y - $0.y / cellH) }
            let area = (g[1].x - g[0].x) * (g[2].y - g[0].y) - (g[2].x - g[0].x) * (g[1].y - g[0].y)
            guard abs(area) > 1e-9 else { continue }
            let c0 = max(0, Int(floor(min(g[0].x, g[1].x, g[2].x)))), c1 = min(cols - 1, Int(ceil(max(g[0].x, g[1].x, g[2].x))))
            let r0 = max(0, Int(floor(min(g[0].y, g[1].y, g[2].y)))), r1 = min(rows - 1, Int(ceil(max(g[0].y, g[1].y, g[2].y))))
            guard c0 <= c1, r0 <= r1 else { continue }
            let nw = t.n.map { rot * $0 }
            for r in r0...r1 {
                let py = Double(r) + 0.5
                for c in c0...c1 {
                    let px = Double(c) + 0.5
                    let w0 = ((g[1].x - px) * (g[2].y - py) - (g[2].x - px) * (g[1].y - py)) / area
                    let w1 = ((g[2].x - px) * (g[0].y - py) - (g[0].x - px) * (g[2].y - py)) / area
                    let w2 = 1 - w0 - w1
                    guard w0 >= -1e-6, w1 >= -1e-6, w2 >= -1e-6 else { continue }
                    let z = w0 * s[0].z + w1 * s[1].z + w2 * s[2].z
                    let i = r * cols + c
                    guard z > Double(f.depth[i]) else { continue }
                    var nrm = simd_normalize(w0 * nw[0] + w1 * nw[1] + w2 * nw[2])
                    if simd_dot(nrm, view) < 0 { nrm = -nrm }      // panels are two-sided
                    let diff = max(0, simd_dot(nrm, lightDir))
                    let half = simd_normalize(lightDir + view)
                    let spec = pow(max(0, simd_dot(nrm, half)), t.part == .canopy ? 30 : 18)
                    var l = 0.16 + 0.68 * diff + (t.part == .canopy ? 0.6 : 0.3) * spec
                    switch t.part {
                    case .canopy: l *= 0.75
                    case .nozzle: l *= 0.45
                    case .intake: l *= 0.85
                    default: break
                    }
                    f.depth[i] = Float(z)
                    f.part[i] = t.part
                    f.light[i] = Float(min(1, l))
                    if t.wingTop {
                        let m = w0 * t.m[0] + w1 * t.m[1] + w2 * t.m[2]
                        f.letter[i] = Self.isLetter(x: m.x, y: m.y)
                        f.panel[i] = !f.letter[i] && Self.isPanelLine(x: m.x, y: m.y)
                    } else {
                        f.letter[i] = false
                        f.panel[i] = false
                    }
                }
            }
        }
        return f
    }
}
