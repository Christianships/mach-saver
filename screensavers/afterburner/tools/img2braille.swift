// Turns a screenshot of dot-matrix art into braille text.
//
// Finds each lit dot, works out the grid it sits on, then packs the grid
// into braille characters (2 dots wide, 4 dots tall per character).
//
//   swift tools/img2braille.swift tools/jet-source.png > Resources/jet.txt

import AppKit

guard CommandLine.arguments.count > 1,
      let image = NSImage(contentsOfFile: CommandLine.arguments[1]),
      let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    FileHandle.standardError.write("usage: img2braille <image>\n".data(using: .utf8)!)
    exit(1)
}

let w = cg.width, h = cg.height
var px = [UInt8](repeating: 0, count: w * h)
let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
func lum(_ x: Int, _ y: Int) -> Int { Int(px[y * w + x]) }

// Dots are bright against a darker, uneven background, so compare each pixel
// with the average of its neighbourhood instead of using one fixed cutoff.
var integral = [Int](repeating: 0, count: (w + 1) * (h + 1))
for y in 0..<h {
    var row = 0
    for x in 0..<w {
        row += lum(x, y)
        integral[(y + 1) * (w + 1) + x + 1] = integral[y * (w + 1) + x + 1] + row
    }
}
func localMean(_ x: Int, _ y: Int, _ r: Int) -> Int {
    let x0 = max(0, x - r), y0 = max(0, y - r), x1 = min(w, x + r + 1), y1 = min(h, y + r + 1)
    let s = integral[y1 * (w + 1) + x1] - integral[y0 * (w + 1) + x1]
          - integral[y1 * (w + 1) + x0] + integral[y0 * (w + 1) + x0]
    return s / ((x1 - x0) * (y1 - y0))
}
var lit = [Bool](repeating: false, count: w * h)
for y in 0..<h { for x in 0..<w {
    let v = lum(x, y)
    lit[y * w + x] = v > 120 && v - localMean(x, y, 10) > 30
}}

// The dots are packed tightly enough that neighbours touch, so rather than
// tracing individual dots, find the rows and columns they line up on (peaks in
// the brightness profile) and sample each crossing.
func contrast(_ x: Int, _ y: Int) -> Int { lit[y * w + x] ? lum(x, y) - localMean(x, y, 10) : 0 }
var colProfile = [Double](repeating: 0, count: w), rowProfile = [Double](repeating: 0, count: h)
for y in 0..<h { for x in 0..<w { let c = Double(contrast(x, y)); colProfile[x] += c; rowProfile[y] += c } }

func peaks(_ profile: [Double]) -> [Int] {
    // Light smoothing, then local maxima at least 3px apart.
    let s = profile.indices.map { i in (max(0, i - 1)...min(profile.count - 1, i + 1)).map { profile[$0] }.reduce(0, +) }
    let floor = (s.max() ?? 0) * 0.02
    var out: [Int] = []
    for i in s.indices where s[i] > floor {
        let lo = max(0, i - 2), hi = min(s.count - 1, i + 2)
        guard s[i] == s[lo...hi].max() else { continue }
        if let last = out.last, i - last < 3 { continue }
        out.append(i)
    }
    return out
}
let cols = peaks(colProfile), rows = peaks(rowProfile)

var cells = Set<[Int]>()
for (j, y) in rows.enumerated() { for (i, x) in cols.enumerated() {
    var best = 0
    for dy in -1...1 { for dx in -1...1 {
        let sx = x + dx, sy = y + dy
        if sx >= 0, sy >= 0, sx < w, sy < h { best = max(best, contrast(sx, sy)) }
    }}
    if best > 30 { cells.insert([i, j]) }
}}
guard !cells.isEmpty else { print("no dots found"); exit(1) }
let minX = cells.map { $0[0] }.min()!, minY = cells.map { $0[1] }.min()!
let maxX = cells.map { $0[0] }.max()!, maxY = cells.map { $0[1] }.max()!

// Pack into braille. Bit layout per character:
//   1 4
//   2 5
//   3 6
//   7 8
let bits: [[UInt32]] = [[0x01, 0x08], [0x02, 0x10], [0x04, 0x20], [0x40, 0x80]]
var lines: [String] = []
for cy in stride(from: minY, through: maxY, by: 4) {
    var line = ""
    for cx in stride(from: minX, through: maxX, by: 2) {
        var mask: UInt32 = 0
        for dy in 0..<4 { for dx in 0..<2 where cells.contains([cx + dx, cy + dy]) { mask |= bits[dy][dx] } }
        line += mask == 0 ? " " : String(UnicodeScalar(0x2800 + mask)!)
    }
    while line.hasSuffix(" ") { line.removeLast() }
    lines.append(line)
}
print(lines.joined(separator: "\n"))
