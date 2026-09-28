import Foundation

enum Art {
    // ANSI Shadow figlet.
    static let mach = [
        "███╗   ███╗ █████╗  ██████╗██╗  ██╗",
        "████╗ ████║██╔══██╗██╔════╝██║  ██║",
        "██╔████╔██║███████║██║     ███████║",
        "██║╚██╔╝██║██╔══██║██║     ██╔══██║",
        "██║ ╚═╝ ██║██║  ██║╚██████╗██║  ██║",
        "╚═╝     ╚═╝╚═╝  ╚═╝ ╚═════╝╚═╝  ╚═╝",
    ]
}

/// A logo as a grid of dots. Braille characters become their 2x4 dots, any
/// other visible character fills its whole 2x4 block, so fastfetch logos work.
struct DotArt {
    private(set) var width = 0
    private(set) var height = 0
    private(set) var points: [(x: Int, y: Int)] = []

    private static let brailleBits: [(bit: UInt32, dx: Int, dy: Int)] = [
        (0x01, 0, 0), (0x02, 0, 1), (0x04, 0, 2), (0x08, 1, 0),
        (0x10, 1, 1), (0x20, 1, 2), (0x40, 0, 3), (0x80, 1, 3),
    ]

    init(text: String) {
        // fastfetch colour markers ($1..$9) aren't part of the picture.
        let clean = text.replacingOccurrences(of: "\\$[0-9]", with: "", options: .regularExpression)
        var raw: [(x: Int, y: Int)] = []
        for (row, line) in clean.components(separatedBy: .newlines).enumerated() {
            for (col, scalar) in line.unicodeScalars.enumerated() {
                let v = scalar.value
                if (0x2800...0x28FF).contains(v) {
                    for b in Self.brailleBits where (v - 0x2800) & b.bit != 0 {
                        raw.append((col * 2 + b.dx, row * 4 + b.dy))
                    }
                } else if !CharacterSet.whitespaces.contains(scalar) {
                    for dy in 0..<4 { for dx in 0..<2 { raw.append((col * 2 + dx, row * 4 + dy)) } }
                }
            }
        }
        guard let minX = raw.map(\.x).min(), let minY = raw.map(\.y).min() else { return }
        points = raw.map { ($0.x - minX, $0.y - minY) }
        width = points.map(\.x).max()! + 1
        height = points.map(\.y).max()! + 1
    }
}
