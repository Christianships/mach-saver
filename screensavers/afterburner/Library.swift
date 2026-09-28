import AppKit

/// Saved screensavers and colourways. The menu bar agent reads it each time it
/// shows the screensaver; the panel edits it. Kept as JSON in
/// ~/Library/Application Support/Mach Saver/library.json.
struct Library: Codable {
    /// A screensaver: the big word, the logo behind it, and its colours.
    struct Saver: Codable, Identifiable, Equatable {
        var id: String
        var name: String
        var text: String            // "MACH" uses the hand-made figlet; anything else is drawn in block letters
        var logoPath: String?       // nil = the built-in jet; else braille/ASCII .txt or an image
        var palette: String         // a Palette name

        var isDefault: Bool { id == Library.defaultID }
        var title: [String] { text.uppercased() == "MACH" ? Art.mach : BlockText.lines(text) }
        var logo: DotArt { Afterburner.logo(at: logoPath) }
    }

    /// A saved colourway, as hex colours.
    struct Colorway: Codable, Identifiable, Equatable {
        var id: String
        var name: String
        var background, jetTop, jetBottom, textStart, textEnd: String
        var camo = false

        var palette: Palette {
            let bg = RGB(hex: background), jt = RGB(hex: jetTop), jb = RGB(hex: jetBottom)
            let ts = RGB(hex: textStart), te = RGB(hex: textEnd)
            let white = RGB(255, 255, 255)
            // Camo splits the text colours into four bands, darkest first.
            let text = camo ? (0..<4).map { te.mix(ts, Double($0) / 3) } : [ts, te]
            return Palette(name: id, title: name, background: bg,
                           fire: [bg.mix(te, 0.3), te, ts, ts.mix(white, 0.6), white],
                           accent: [jt, jt.mix(jb, 0.5), jb], text: text, camo: camo)
        }

        /// A new colourway starting from any palette's colours.
        init(copying p: Palette, id: String = UUID().uuidString, name: String) {
            let text = p.text ?? p.accent
            self.id = id; self.name = name
            background = p.background.hex
            jetTop = p.accent.first!.hex; jetBottom = p.accent.last!.hex
            textStart = (p.camo ? text.last! : text.first!).hex
            textEnd = (p.camo ? text.first! : text.last!).hex
            camo = p.camo
        }
    }

    var savers: [Saver]
    var colorways: [Colorway]
    var active: String

    static let defaultID = "afterburner"

    static var url: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Mach Saver/library.json")
    }

    static func load() -> Library {
        if let data = try? Data(contentsOf: url), let lib = try? JSONDecoder().decode(Library.self, from: data), !lib.savers.isEmpty {
            return lib
        }
        // First run: the one screensaver there was, with the old colour/logo settings.
        let d = UserDefaults.standard
        let saver = Saver(id: defaultID, name: "Afterburner", text: "MACH",
                          logoPath: d.string(forKey: "afterburner.logoPath"),
                          palette: d.string(forKey: "afterburner.palette") ?? Palette.purple.name)
        return Library(savers: [saver], colorways: [], active: defaultID)
    }

    func save() {
        try? FileManager.default.createDirectory(at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(self).write(to: Self.url, options: .atomic)
    }

    var activeSaver: Saver { savers.first { $0.id == active } ?? savers[0] }
}

// MARK: hex colours

extension RGB {
    init(hex: String) {
        let v = UInt32(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0
        self.init(Double(v >> 16 & 0xFF), Double(v >> 8 & 0xFF), Double(v & 0xFF))
    }

    var hex: String {
        String(format: "#%02X%02X%02X", Int(r.rounded()), Int(g.rounded()), Int(b.rounded()))
    }
}

// MARK: block letters for custom text

/// Any text as rows of █, by drawing it in a heavy font and sampling a grid,
/// so a custom screensaver's word can play the same text effects as MACH.
enum BlockText {
    static let rows = 7

    static func lines(_ text: String) -> [String] {
        let word = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty else { return Art.mach }
        let font = NSFont.systemFont(ofSize: 120, weight: .black)
        let attr = NSAttributedString(string: word, attributes: [.font: font, .foregroundColor: NSColor.white])
        let line = CTLineCreateWithAttributedString(attr)
        let bounds = CTLineGetImageBounds(line, nil)
        guard bounds.width > 0, bounds.height > 0 else { return Art.mach }
        // Characters are about half as wide as they are tall.
        let cellH = bounds.height / CGFloat(rows), cellW = cellH * 0.5
        let cols = max(1, Int((bounds.width / cellW).rounded(.up)))
        let w = cols * 4, h = rows * 8
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let data = ctx.data else { return Art.mach }
        ctx.scaleBy(x: CGFloat(w) / bounds.width, y: CGFloat(h) / bounds.height)
        ctx.translateBy(x: -bounds.minX, y: -bounds.minY)
        ctx.textPosition = .zero
        CTLineDraw(line, ctx)
        let px = data.bindMemory(to: UInt8.self, capacity: w * h)
        return (0..<rows).map { r in
            String((0..<cols).map { c -> Character in
                var sum = 0
                for y in 0..<8 { for x in 0..<4 { sum += Int(px[(r * 8 + y) * w + c * 4 + x]) } }
                return sum > 32 * 255 * 45 / 100 ? "█" : " "
            })
        }
    }
}

// MARK: logos from images

extension DotArt {
    /// An image as dots about `width` across: its opaque parts if it has
    /// transparency, otherwise whichever of light or dark there's less of.
    init(image url: URL, width: Int = 120) {
        guard let img = NSImage(contentsOf: url), let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            self.init(text: ""); return
        }
        let w = width, h = max(1, Int(Double(width) * Double(cg.height) / Double(cg.width)))
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let ok = px.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { self.init(text: ""); return }
        let alpha = (0..<(w * h)).map { px[$0 * 4 + 3] }
        let transparent = alpha.contains { $0 < 200 }
        let luma = (0..<(w * h)).map { i in (Int(px[i * 4]) * 3 + Int(px[i * 4 + 1]) * 6 + Int(px[i * 4 + 2])) / 10 }
        let bright = luma.filter { $0 > 128 }.count
        let on: (Int) -> Bool = transparent ? { alpha[$0] > 128 }
            : bright < w * h / 2 ? { luma[$0] > 128 } : { luma[$0] <= 128 }
        // Pack into braille (a 2x4 block of dots per character) so DotArt's own
        // parsing does the rest. Bitmap memory is already top row first.
        var lines: [String] = []
        for by in stride(from: 0, to: h, by: 4) {
            var line = ""
            for bx in stride(from: 0, to: w, by: 2) {
                var bits: UInt32 = 0
                let map: [(Int, Int, UInt32)] = [(0, 0, 0x01), (0, 1, 0x02), (0, 2, 0x04), (1, 0, 0x08),
                                                 (1, 1, 0x10), (1, 2, 0x20), (0, 3, 0x40), (1, 3, 0x80)]
                for (dx, dy, bit) in map {
                    let x = bx + dx, y = by + dy
                    guard x < w, y < h else { continue }
                    if on(y * w + x) { bits |= bit }
                }
                line.unicodeScalars.append(Unicode.Scalar(0x2800 + bits)!)
            }
            lines.append(line)
        }
        self.init(text: lines.joined(separator: "\n"))
    }
}
